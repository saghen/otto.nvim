//! What's recorded while the log is held: changes from outside, versions of files, removals and renames

use std::fs::File;
use std::io;
use std::os::fd::{AsFd, BorrowedFd};

use rustix::fs::{Mode, OFlags};

use super::log::{Last, Line, Log, Op};
use super::{By, Recorder, report};
use crate::fd_path;

/// The log, held while a change is compared and appended, see `Recorder::locked`. Without it when it couldn't be
/// read, when nothing's recorded, nor any blob copied
pub struct Locked<'a> {
    pub(super) recorder: &'a Recorder,
    pub(super) log: Option<&'a mut Log>,
}

impl Locked<'_> {
    pub(super) fn append(&mut self, line: Line) {
        let Some(log) = self.log.as_deref_mut() else { return };
        let what = line.op.path().map_or_else(|| "the agent's start".into(), str::to_string);
        if let Err(err) = log.append(line) {
            report(&what, &err);
        }
    }

    /// Copies what `file`, at `path`, holds now to its blob, and returns its hash
    fn store_blob(&self, path: &str, file: BorrowedFd) -> Option<String> {
        reopen(file).and_then(|file| self.recorder.blobs.store(&file)).inspect_err(|err| report(path, err)).ok()
    }

    /// Records what's on disk at `path` as a change from outside, when it isn't what the log last says, so the next
    /// change has the right before
    pub fn catch_up_outside(&mut self, path: &str) {
        let Some(log) = self.log.as_deref() else { return };
        if self.recorder.ignores.ignored(path, false) {
            return;
        }
        let flags = OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
        let hash = match rustix::fs::openat(&self.recorder.root, path, flags, Mode::empty()) {
            Ok(fd) => match self.recorder.blobs.store(&fd.into()) {
                Ok(hash) => Some(hash),
                Err(err) => return report(path, &err),
            },
            Err(rustix::io::Errno::NOENT) => None,
            Err(err) => return report(path, &err.into()),
        };
        if log.last(path).holds(hash.as_deref()) {
            return;
        }
        let op = match hash {
            Some(hash) => Op::Write { path: path.into(), hash, before: None },
            None => Op::Remove { path: path.into() },
        };
        self.append(self.recorder.line(op, None));
    }

    /// Records a version of `path`, what `file` holds now, if it changed. If another wrapper caught up on it as a
    /// change from outside since `since_offset`, the log offset when the change started, that was ours, all or in part
    pub fn write(&mut self, path: &str, file: BorrowedFd, by: &By, since_offset: Option<u64>) {
        let Some(log) = self.log.as_deref() else { return };
        // as of now, since a `.gitignore` could have changed since it was opened
        if self.recorder.ignores.ignored(path, false) {
            return;
        }
        let Some(hash) = self.store_blob(path, file) else { return };
        let before = match (log.outside.get(path), since_offset) {
            // which the log says otherwise of, so it says what was there before the change from outside
            (Some(outside), Some(since_offset)) if outside.offset >= since_offset => Some(outside.before.clone()),
            _ if log.last(path) == Last::Hash(&hash) => return,
            _ => None,
        };
        self.append(self.recorder.line(Op::Write { path: path.into(), hash, before }, Some(by)));
    }

    pub fn remove(&mut self, path: &str, by: &By) {
        if self.log.as_deref().is_some_and(|log| log.last(path) != Last::Removed) {
            self.append(self.recorder.line(Op::Remove { path: path.into() }, Some(by)));
        }
    }

    /// Records `from` renamed to `to`, each none when ignored, with what `file` holds now, none for a directory
    pub fn rename(&mut self, from: Option<&str>, to: Option<&str>, file: Option<BorrowedFd>, by: &By) {
        let Some(log) = self.log.as_deref() else { return };
        let line = |from: &str, to: &str, hash| {
            self.recorder.line(Op::Rename { from: from.into(), path: to.into(), hash }, Some(by))
        };
        match (from, to, file) {
            (Some(from), Some(to), Some(file)) => {
                let Some(hash) = self.store_blob(to, file) else { return };
                self.append(line(from, to, Some(hash)));
            }
            (Some(from), Some(to), None) => self.append(line(from, to, None)),
            // out of what's ignored, which is new as far as the log goes
            (None, Some(to), Some(file)) => self.write(to, file, by, None),
            (None, Some(to), None) => self.write_dir(to, by),
            // into it, which is gone, listed before any is removed
            (Some(from), None, Some(_)) => self.remove(from, by),
            (Some(from), None, None) => {
                for path in log.files_under(from) {
                    self.remove(&path, by);
                }
            }
            (None, None, _) => {}
        }
    }

    /// Records the files under `dir`, through the real workspace
    fn write_dir(&mut self, dir: &str, by: &By) {
        let entries = match std::fs::read_dir(fd_path(self.recorder.root.as_fd()).join(dir)) {
            Ok(entries) => entries,
            Err(err) => return report(dir, &err),
        };
        let mut entries: Vec<_> = entries.filter_map(|entry| entry.inspect_err(|err| report(dir, err)).ok()).collect();
        entries.sort_by_key(std::fs::DirEntry::file_name);
        for entry in entries {
            // which isn't recorded, like any path that isn't UTF-8
            let Some(path) = entry.file_name().to_str().map(|name| format!("{dir}/{name}")) else { continue };
            let kind = match entry.file_type() {
                Ok(kind) => kind,
                Err(err) => {
                    report(&path, &err);
                    continue;
                }
            };
            if self.recorder.ignores.ignored(&path, kind.is_dir()) {
                continue;
            }
            if kind.is_dir() {
                self.write_dir(&path, by);
            } else if kind.is_file() {
                match File::open(entry.path()) {
                    Ok(file) => self.write(&path, file.as_fd(), by, None),
                    Err(err) => report(&path, &err),
                }
            }
        }
    }
}

/// A fresh read-only file for what `fd` points to, at its start
fn reopen(fd: BorrowedFd) -> io::Result<File> {
    Ok(rustix::fs::open(fd_path(fd), OFlags::RDONLY | OFlags::CLOEXEC, Mode::empty())?.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record::tests::{open_path, recorder};
    use crate::test_util::Temp;

    #[test]
    fn renames_by_which_ends_are_recorded() {
        let temp = Temp::new("locked-rename");
        let (ws, _root, recorder) = recorder(&temp);
        let by = recorder.by(std::process::id());
        temp.write("ws/d/e/f", "f");
        temp.write("ws/g", "g");
        let g = open_path(&ws.join("g"));
        recorder.locked(|log| {
            log.rename(Some("a"), Some("g"), Some(g.as_fd()), &by);
            log.rename(Some("c"), Some("d"), None, &by);
            log.rename(None, Some("d"), None, &by);
            log.rename(Some("g"), None, Some(g.as_fd()), &by);
            log.rename(Some("d"), None, None, &by);
            // neither recorded
            log.rename(None, None, Some(g.as_fd()), &by);
            log.rename(None, None, None, &by);
        });
        assert_eq!(temp.ops(), ["rename a -> g", "rename c -> d", "write d/e/f", "remove g", "remove d/e/f"]);
    }

    #[test]
    fn nothing_is_recorded_or_copied_without_the_log() {
        let temp = Temp::new("locked-degraded");
        let (ws, _root, recorder) = recorder(&temp);
        let by = recorder.by(std::process::id());
        temp.write("ws/f", "f");
        let f = open_path(&ws.join("f"));
        let mut log = Locked { recorder: &recorder, log: None };
        log.catch_up_outside("f");
        log.write("f", f.as_fd(), &by, None);
        log.rename(Some("f"), Some("g"), Some(f.as_fd()), &by);
        log.remove("f", &by);
        assert_eq!(std::fs::read_dir(temp.0.join("store/blobs")).unwrap().count(), 0);
        assert_eq!(std::fs::read_to_string(temp.0.join("store/log.jsonl")).unwrap(), "");
    }
}
