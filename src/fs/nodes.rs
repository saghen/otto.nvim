//! The inodes the kernel knows of, and what it may keep of them

use std::collections::{HashMap, HashSet};
use std::ffi::{OsStr, OsString};
use std::io;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::time::Duration;

use fuser::INodeNo;
use rustix::fs::inotify::{self, ReadFlags, WatchFlags};
use rustix::fs::{AtFlags, Stat};

use super::watch::{Invalidations, Stale};
use crate::fd_path;

/// How long the kernel keeps what it looked up in directories we watch, where `forward_invalidations` tells it of
/// every change, from anyone. Elsewhere, like once inotify is out of watches, or that stopped, it keeps nothing, since
/// other agents and the user change files under us
pub(super) const TTL: Duration = Duration::from_secs(60);
pub(super) const ROOT: INodeNo = INodeNo::ROOT;

const WATCHED: WatchFlags = WatchFlags::CREATE
    .union(WatchFlags::DELETE)
    .union(WatchFlags::MOVED_FROM)
    .union(WatchFlags::MOVED_TO)
    .union(WatchFlags::MODIFY)
    .union(WatchFlags::CLOSE_WRITE)
    .union(WatchFlags::ATTRIB)
    .union(WatchFlags::DELETE_SELF)
    .union(WatchFlags::MOVE_SELF)
    .union(WatchFlags::ONLYDIR);

/// An inode, by its device and number, which are what tell two of them apart
type Key = (u64, u64);

fn key(st: &Stat) -> Key {
    (st.st_dev, st.st_ino)
}

/// A directory's inotify watch, and the names in it that the kernel may keep
struct Watch {
    wd: i32,
    names: HashSet<OsString>,
}

struct Node {
    fd: OwnedFd,
    key: Key,
    lookups: u64,
    /// Of a directory we watch
    watch: Option<Watch>,
    /// Whether it was last looked up in a directory we watch, which tells us of changes to it
    in_watched: bool,
    /// Whether the kernel keeps its attributes, and contents
    cached: bool,
    /// Whether an open found it removed, so the next may open it anyway
    removed: bool,
}

/// Each node the kernel may keep something of, with the names in it that it may keep, see `Nodes::take_kept`
pub(super) type Kept = Vec<(INodeNo, HashSet<OsString>)>;

/// What the kernel knows of, by the id it knows each by, the real inode number where it's free. Each watch in
/// `by_watch` is its node's
pub(super) struct Nodes {
    by_id: HashMap<INodeNo, Node>,
    by_key: HashMap<Key, INodeNo>,
    by_watch: HashMap<i32, INodeNo>,
    next: u64,
    /// What tells us of changes to the directories we watch
    pub(super) inotify: OwnedFd,
    /// Until `forward_invalidations` stops, after which nothing's watched, so the kernel keeps nothing
    watching: bool,
}

impl Nodes {
    pub(super) fn new(root: OwnedFd) -> io::Result<Self> {
        let inotify = inotify::init(inotify::CreateFlags::CLOEXEC)?;
        let (by_id, by_key, by_watch) = (HashMap::new(), HashMap::new(), HashMap::new());
        let mut nodes = Self { by_id, by_key, by_watch, next: 0, inotify, watching: true };
        let st = rustix::fs::fstat(&root)?;
        let watch = nodes.add_watch(ROOT, root.as_fd(), &st);
        let key = key(&st);
        nodes.by_key.insert(key, ROOT);
        let node = Node { fd: root, key, lookups: 1, watch, in_watched: false, cached: false, removed: false };
        nodes.by_id.insert(ROOT, node);
        Ok(nodes)
    }

    /// The id of the node of the inode `st`, if the kernel knows of it
    pub(super) fn id_of(&self, st: &Stat) -> Option<INodeNo> {
        self.by_key.get(&key(st)).copied()
    }

    /// A duplicate of the node's fd, which a forget could close once they're no longer held
    pub(super) fn fd(&self, id: INodeNo) -> io::Result<OwnedFd> {
        self.by_id.get(&id).ok_or(io::Error::from(rustix::io::Errno::STALE))?.fd.try_clone()
    }

    /// Whether the node's file is gone by the name the kernel opens it by, like when another process replaced it since
    /// it was looked up, so the kernel looks it up again. True only the first time, which it records, since the
    /// kernel then opens a removed file on purpose, like through `/proc/<pid>/fd`
    pub(super) fn first_open_of_removed(&mut self, id: INodeNo) -> bool {
        let Some(node) = self.by_id.get_mut(&id) else { return false };
        let removed = rustix::fs::fstat(&node.fd).is_ok_and(|st| st.st_nlink == 0);
        removed && !std::mem::replace(&mut node.removed, true)
    }

    /// Whether the kernel keeps the node's attributes, and contents, as `cache_attr` last said
    pub(super) fn cached(&self, id: INodeNo) -> bool {
        self.by_id.get(&id).is_some_and(|node| node.cached)
    }

    /// Adds what an inotify event invalidates to `invalidations`
    pub(super) fn changed(&mut self, event: &inotify::Event, invalidations: &mut Invalidations) {
        let flags = event.events();
        // Events were lost, so anything could have changed
        if flags.contains(ReadFlags::QUEUE_OVERFLOW) {
            return invalidations.add_kept(self.take_kept());
        }
        let Some(&dir) = self.by_watch.get(&event.wd()) else { return };
        let Some(node) = self.by_id.get_mut(&dir) else { return };
        // Like once it's removed, which leaves nothing to look up in it
        if flags.contains(ReadFlags::IGNORED) {
            self.by_watch.remove(&event.wd());
            node.watch = None;
            return invalidations.add_inode(dir, Stale::Contents);
        }
        let Some(name) = event.file_name() else { return invalidations.add_inode(dir, Stale::Attributes) };
        let name = OsStr::from_bytes(name.to_bytes());
        if flags.intersects(ReadFlags::CREATE | ReadFlags::DELETE | ReadFlags::MOVED_FROM | ReadFlags::MOVED_TO) {
            // which it then looks up again
            if node.watch.as_mut().is_some_and(|watch| watch.names.remove(name)) {
                invalidations.entries.insert((dir, name.into()));
            }
            // and its listing
            return invalidations.add_inode(dir, Stale::Contents);
        }
        let attributes_only =
            flags.contains(ReadFlags::ATTRIB) && !flags.intersects(ReadFlags::MODIFY | ReadFlags::CLOSE_WRITE);
        let Ok(st) = rustix::fs::statat(&node.fd, name, AtFlags::SYMLINK_NOFOLLOW) else { return };
        if let Some(id) = self.id_of(&st) {
            invalidations.add_inode(id, if attributes_only { Stale::Attributes } else { Stale::Contents });
        }
    }

    /// Each node, with the names in it that the kernel may keep, which it then no longer does
    pub(super) fn take_kept(&mut self) -> Kept {
        let names = |node: &mut Node| node.watch.as_mut().map(|watch| std::mem::take(&mut watch.names));
        self.by_id.iter_mut().map(|(&id, node)| (id, names(node).unwrap_or_default())).collect()
    }

    /// Once nothing can tell the kernel of changes, keeps it from keeping anything more, and returns what it kept, like
    /// `take_kept`
    pub(super) fn stop_watching(&mut self) -> Kept {
        let kept = self.take_kept();
        self.watching = false;
        self.by_watch.clear();
        for node in self.by_id.values_mut() {
            node.watch = None;
            node.cached = false;
        }
        kept
    }

    /// Watches a directory, unless inotify is out of watches, or watching stopped
    fn add_watch(&mut self, id: INodeNo, fd: BorrowedFd, st: &Stat) -> Option<Watch> {
        if !self.watching || rustix::fs::FileType::from_raw_mode(st.st_mode) != rustix::fs::FileType::Directory {
            return None;
        }
        let wd = inotify::add_watch(&self.inotify, fd_path(fd), WATCHED).ok()?;
        self.by_watch.insert(wd, id);
        Some(Watch { wd, names: HashSet::new() })
    }

    /// Adds a lookup of the inode `fd` points to, and returns its node's id
    pub(super) fn insert(&mut self, fd: OwnedFd, st: &Stat, in_watched: bool) -> INodeNo {
        let key = key(st);
        if let Some(&id) = self.by_key.get(&key)
            && let Some(node) = self.by_id.get_mut(&id)
        {
            node.lookups += 1;
            // by the name it was last looked up by, which files then open as, since another name may be gone
            node.fd = fd;
            node.in_watched = in_watched;
            return id;
        }
        // The real inode number where it's free, which git's index keeps
        let mut id = INodeNo(st.st_ino);
        while id == ROOT || self.by_id.contains_key(&id) {
            self.next += 1;
            id = INodeNo((1 << 63) + self.next);
        }
        let watch = self.add_watch(id, fd.as_fd(), st);
        self.by_id.insert(id, Node { fd, key, lookups: 1, watch, in_watched, cached: false, removed: false });
        self.by_key.insert(key, id);
        id
    }

    /// Drops `n` of the node's lookups, which the kernel no longer holds, and the node once none are left
    pub(super) fn forget(&mut self, id: INodeNo, n: u64) {
        let Some(node) = self.by_id.get_mut(&id) else { return };
        node.lookups = node.lookups.saturating_sub(n);
        if node.lookups == 0 && id != ROOT {
            self.remove(id);
        }
    }

    pub(super) fn remove(&mut self, id: INodeNo) {
        let Some(node) = self.by_id.remove(&id) else { return };
        self.by_key.remove(&node.key);
        if let Some(Watch { wd, .. }) = node.watch {
            self.by_watch.remove(&wd);
            // which inotify drops itself once the directory's gone
            let _ = inotify::remove_watch(&self.inotify, wd);
        }
    }

    /// Records that the kernel may keep `name` in `dir`, which `forward_invalidations` then invalidates when it
    /// changes, and returns for how long
    pub(super) fn cache_entry(&mut self, dir: INodeNo, name: &OsStr) -> Duration {
        match self.by_id.get_mut(&dir).and_then(|node| node.watch.as_mut()) {
            Some(watch) => {
                watch.names.insert(name.into());
                TTL
            }
            None => Duration::ZERO,
        }
    }

    /// Records whether the kernel may keep the node's attributes, and with them what it read of it, unless a change by
    /// another of its names would go unseen, and returns for how long
    pub(super) fn cache_attr(&mut self, id: INodeNo, st: &Stat) -> Duration {
        let watching = self.watching;
        let Some(node) = self.by_id.get_mut(&id) else { return Duration::ZERO };
        let is_dir = rustix::fs::FileType::from_raw_mode(st.st_mode) == rustix::fs::FileType::Directory;
        node.cached = watching && (node.watch.is_some() || !is_dir && node.in_watched && st.st_nlink == 1);
        if node.cached { TTL } else { Duration::ZERO }
    }
}

#[cfg(test)]
pub(super) mod tests {
    use std::path::Path;

    use rustix::fs::{Mode, OFlags};

    use super::*;
    use crate::test_util::Temp;

    pub(in crate::fs) fn open_with_stat(path: &Path) -> (OwnedFd, Stat) {
        let fd = rustix::fs::open(path, OFlags::PATH | OFlags::NOFOLLOW | OFlags::CLOEXEC, Mode::empty()).unwrap();
        let st = rustix::fs::fstat(&fd).unwrap();
        (fd, st)
    }

    pub(in crate::fs) fn nodes(temp: &Temp) -> Nodes {
        Nodes::new(open_with_stat(&temp.0).0).unwrap()
    }

    /// What the other modules' tests check of a node
    impl Nodes {
        pub(in crate::fs) fn lookups(&self, id: INodeNo) -> u64 {
            self.by_id[&id].lookups
        }

        /// Whether the node is a directory we watch
        pub(in crate::fs) fn is_watched(&self, id: INodeNo) -> bool {
            self.by_id[&id].watch.as_ref().is_some_and(|watch| self.by_watch.get(&watch.wd) == Some(&id))
        }

        pub(in crate::fs) fn watches(&self) -> usize {
            self.by_watch.len()
        }
    }

    #[test]
    fn new_has_the_root() {
        let temp = Temp::new("nodes-new");
        let nodes = nodes(&temp);
        let (_, st) = open_with_stat(&temp.0);
        let root = &nodes.by_id[&ROOT];
        assert_eq!(root.key, key(&st));
        assert_eq!(root.lookups, 1);
        assert_eq!(nodes.id_of(&st), Some(ROOT));
        assert_eq!(nodes.by_watch[&root.watch.as_ref().unwrap().wd], ROOT);
    }

    #[test]
    fn insert_counts_lookups_of_an_inode() {
        let temp = Temp::new("nodes-insert");
        let mut nodes = nodes(&temp);
        temp.write("a", "");
        std::fs::hard_link(temp.0.join("a"), temp.0.join("b")).unwrap();
        let (fd, st) = open_with_stat(&temp.0.join("a"));
        let id = nodes.insert(fd, &st, false);
        // the real inode number
        assert_eq!(id, INodeNo(st.st_ino));
        let (fd, st) = open_with_stat(&temp.0.join("b"));
        assert_eq!(nodes.insert(fd, &st, true), id);
        let node = &nodes.by_id[&id];
        assert_eq!(node.lookups, 2);
        assert!(node.in_watched);
        assert!(node.watch.is_none());
        // by the name last looked up by
        let link = std::fs::read_link(fd_path(node.fd.as_fd())).unwrap();
        assert_eq!(link.file_name(), Some("b".as_ref()));
    }

    #[test]
    fn insert_avoids_ids_taken() {
        let temp = Temp::new("nodes-collide");
        let mut nodes = nodes(&temp);
        temp.write("a", "");
        let (fd, st) = open_with_stat(&temp.0.join("a"));
        let a = nodes.insert(fd, &st, false);
        // another device's inode of the same number
        let (fd, mut other) = open_with_stat(&temp.0.join("a"));
        other.st_dev += 1;
        let b = nodes.insert(fd, &other, false);
        assert_eq!(b, INodeNo((1 << 63) + 1));
        let (fd, mut other) = open_with_stat(&temp.0.join("a"));
        (other.st_dev, other.st_ino) = (st.st_dev + 2, ROOT.0);
        let c = nodes.insert(fd, &other, false);
        assert_eq!(c, INodeNo((1 << 63) + 2));
        assert_eq!(nodes.by_id.len(), 4);
        assert_eq!(nodes.id_of(&st), Some(a));
        (other.st_dev, other.st_ino) = (st.st_dev + 1, st.st_ino);
        assert_eq!(nodes.id_of(&other), Some(b));
    }

    #[test]
    fn remove_forgets_the_node_and_its_watch() {
        let temp = Temp::new("nodes-remove");
        let mut nodes = nodes(&temp);
        std::fs::create_dir(temp.0.join("dir")).unwrap();
        let (fd, st) = open_with_stat(&temp.0.join("dir"));
        let id = nodes.insert(fd, &st, true);
        let wd = nodes.by_id[&id].watch.as_ref().unwrap().wd;
        assert_eq!(nodes.by_watch[&wd], id);
        nodes.remove(id);
        assert!(!nodes.by_id.contains_key(&id));
        assert_eq!(nodes.id_of(&st), None);
        assert!(!nodes.by_watch.contains_key(&wd));
        // and a lookup after is a new node
        let (fd, st) = open_with_stat(&temp.0.join("dir"));
        assert_eq!(nodes.insert(fd, &st, true), id);
        assert_eq!(nodes.by_id[&id].lookups, 1);
    }

    #[test]
    fn forget_drops_the_node_once_no_lookups_are_left() {
        let temp = Temp::new("nodes-forget");
        let mut nodes = nodes(&temp);
        temp.write("a", "");
        let (fd, st) = open_with_stat(&temp.0.join("a"));
        let id = nodes.insert(fd, &st, true);
        let (fd, st) = open_with_stat(&temp.0.join("a"));
        nodes.insert(fd, &st, true);
        nodes.forget(id, 1);
        assert_eq!(nodes.by_id[&id].lookups, 1);
        nodes.forget(id, 5);
        assert!(!nodes.by_id.contains_key(&id));
        // but never the root
        nodes.forget(ROOT, 1);
        assert!(nodes.by_id.contains_key(&ROOT));
        nodes.forget(INodeNo(12345), 1);
    }

    #[test]
    fn cache_entry_only_in_watched_dirs() {
        let temp = Temp::new("nodes-cache-entry");
        let mut nodes = nodes(&temp);
        temp.write("a", "");
        let (fd, st) = open_with_stat(&temp.0.join("a"));
        let file = nodes.insert(fd, &st, true);
        assert_eq!(nodes.cache_entry(ROOT, "a".as_ref()), TTL);
        assert!(nodes.by_id[&ROOT].watch.as_ref().unwrap().names.contains(OsStr::new("a")));
        assert_eq!(nodes.cache_entry(file, "x".as_ref()), Duration::ZERO);
        assert_eq!(nodes.cache_entry(INodeNo(12345), "x".as_ref()), Duration::ZERO);
    }

    #[test]
    fn cache_attr_rules() {
        let temp = Temp::new("nodes-cache-attr");
        let mut nodes = nodes(&temp);
        temp.write("one", "");
        temp.write("two", "");
        std::fs::hard_link(temp.0.join("two"), temp.0.join("two-again")).unwrap();
        temp.write("elsewhere", "");
        let mut insert = |name: &str, in_watched| {
            let (fd, st) = open_with_stat(&temp.0.join(name));
            (nodes.insert(fd, &st, in_watched), st)
        };
        let (one, one_st) = insert("one", true);
        let (two, two_st) = insert("two", true);
        let (elsewhere, elsewhere_st) = insert("elsewhere", false);
        let (_, root_st) = open_with_stat(&temp.0);
        // a watched dir
        assert_eq!(nodes.cache_attr(ROOT, &root_st), TTL);
        // a file with one name, in a watched dir
        assert_eq!(nodes.cache_attr(one, &one_st), TTL);
        assert!(nodes.by_id[&one].cached);
        // but not with another, whose changes go unseen
        assert_eq!(nodes.cache_attr(two, &two_st), Duration::ZERO);
        assert!(!nodes.by_id[&two].cached);
        assert_eq!(nodes.cache_attr(elsewhere, &elsewhere_st), Duration::ZERO);
        assert_eq!(nodes.cache_attr(INodeNo(12345), &one_st), Duration::ZERO);
        // which it forgets once it's no longer cached
        std::fs::hard_link(temp.0.join("one"), temp.0.join("one-again")).unwrap();
        let (_, one_st) = open_with_stat(&temp.0.join("one"));
        assert_eq!(nodes.cache_attr(one, &one_st), Duration::ZERO);
        assert!(!nodes.by_id[&one].cached);
    }
}
