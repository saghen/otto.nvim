//! Renames, which move what the log knows of, or replace or exchange it

use std::ffi::OsStr;
use std::io;
use std::os::fd::{AsFd, BorrowedFd};

use rustix::fs::{AtFlags, FileType, RenameFlags};

use super::{Passthrough, path_fd};

impl Passthrough {
    /// Renames `name` in `from` to `newname` in `to`, as the thread `tid` asks, and records it
    pub(super) fn rename_recording(
        &self,
        tid: u32,
        from: BorrowedFd,
        name: &OsStr,
        to: BorrowedFd,
        newname: &OsStr,
        flags: RenameFlags,
    ) -> io::Result<()> {
        let rename = || Ok(rustix::fs::renameat_with(from, name, to, newname, flags)?);
        let st = rustix::fs::statat(from, name, AtFlags::SYMLINK_NOFOLLOW)?;
        let kind = FileType::from_raw_mode(st.st_mode);
        let (is_file, is_dir) = (kind == FileType::RegularFile, kind == FileType::Directory);
        // Like a symlink, which isn't recorded, unless it replaces a file, like `ln -sf`'s, which is then gone
        if !is_file && !is_dir {
            let over_file = || {
                let st = rustix::fs::statat(to, newname, AtFlags::SYMLINK_NOFOLLOW);
                st.is_ok_and(|st| FileType::from_raw_mode(st.st_mode).is_file())
            };
            return match self.recorded_name(to, newname).filter(|_| over_file()) {
                Some(replaced) => self.remove_recorded(tid, replaced, rename),
                None => rename(),
            };
        }
        // What it replaces, to catch up on as changes from outside first, so they have the right before. Before the
        // pending changes are taken, which would count them as from outside
        let exchange = flags.contains(RenameFlags::EXCHANGE);
        let to_named = self.recorded_name(to, newname);
        // of an exchange, what moves to the old name
        let target = to_named.as_ref().filter(|_| exchange).and_then(|_| path_fd(to, newname).ok());
        let replaced_to = to_named.and_then(|(path, catch_up)| catch_up.then_some(path));
        let replaced_from = if exchange { self.name_to_catch_up(from, name) } else { None };

        let from_path = self.recorder.child_path(from, name, is_dir);
        let to_path = self.recorder.child_path(to, newname, is_dir);
        if from_path.is_none() && to_path.is_none() {
            return rename();
        }
        // Before it moves, which another process could follow it with
        let source = if is_file { Some(path_fd(from, name)?) } else { None };
        // Like a temp file moved before it's closed, whose writes then come from its path
        let pending = if is_file && from_path.is_some() { self.take_pending_changes(&st) } else { None };
        self.recorder.locked(|log| {
            for path in [&replaced_to, &replaced_from].into_iter().flatten() {
                log.catch_up_outside(path);
            }
            // as of the path they were made at
            if let (Some(path), Some(pending)) = (&from_path, &pending) {
                for (open, change) in &pending.changes {
                    log.write(path, open.file.as_fd(), &change.by, Some(change.since_offset));
                }
            }
            rename()?;
            let by = self.recorder.by(tid);
            if exchange {
                // each holds what the other did
                if let (Some(path), Some(file)) = (&to_path, &source) {
                    log.write(path, file.as_fd(), &by, None);
                }
                if let (Some(path), Some(file)) = (&from_path, &target) {
                    log.write(path, file.as_fd(), &by, None);
                }
            } else {
                // in the log, or out of or into what it ignores
                log.rename(from_path.as_deref(), to_path.as_deref(), source.as_ref().map(AsFd::as_fd), &by);
            }
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use rustix::fs::OFlags;

    use super::*;
    use crate::fs::tests::{open, passthrough, workspace};
    use crate::test_util::Temp;

    /// Renames `name` to `newname`, both in the workspace's root, as this process
    fn rename(temp: &Temp, fs: &Passthrough, name: &str, newname: &str, flags: RenameFlags) {
        let root = open(&temp.0.join("ws"), OFlags::PATH | OFlags::DIRECTORY);
        let (name, newname) = (name.as_ref(), newname.as_ref());
        fs.rename_recording(std::process::id(), root.as_fd(), name, root.as_fd(), newname, flags).unwrap();
    }

    #[test]
    fn files_and_directories_move_in_and_out_of_whats_ignored() {
        let temp = workspace("rename-moves");
        let fs = passthrough(&temp);
        temp.write("ws/.gitignore", "*.gen\n");
        temp.write("ws/a", "a");
        temp.write("ws/c.gen", "c");
        temp.write("ws/d/f", "f");
        rename(&temp, &fs, "a", "b", RenameFlags::empty());
        rename(&temp, &fs, "b", "b.gen", RenameFlags::empty());
        rename(&temp, &fs, "c.gen", "c", RenameFlags::empty());
        rename(&temp, &fs, "d", "e", RenameFlags::empty());
        assert_eq!(temp.ops(), ["rename a -> b", "remove b", "write c", "rename d -> e"]);
    }

    #[test]
    fn a_symlink_over_a_file_removes_it() {
        let temp = workspace("rename-symlink");
        let fs = passthrough(&temp);
        temp.write("ws/f", "old");
        std::os::unix::fs::symlink("elsewhere", temp.0.join("ws/s")).unwrap();
        rename(&temp, &fs, "s", "f", RenameFlags::empty());
        // with what it held, as a change from outside
        assert_eq!(temp.ops(), ["- write f", "remove f"]);
        // but not over nothing, which isn't recorded
        std::os::unix::fs::symlink("elsewhere", temp.0.join("ws/t")).unwrap();
        rename(&temp, &fs, "t", "u", RenameFlags::empty());
        assert_eq!(temp.ops().len(), 2);
    }

    #[test]
    fn an_exchange_writes_each() {
        let temp = workspace("rename-exchange");
        let fs = passthrough(&temp);
        temp.write("ws/x", "one");
        temp.write("ws/y", "two");
        rename(&temp, &fs, "x", "y", RenameFlags::EXCHANGE);
        assert_eq!(std::fs::read_to_string(temp.0.join("ws/x")).unwrap(), "two");
        assert_eq!(temp.ops(), ["- write y", "- write x", "write y", "write x"]);
    }

    #[test]
    fn pending_changes_are_written_first() {
        let temp = workspace("rename-pending");
        let fs = passthrough(&temp);
        temp.write("ws/t", "new");
        let id = fs.lookup_child(crate::fs::nodes::ROOT, "t".as_ref()).unwrap().attr.ino;
        let file = open(&temp.0.join("ws/t"), OFlags::RDONLY);
        fs.add_file(file, id, Some(fs.new_change(std::process::id())));
        rename(&temp, &fs, "t", "f", RenameFlags::empty());
        assert_eq!(temp.ops(), ["write t", "rename t -> f"]);
        // and taken, so not again
        assert!(!fs.files.has_unrecorded_change(id, std::time::Duration::ZERO));
    }

    #[test]
    fn an_exchange_of_a_file_with_pending_changes_writes_them_as_its_own() {
        let temp = workspace("rename-exchange-pending");
        let fs = passthrough(&temp);
        temp.write("ws/t", "new");
        temp.write("ws/u", "old");
        let id = fs.lookup_child(crate::fs::nodes::ROOT, "t".as_ref()).unwrap().attr.ino;
        let file = open(&temp.0.join("ws/t"), OFlags::RDONLY);
        fs.add_file(file, id, Some(fs.new_change(std::process::id())));
        rename(&temp, &fs, "t", "u", RenameFlags::EXCHANGE);
        // so not as from outside
        assert_eq!(temp.ops(), ["- write u", "write t", "write u", "write t"]);
    }
}
