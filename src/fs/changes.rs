//! What the agent's handles change, and recording it

use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs::File;
use std::io;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use fuser::{FileHandle, INodeNo};
use rustix::fs::{AtFlags, FileType, Stat};

use super::Passthrough;
use crate::record::By;
use crate::{fd_path, lock};

/// How long an op waits for a change of the node it's about to change to be recorded, which only takes as long as the
/// log is held elsewhere. Past it, the change counts as from outside, which beats hanging the agent
const RECORDING_WAIT: Duration = Duration::from_secs(5);

/// The open files, by handle, and what tells waiters when their changes are recorded
#[derive(Default)]
pub(super) struct Files {
    opens: Mutex<Opens>,
    recorded: Condvar,
}

#[derive(Default)]
struct Opens {
    by_handle: HashMap<FileHandle, Arc<Open>>,
    /// The node of each take of changes that isn't in the log yet
    recording: Vec<INodeNo>,
}

impl Opens {
    /// Whether a change of the node is pending, or being recorded, or of any node for none
    fn unrecorded(&self, id: Option<INodeNo>) -> bool {
        let of = |node: INodeNo| id.is_none_or(|id| id == node);
        self.recording.iter().any(|&node| of(node))
            || self.by_handle.values().any(|open| of(open.id) && lock(&open.change).is_some())
    }
}

/// An open file of the node `id`, and what it changed since last recorded
pub(super) struct Open {
    pub(super) file: File,
    pub(super) id: INodeNo,
    pub(super) change: Mutex<Option<Change>>,
}

pub(super) struct Change {
    pub(super) by: By,
    /// Where the log was read up to when it started
    pub(super) since_offset: u64,
    /// Rather than only created or truncated it
    pub(super) written: bool,
}

impl Open {
    /// Marks it written, starting a change with `change` unless one's pending
    pub(super) fn mark_written(&self, change: impl FnOnce() -> Change) {
        lock(&self.change).get_or_insert_with(change).written = true;
    }
}

impl Files {
    pub(super) fn get(&self, fh: FileHandle) -> Option<Arc<Open>> {
        lock(&self.opens).by_handle.get(&fh).cloned()
    }

    pub(super) fn remove(&self, fh: FileHandle) {
        lock(&self.opens).by_handle.remove(&fh);
    }

    /// Takes the changes of `opens`, all of the node `id`, that `done` says are done. The only way changes are taken
    fn take_changes(
        &self,
        id: INodeNo,
        opens: impl IntoIterator<Item = Arc<Open>>,
        done: impl Fn(&mut Change) -> bool,
    ) -> Taken<'_> {
        // Counted first, so waiters see it either way, and not with a change held, which they lock after
        lock(&self.opens).recording.push(id);
        let mut taken = Taken { files: self, id, changes: Vec::new() };
        let take = |open: Arc<Open>| {
            let change = lock(&open.change).take_if(|change| done(change))?;
            Some((open, change))
        };
        taken.changes = opens.into_iter().filter_map(take).collect();
        taken
    }

    /// Waits while `unrecorded` holds, for at most `within`, and returns the opens once it doesn't, or none if it still
    /// does
    fn wait_while(&self, within: Duration, unrecorded: impl Fn(&Opens) -> bool) -> Option<MutexGuard<'_, Opens>> {
        let deadline = Instant::now() + within;
        let mut opens = lock(&self.opens);
        while unrecorded(&opens) {
            let left = deadline.checked_duration_since(Instant::now())?;
            opens = self.recorded.wait_timeout(opens, left).unwrap_or_else(PoisonError::into_inner).0;
        }
        Some(opens)
    }

    /// Waits until our handles' changes are recorded, like what the kernel releases after the agent exits, which it
    /// doesn't wait for, or until `within` passes
    pub(super) fn settle(&self, within: Duration) {
        self.wait_while(within, |opens| opens.unrecorded(None));
    }

    /// Whether a handle of ours changed the node and that isn't in the log yet, which makes what's on disk this
    /// agent's rather than a change from outside. Waits, for at most `within`, for one being recorded, so it's in the
    /// log first, past which it counts as from outside
    pub(super) fn has_unrecorded_change(&self, id: INodeNo, within: Duration) -> bool {
        self.wait_while(within, |opens| opens.recording.contains(&id)).is_some_and(|opens| opens.unrecorded(Some(id)))
    }
}

/// Changes taken from our handles of a node, which count as being recorded, so waiters wait, until this drops, which
/// must be after they're in the log
pub(super) struct Taken<'a> {
    files: &'a Files,
    id: INodeNo,
    pub(super) changes: Vec<(Arc<Open>, Change)>,
}

impl Drop for Taken<'_> {
    fn drop(&mut self) {
        let mut opens = lock(&self.files.opens);
        if let Some(i) = opens.recording.iter().position(|&id| id == self.id) {
            opens.recording.swap_remove(i);
        }
        drop(opens);
        self.files.recorded.notify_all();
    }
}

impl Passthrough {
    /// A change by the thread `tid` that starts now, which only created or truncated the file until it's marked
    /// written
    pub(super) fn new_change(&self, tid: u32) -> Change {
        Change { by: self.recorder.by(tid), since_offset: self.recorder.read_offset(), written: false }
    }

    pub(super) fn add_file(&self, fd: OwnedFd, id: INodeNo, change: Option<Change>) -> FileHandle {
        let fh = self.next_handle();
        let open = Open { file: fd.into(), id, change: Mutex::new(change) };
        lock(&self.files.opens).by_handle.insert(fh, Arc::new(open));
        fh
    }

    /// The recorded path of `name` in `dir`, if it's a file or nothing, which may have been removed, and whether to
    /// catch up on changes from outside to it before replacing or removing it, unless this agent is changing it. Waits
    /// while a change of it is being recorded, so not with the log held, which that needs
    pub(super) fn recorded_name(&self, dir: BorrowedFd, name: &OsStr) -> Option<(String, bool)> {
        let path = self.recorder.child_path(dir, name, false)?;
        let id = match rustix::fs::statat(dir, name, AtFlags::SYMLINK_NOFOLLOW) {
            Err(rustix::io::Errno::NOENT) => None,
            Ok(st) if FileType::from_raw_mode(st.st_mode) == FileType::RegularFile => lock(&self.nodes).id_of(&st),
            _ => return None,
        };
        Some((path, !id.is_some_and(|id| self.files.has_unrecorded_change(id, RECORDING_WAIT))))
    }

    /// Of `recorded_name`, the path to catch up on, if any
    pub(super) fn name_to_catch_up(&self, dir: BorrowedFd, name: &OsStr) -> Option<String> {
        self.recorded_name(dir, name).and_then(|(path, catch_up)| catch_up.then_some(path))
    }

    /// Like `name_to_catch_up`, of the node `id`, through its fd
    pub(super) fn node_to_catch_up(&self, id: INodeNo, fd: BorrowedFd) -> Option<String> {
        self.recorder.path(fd).filter(|_| !self.files.has_unrecorded_change(id, RECORDING_WAIT))
    }

    /// Records the changes from outside to `path`, if any, before the agent changes it
    pub(super) fn catch_up(&self, path: Option<String>) {
        if let Some(path) = path {
            self.recorder.locked(|log| log.catch_up_outside(&path));
        }
    }

    /// Takes the changes that our handles of the inode `st` made and that aren't recorded yet
    pub(super) fn take_pending_changes(&self, st: &Stat) -> Option<Taken<'_>> {
        let id = lock(&self.nodes).id_of(st)?;
        let opens: Vec<_> = lock(&self.files.opens).by_handle.values().filter(|open| open.id == id).cloned().collect();
        Some(self.files.take_changes(id, opens, |_| true))
    }

    /// Records what the file holds now, if the handle changed it since last time. Until it's `released`, only once it
    /// wrote to it or its process closed it, since shells close a redirect's file once before writing to it
    pub(super) fn record(&self, open: &Arc<Open>, released: bool) {
        let path = self.recorder.path(open.file.as_fd());
        let done = |change: &mut Change| {
            released || change.written || path.as_ref().is_none_or(|path| !self.recorder.has_open(&change.by, path))
        };
        let taken = self.files.take_changes(open.id, [open.clone()], done);
        let Some((_, change)) = taken.changes.first() else { return };
        // as of now, since a rename or removal could have come first
        self.recorder.locked(|log| {
            if let Some(path) = self.recorder.path(open.file.as_fd()) {
                log.write(&path, open.file.as_fd(), &change.by, Some(change.since_offset));
            }
        });
    }

    /// Runs `remove`, which removes or replaces the file of `recorded_name`, holding the log, and records it removed
    /// by `tid`
    pub(super) fn remove_recorded(
        &self,
        tid: u32,
        (path, catch_up): (String, bool),
        remove: impl FnOnce() -> io::Result<()>,
    ) -> io::Result<()> {
        self.recorder.locked(|log| {
            if catch_up {
                log.catch_up_outside(&path);
            }
            remove()?;
            log.remove(&path, &self.recorder.by(tid));
            Ok(())
        })
    }

    /// Truncates or extends the node's file, through the agent's handle `fh` when it has one
    pub(super) fn set_size(
        &self,
        tid: u32,
        id: INodeNo,
        fd: BorrowedFd,
        fh: Option<FileHandle>,
        size: u64,
    ) -> io::Result<()> {
        if let Some(fh) = fh {
            let open = self.file(fh)?;
            open.mark_written(|| self.new_change(tid));
            return open.file.set_len(size);
        }
        // Like `truncate(2)`, with no handle to record it when released
        let truncate = || File::options().write(true).open(fd_path(fd))?.set_len(size);
        let Some(recorded) = self.node_to_catch_up(id, fd) else { return truncate() };
        self.recorder.locked(|log| {
            log.catch_up_outside(&recorded);
            truncate()?;
            log.write(&recorded, fd, &self.recorder.by(tid), None);
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, Ordering};

    use rustix::fs::OFlags;

    use super::*;
    use crate::fs::nodes::ROOT;
    use crate::fs::tests::{open, passthrough, workspace};

    #[test]
    fn recorded_name_of_files_and_nothing_only() {
        let temp = workspace("changes-named");
        let fs = passthrough(&temp);
        let ws = temp.0.join("ws");
        temp.write("ws/.gitignore", "*.gen\n");
        temp.write("ws/file", "");
        std::fs::create_dir(ws.join("dir")).unwrap();
        let root = open(&ws, OFlags::PATH | OFlags::DIRECTORY);
        let named = |name: &str| fs.recorded_name(root.as_fd(), name.as_ref());
        let to_catch_up = |name: &str| fs.name_to_catch_up(root.as_fd(), name.as_ref());
        // with no handle of ours writing it, so a change from outside
        assert_eq!(named("file"), Some(("file".into(), true)));
        assert_eq!(named("new"), Some(("new".into(), true)));
        assert_eq!(named("dir"), None);
        assert_eq!(named("a.gen"), None);
        assert_eq!(to_catch_up("file").as_deref(), Some("file"));
        // but this agent's while a handle of ours changed it
        let id = fs.lookup_child(ROOT, "file".as_ref()).unwrap().attr.ino;
        fs.add_file(open(&ws.join("file"), OFlags::RDONLY), id, Some(fs.new_change(std::process::id())));
        assert_eq!(named("file"), Some(("file".into(), false)));
        assert_eq!(to_catch_up("file"), None);
        assert_eq!(to_catch_up("new").as_deref(), Some("new"));
    }

    /// A file in the workspace, open with a change pending
    fn pending(fs: &Passthrough, temp: &crate::test_util::Temp) -> (INodeNo, Arc<Open>) {
        temp.write("ws/file", "");
        let id = fs.lookup_child(ROOT, "file".as_ref()).unwrap().attr.ino;
        let fh = fs.add_file(open(&temp.0.join("ws/file"), OFlags::RDONLY), id, Some(fs.new_change(1)));
        (id, fs.files.get(fh).unwrap())
    }

    #[test]
    fn settle_waits_for_changes_to_be_recorded() {
        let temp = workspace("changes-settle");
        let fs = passthrough(&temp);
        // with none
        let start = Instant::now();
        fs.files.settle(Duration::from_secs(5));
        assert!(start.elapsed() < Duration::from_secs(1));
        let (id, open) = pending(&fs, &temp);
        // until the deadline, with one never recorded
        let start = Instant::now();
        fs.files.settle(Duration::from_millis(50));
        assert!(start.elapsed() >= Duration::from_millis(50));
        // or until it's recorded, which wakes it
        let (recorded, files) = (Arc::new(AtomicBool::new(false)), fs.files.clone());
        let recording = std::thread::spawn({
            let recorded = recorded.clone();
            move || {
                let taken = files.take_changes(id, [open], |_| true);
                assert_eq!(taken.changes.len(), 1);
                std::thread::sleep(Duration::from_millis(50));
                recorded.store(true, Ordering::SeqCst);
                drop(taken);
            }
        });
        fs.files.settle(Duration::from_secs(5));
        assert!(recorded.load(Ordering::SeqCst));
        recording.join().unwrap();
        assert!(lock(&fs.files.opens).recording.is_empty());
    }

    #[test]
    fn has_unrecorded_change_waits_for_one_being_recorded() {
        let temp = workspace("changes-unrecorded");
        let fs = passthrough(&temp);
        let (id, open) = pending(&fs, &temp);
        assert!(fs.files.has_unrecorded_change(id, RECORDING_WAIT));
        let (recorded, files) = (Arc::new(AtomicBool::new(false)), fs.files.clone());
        let (taken_tx, taken_rx) = std::sync::mpsc::channel();
        let recording = std::thread::spawn({
            let recorded = recorded.clone();
            move || {
                let taken = files.take_changes(id, [open], |_| true);
                taken_tx.send(()).unwrap();
                std::thread::sleep(Duration::from_millis(50));
                recorded.store(true, Ordering::SeqCst);
                drop(taken);
            }
        });
        taken_rx.recv().unwrap();
        // once it's in the log, after which it's not this agent's to catch up on
        assert!(!fs.files.has_unrecorded_change(id, RECORDING_WAIT));
        assert!(recorded.load(Ordering::SeqCst));
        recording.join().unwrap();
    }

    #[test]
    fn a_change_recorded_for_too_long_counts_as_from_outside() {
        let temp = workspace("changes-wait-out");
        let fs = passthrough(&temp);
        let (id, open) = pending(&fs, &temp);
        // and another, still pending, which it would be this agent's by otherwise
        fs.add_file(open.file.try_clone().unwrap().into(), id, Some(fs.new_change(1)));
        let taken = fs.files.take_changes(id, [open], |_| true);
        let start = Instant::now();
        assert!(!fs.files.has_unrecorded_change(id, Duration::from_millis(50)));
        assert!(start.elapsed() >= Duration::from_millis(50));
        drop(taken);
        assert!(fs.files.has_unrecorded_change(id, Duration::ZERO));
    }

    #[test]
    fn pending_changes_count_as_being_recorded() {
        let temp = workspace("changes-pending");
        let fs = passthrough(&temp);
        let (id, _open) = pending(&fs, &temp);
        let st = rustix::fs::stat(temp.0.join("ws/file")).unwrap();
        let taken = fs.take_pending_changes(&st).unwrap();
        assert_eq!(taken.changes.len(), 1);
        // until they're in the log, which dropping them says
        let start = Instant::now();
        fs.files.settle(Duration::from_millis(50));
        assert!(start.elapsed() >= Duration::from_millis(50));
        drop(taken);
        assert!(!fs.files.has_unrecorded_change(id, Duration::ZERO));
    }
}
