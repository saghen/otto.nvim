//! What tells the kernel when the inodes it keeps change under it, from anyone

use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::mem::MaybeUninit;
use std::os::fd::OwnedFd;
use std::os::unix::ffi::OsStrExt;
use std::sync::Mutex;

use fuser::INodeNo;
use rustix::fs::inotify;

use super::nodes::{Kept, Nodes};
use crate::lock;

/// Tells the kernel what changed in the directories we watch, whoever changed it, so it can cache the rest. Between a
/// change and this, it may see what was there before
pub(super) fn forward_invalidations(nodes: &Mutex<Nodes>, inotify: &OwnedFd, device: &OwnedFd) {
    let mut buf = vec![MaybeUninit::uninit(); 64 * 1024];
    let mut reader = inotify::Reader::new(inotify, &mut buf);
    loop {
        // What's queued, each once
        let mut invalidations = Invalidations::default();
        let stopped = loop {
            match reader.next() {
                Ok(event) => lock(nodes).changed(&event, &mut invalidations),
                Err(rustix::io::Errno::INTR) => continue,
                Err(err) => {
                    eprintln!("otto-track: watching the workspace, which the kernel now caches nothing of: {err}");
                    invalidations.add_kept(lock(nodes).stop_watching());
                    break true;
                }
            }
            if reader.is_buffer_empty() {
                break false;
            }
        };
        // Not with the nodes held, since the kernel waits for lookups in flight, which need them
        invalidations.send(device);
        if stopped {
            return;
        }
    }
}

/// What of an inode the kernel keeps is stale, in order, so the more of two covers both
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub(super) enum Stale {
    Attributes,
    /// and contents, from their start
    Contents,
}

/// What the kernel keeps that changed: names in directories, and inodes
#[derive(Default, PartialEq, Eq, Debug)]
pub(super) struct Invalidations {
    pub(super) entries: HashSet<(INodeNo, OsString)>,
    inodes: HashMap<INodeNo, Stale>,
}

impl Invalidations {
    /// Adds the inode `id`, with what of it is `stale`, unless more of it already is
    pub(super) fn add_inode(&mut self, id: INodeNo, stale: Stale) {
        let at = self.inodes.entry(id).or_insert(stale);
        *at = stale.max(*at);
    }

    /// Adds everything the kernel kept, from `Nodes::take_kept`
    pub(super) fn add_kept(&mut self, kept: Kept) {
        for (id, names) in kept {
            self.add_inode(id, Stale::Contents);
            self.entries.extend(names.into_iter().map(|name| (id, name)));
        }
    }

    fn send(self, device: &OwnedFd) {
        for (dir, name) in self.entries {
            // Only expired, which fuser can't say, so the kernel looks it up again, but keeps it if it's the same.
            // Removing it would make the agent's open files look deleted
            let name = name.as_bytes();
            // within `NAME_MAX`
            let Ok(len) = u32::try_from(name.len()) else { continue };
            let len = len.to_ne_bytes();
            notify(device, INVAL_ENTRY, &[&dir.0.to_ne_bytes(), &len, &EXPIRE_ONLY.to_ne_bytes(), name, &[0]]);
        }
        for (id, stale) in self.inodes {
            // contents from this offset, -1 for none
            let offset: i64 = if stale == Stale::Contents { 0 } else { -1 };
            notify(device, INVAL_INODE, &[&id.0.to_ne_bytes(), &offset.to_ne_bytes(), &0i64.to_ne_bytes()]);
        }
    }
}

const INVAL_INODE: i32 = 2;
const INVAL_ENTRY: i32 = 3;
/// Since Linux 6.2, before which it's ignored
const EXPIRE_ONLY: u32 = 1;

/// Sends the kernel a notification, of nothing it may not have
fn notify(device: &OwnedFd, code: i32, body: &[&[u8]]) {
    let len = 16 + body.iter().map(|part| part.len()).sum::<usize>();
    let Ok(len_header) = u32::try_from(len) else { return };
    let mut message = Vec::with_capacity(len);
    message.extend(len_header.to_ne_bytes());
    message.extend(code.to_ne_bytes());
    message.extend(0u64.to_ne_bytes());
    for part in body {
        message.extend(*part);
    }
    // which fails only for what the kernel no longer has
    let _ = rustix::io::write(device, &message);
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use rustix::fs::OFlags;

    use super::*;
    use crate::fs::nodes::tests::{nodes, open_with_stat};
    use crate::fs::nodes::{ROOT, TTL};
    use crate::test_util::Temp;

    #[test]
    fn nothing_is_cached_once_watching_stops() {
        let temp = Temp::new("watch-stopped");
        let mut nodes = nodes(&temp);
        temp.write("a", "");
        std::fs::create_dir(temp.0.join("d")).unwrap();
        let (fd, a_st) = open_with_stat(&temp.0.join("a"));
        let a = nodes.insert(fd, &a_st, true);
        assert_eq!(nodes.cache_attr(a, &a_st), TTL);
        assert_eq!(nodes.cache_entry(ROOT, "a".as_ref()), TTL);
        let mut invalidations = Invalidations::default();
        invalidations.add_kept(nodes.stop_watching());
        // what the kernel kept, which it then looks up again
        assert_eq!(invalidations.entries, HashSet::from([(ROOT, OsString::from("a"))]));
        assert_eq!(invalidations.inodes, HashMap::from([(ROOT, Stale::Contents), (a, Stale::Contents)]));
        assert!(!nodes.cached(a));
        assert_eq!(nodes.cache_attr(a, &a_st), Duration::ZERO);
        let (_, root_st) = open_with_stat(&temp.0);
        assert_eq!(nodes.cache_attr(ROOT, &root_st), Duration::ZERO);
        assert_eq!(nodes.cache_entry(ROOT, "a".as_ref()), Duration::ZERO);
        // nor watches a directory looked up after
        let (fd, st) = open_with_stat(&temp.0.join("d"));
        let d = nodes.insert(fd, &st, false);
        assert!(!nodes.is_watched(d));
        assert_eq!(nodes.watches(), 0);
    }

    #[test]
    fn the_more_stale_of_two_covers_both() {
        let mut invalidations = Invalidations::default();
        invalidations.add_inode(ROOT, Stale::Attributes);
        invalidations.add_inode(ROOT, Stale::Contents);
        invalidations.add_inode(ROOT, Stale::Attributes);
        assert_eq!(invalidations.inodes, HashMap::from([(ROOT, Stale::Contents)]));
    }

    /// What the queued inotify events invalidate
    fn collected(nodes: &mut Nodes) -> Invalidations {
        let mut invalidations = Invalidations::default();
        let inotify = nodes.inotify.try_clone().unwrap();
        let mut buf = vec![MaybeUninit::uninit(); 64 * 1024];
        let mut reader = inotify::Reader::new(&inotify, &mut buf);
        while let Ok(event) = reader.next() {
            nodes.changed(&event, &mut invalidations);
        }
        invalidations
    }

    #[test]
    fn events_invalidate_entries_and_inodes() {
        let temp = Temp::new("watch-changed");
        let mut nodes = nodes(&temp);
        rustix::fs::fcntl_setfl(&nodes.inotify, OFlags::NONBLOCK).unwrap();
        temp.write("a", "");
        let (fd, st) = open_with_stat(&temp.0.join("a"));
        let a = nodes.insert(fd, &st, true);
        collected(&mut nodes);

        // a name the kernel keeps, and the listing
        nodes.cache_entry(ROOT, "new".as_ref());
        temp.write("new", "");
        temp.write("unkept", "");
        let invalidations = collected(&mut nodes);
        assert_eq!(invalidations.entries, HashSet::from([(ROOT, OsString::from("new"))]));
        assert_eq!(invalidations.inodes.get(&ROOT), Some(&Stale::Contents));
        // once, until it's looked up again
        std::fs::remove_file(temp.0.join("new")).unwrap();
        assert!(collected(&mut nodes).entries.is_empty());

        // contents
        temp.write("a", "more");
        assert_eq!(collected(&mut nodes).inodes, HashMap::from([(a, Stale::Contents)]));
        // attributes only
        std::fs::set_permissions(temp.0.join("a"), std::os::unix::fs::PermissionsExt::from_mode(0o600)).unwrap();
        assert_eq!(collected(&mut nodes).inodes, HashMap::from([(a, Stale::Attributes)]));
    }
}
