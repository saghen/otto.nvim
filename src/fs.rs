//! A passthrough filesystem with an `O_PATH` fd per inode the kernel knows of, like virtiofsd, which records what the
//! agent changes through it, see `changes` and `rename`

mod attr;
mod changes;
mod nodes;
mod ops;
mod rename;
mod watch;

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::io;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use fuser::{
    Errno, FileAttr, FileHandle, FileType, FopenFlags, Generation, INodeNo, ReplyAttr, ReplyData, ReplyEmpty,
    ReplyEntry,
};
use rustix::fs::{Mode, OFlags};

use crate::record::Recorder;
use crate::{fd_path, lock};
use attr::{attr, kind};
use changes::{Files, Open};
use nodes::Nodes;
use watch::forward_invalidations;

pub struct Mount {
    _session: fuser::BackgroundSession,
    files: Arc<Files>,
}

impl Mount {
    /// Waits a moment for the kernel to release what the agent closed, which it doesn't wait for, and for that to be
    /// recorded
    pub fn settle(&self) {
        self.files.settle(Duration::from_secs(1));
    }
}

pub fn serve(fuse: OwnedFd, root: OwnedFd, recorder: Arc<Recorder>) -> io::Result<Mount> {
    let fs = Passthrough::new(root, recorder)?;
    let (files, nodes) = (fs.files.clone(), fs.nodes.clone());
    let inotify = lock(&nodes).inotify.try_clone()?;
    let mut config = fuser::Config::default();
    config.n_threads = Some(std::thread::available_parallelism().map_or(4, std::num::NonZero::get));
    config.clone_fd = true;
    let device = fuse.try_clone()?;
    let session = fuser::Session::from_fd(fs, fuse, fuser::SessionACL::Owner, config)?.spawn()?;
    std::thread::spawn(move || forward_invalidations(&nodes, &inotify, &device));
    Ok(Mount { _session: session, files })
}

/// An `O_PATH` fd of `name` in `dir`, without following it
fn path_fd(dir: BorrowedFd, name: &OsStr) -> io::Result<OwnedFd> {
    Ok(rustix::fs::openat(dir, name, OFlags::PATH | OFlags::NOFOLLOW | OFlags::CLOEXEC, Mode::empty())?)
}

/// A directory's entries, each by its real inode number
type Listing = Vec<(u64, FileType, OsString)>;

/// An open directory, and its listing as of when it was last read from the start
struct Dir {
    fd: OwnedFd,
    listing: Mutex<Listing>,
}

struct Passthrough {
    recorder: Arc<Recorder>,
    nodes: Arc<Mutex<Nodes>>,
    files: Arc<Files>,
    dirs: Mutex<HashMap<FileHandle, Arc<Dir>>>,
    next_handle: AtomicU64,
}

/// What a lookup found, and how long the kernel may keep its attributes and the entry
#[derive(Debug)]
struct Lookup {
    attr: FileAttr,
    attr_ttl: Duration,
    entry_ttl: Duration,
}

fn reply_entry(reply: ReplyEntry, result: io::Result<Lookup>) {
    match result {
        Ok(found) => reply.entry_with_ttls(&found.attr_ttl, &found.entry_ttl, &found.attr, Generation(0)),
        Err(err) => reply.error(Errno::from(err)),
    }
}

/// With the attributes, and how long the kernel may keep them
fn reply_attr(reply: ReplyAttr, result: io::Result<(FileAttr, Duration)>) {
    match result {
        Ok((attr, ttl)) => reply.attr(&ttl, &attr),
        Err(err) => reply.error(Errno::from(err)),
    }
}

fn reply_empty(reply: ReplyEmpty, result: io::Result<()>) {
    match result {
        Ok(()) => reply.ok(),
        Err(err) => reply.error(Errno::from(err)),
    }
}

fn reply_data(reply: ReplyData, result: io::Result<Vec<u8>>) {
    match result {
        Ok(data) => reply.data(&data),
        Err(err) => reply.error(Errno::from(err)),
    }
}

impl Passthrough {
    fn new(root: OwnedFd, recorder: Arc<Recorder>) -> io::Result<Self> {
        Ok(Self {
            recorder,
            nodes: Arc::new(Mutex::new(Nodes::new(root)?)),
            files: Arc::default(),
            dirs: Mutex::default(),
            next_handle: AtomicU64::new(1),
        })
    }

    /// Runs `f` with a duplicate of the node's fd, which a forget could close meanwhile
    fn with_node<T>(&self, id: INodeNo, f: impl FnOnce(BorrowedFd) -> io::Result<T>) -> io::Result<T> {
        let fd = lock(&self.nodes).fd(id)?;
        f(fd.as_fd())
    }

    /// Whether the kernel may keep what it read of the node, as of its attributes, which `forward_invalidations`
    /// invalidates with them
    fn cache_flags(&self, id: INodeNo) -> FopenFlags {
        if lock(&self.nodes).cached(id) { FopenFlags::FOPEN_KEEP_CACHE } else { FopenFlags::empty() }
    }

    fn file(&self, fh: FileHandle) -> io::Result<Arc<Open>> {
        self.files.get(fh).ok_or(io::Error::from(rustix::io::Errno::BADF))
    }

    fn dir(&self, fh: FileHandle) -> io::Result<Arc<Dir>> {
        lock(&self.dirs).get(&fh).cloned().ok_or(io::Error::from(rustix::io::Errno::BADF))
    }

    fn next_handle(&self) -> FileHandle {
        FileHandle(self.next_handle.fetch_add(1, Ordering::Relaxed))
    }

    /// Looks up `name` in `parent`, counting a lookup the kernel now holds
    fn lookup_child(&self, parent: INodeNo, name: &OsStr) -> io::Result<Lookup> {
        let fd = self.with_node(parent, |dir| path_fd(dir, name))?;
        self.add_lookup(parent, name, fd)
    }

    fn add_lookup(&self, parent: INodeNo, name: &OsStr, fd: OwnedFd) -> io::Result<Lookup> {
        let st = rustix::fs::fstat(&fd)?;
        let mut nodes = lock(&self.nodes);
        let entry_ttl = nodes.cache_entry(parent, name);
        let id = nodes.insert(fd, &st, !entry_ttl.is_zero());
        Ok(Lookup { attr: attr(id, &st), attr_ttl: nodes.cache_attr(id, &st), entry_ttl })
    }

    /// The node's attributes, and how long the kernel may keep them, recording that it does, see `Nodes::cache_attr`
    fn get_attr(&self, id: INodeNo, fd: BorrowedFd) -> io::Result<(FileAttr, Duration)> {
        let st = rustix::fs::fstat(fd)?;
        Ok((attr(id, &st), lock(&self.nodes).cache_attr(id, &st)))
    }

    /// Creates `name` in `parent` with `make`, and looks it up
    fn make(
        &self,
        parent: INodeNo,
        name: &OsStr,
        make: impl FnOnce(BorrowedFd) -> rustix::io::Result<()>,
    ) -> io::Result<Lookup> {
        self.with_node(parent, |dir| Ok(make(dir)?))?;
        self.lookup_child(parent, name)
    }

    /// Opens the node's inode for real, with the flags the agent opened it with
    fn reopen(&self, id: INodeNo, flags: OFlags) -> io::Result<OwnedFd> {
        // The kernel followed symlinks already, and creating goes through `create`
        let flags = (flags - (OFlags::NOFOLLOW | OFlags::CREATE | OFlags::EXCL | OFlags::DIRECT)) | OFlags::CLOEXEC;
        self.with_node(id, |fd| Ok(rustix::fs::open(fd_path(fd), flags, Mode::empty())?))
    }

    fn read_dir(fd: &OwnedFd) -> io::Result<Listing> {
        let mut dir = rustix::fs::Dir::read_from(fd)?;
        let mut listing = Vec::new();
        while let Some(entry) = dir.read() {
            let entry = entry?;
            let name = OsStr::from_bytes(entry.file_name().to_bytes()).into();
            listing.push((entry.ino(), kind(entry.file_type()), name));
        }
        Ok(listing)
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;
    use crate::test_util::Temp;
    use nodes::{ROOT, TTL};

    /// With a workspace, the top of its repo, at `ws`
    pub(super) fn workspace(name: &str) -> Temp {
        let temp = Temp::new(name);
        std::fs::create_dir_all(temp.0.join("ws/.git")).unwrap();
        temp
    }

    pub(super) fn open(path: &Path, flags: OFlags) -> OwnedFd {
        rustix::fs::open(path, flags | OFlags::CLOEXEC, Mode::empty()).unwrap()
    }

    /// Over the workspace, with a store beside it
    pub(super) fn passthrough(temp: &Temp) -> Passthrough {
        let root = open(&temp.0.join("ws"), OFlags::PATH | OFlags::DIRECTORY);
        let recorder = Recorder::new(&temp.0.join("store"), "x".into(), root.as_fd()).unwrap();
        Passthrough::new(root, Arc::new(recorder)).unwrap()
    }

    #[test]
    fn read_dir_lists_entries_with_kinds() {
        let temp = workspace("fs-read-dir");
        let ws = temp.0.join("ws");
        temp.write("ws/file", "");
        std::os::unix::fs::symlink("file", ws.join("link")).unwrap();
        let mut listing = Passthrough::read_dir(&open(&ws, OFlags::RDONLY | OFlags::DIRECTORY)).unwrap();
        listing.sort_by(|a, b| a.2.cmp(&b.2));
        let kinds: Vec<_> = listing.iter().map(|(_, kind, name)| (name.to_str().unwrap(), *kind)).collect();
        assert_eq!(
            kinds,
            [
                (".", FileType::Directory),
                ("..", FileType::Directory),
                (".git", FileType::Directory),
                ("file", FileType::RegularFile),
                ("link", FileType::Symlink),
            ]
        );
        let (ino, ..) = listing.iter().find(|(.., name)| name == "file").unwrap();
        assert_eq!(*ino, rustix::fs::lstat(ws.join("file")).unwrap().st_ino);
    }

    #[test]
    fn with_node_of_an_unknown_inode_is_stale() {
        let temp = workspace("fs-stale");
        let fs = passthrough(&temp);
        let err = fs.with_node(INodeNo(12345), |_| Ok(())).unwrap_err();
        assert_eq!(err.raw_os_error(), Some(rustix::io::Errno::STALE.raw_os_error()));
        let st = fs.with_node(ROOT, |fd| Ok(rustix::fs::fstat(fd)?)).unwrap();
        assert_eq!(st.st_ino, rustix::fs::stat(temp.0.join("ws")).unwrap().st_ino);
    }

    #[test]
    fn lookup_child_adds_a_node() {
        let temp = workspace("fs-lookup");
        let fs = passthrough(&temp);
        temp.write("ws/file", "hello");
        let found = fs.lookup_child(ROOT, "file".as_ref()).unwrap();
        assert_eq!(found.attr.ino.0, rustix::fs::stat(temp.0.join("ws/file")).unwrap().st_ino);
        assert_eq!((found.attr.size, found.attr.kind), (5, FileType::RegularFile));
        // in the watched root
        assert_eq!((found.attr_ttl, found.entry_ttl), (TTL, TTL));
        let again = fs.lookup_child(ROOT, "file".as_ref()).unwrap();
        assert_eq!(again.attr.ino, found.attr.ino);
        assert_eq!(lock(&fs.nodes).lookups(found.attr.ino), 2);
        let err = fs.lookup_child(ROOT, "missing".as_ref()).unwrap_err();
        assert_eq!(err.raw_os_error(), Some(rustix::io::Errno::NOENT.raw_os_error()));
    }

    #[test]
    fn first_open_of_removed_once() {
        let temp = workspace("fs-removed");
        let fs = passthrough(&temp);
        temp.write("ws/file", "");
        let id = fs.lookup_child(ROOT, "file".as_ref()).unwrap().attr.ino;
        let first_open_of_removed = |id| lock(&fs.nodes).first_open_of_removed(id);
        assert!(!first_open_of_removed(id));
        std::fs::remove_file(temp.0.join("ws/file")).unwrap();
        assert!(first_open_of_removed(id));
        // since the next open is on purpose
        assert!(!first_open_of_removed(id));
        assert!(!first_open_of_removed(INodeNo(12345)));
    }

    #[test]
    fn unknown_handles_are_bad() {
        let temp = workspace("fs-handles");
        let fs = passthrough(&temp);
        let err = fs.file(FileHandle(12345)).err().unwrap();
        assert_eq!(err.raw_os_error(), Some(rustix::io::Errno::BADF.raw_os_error()));
        let err = fs.dir(FileHandle(12345)).err().unwrap();
        assert_eq!(err.raw_os_error(), Some(rustix::io::Errno::BADF.raw_os_error()));
    }
}
