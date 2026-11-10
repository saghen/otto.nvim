//! Records each change to the workspace in the store, which every agent's wrapper shares:
//! `log.jsonl`, a line per change in the order they happened, and `blobs/<hash>`, the contents. Each says who made it,
//! from `/proc`: the process, and the agent's tool call it's part of. What git ignores isn't recorded

mod blobs;
mod ignores;
mod locked;
mod log;

use std::ffi::OsStr;
use std::fs::File;
use std::io;
use std::os::fd::{BorrowedFd, OwnedFd};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use rustix::fs::AtFlags;
use rustix::process::Pid;

use crate::{fd_path, lock};
use blobs::Blobs;
use ignores::Ignores;
use log::{Line, Log, Op};

pub use locked::Locked;

/// Who made a change: the process, its command, and the command lines of the processes from the agent's child down to
/// it, which tell the agent's tool calls apart, even under a launcher like npm's
pub struct By {
    pid: u32,
    cmd: String,
    commands: Option<Vec<Vec<String>>>,
}

fn parent(pid: u32) -> Option<u32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // After the command, which can have spaces and parentheses
    stat[stat.rfind(')')? + 2..].split(' ').nth(1)?.parse().ok()
}

pub struct Recorder {
    agent: String,
    /// The real workspace, under the mount
    root: OwnedFd,
    root_path: PathBuf,
    blobs: Blobs,
    log: Mutex<Log>,
    /// Of the log, see `read_offset`
    read: AtomicU64,
    ignores: Ignores,
    /// Of the agent, once it's started, until when it's 0
    agent_pid: AtomicU32,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

impl Recorder {
    pub fn new(store: &Path, agent: String, root: BorrowedFd) -> io::Result<Self> {
        let blobs = Blobs::new(store.join("blobs"))?;
        // Only for us, like the blobs, since it has the agent's command lines
        let file = File::options().read(true).append(true).create(true).mode(0o600).open(store.join("log.jsonl"))?;
        let root_path = std::fs::read_link(fd_path(root))?;
        let root = root.try_clone_to_owned()?;
        let ignores = Ignores::new(root.try_clone()?, &root_path);
        let log = Mutex::new(Log::new(file));
        let (read, agent_pid) = (AtomicU64::new(0), AtomicU32::new(0));
        Ok(Self { agent, root, root_path, blobs, log, read, ignores, agent_pid })
    }

    /// Runs `f` holding the log, in this process and across them, so that what it records is in the order it
    /// happened. Recording fails quietly, since what the agent does mustn't
    pub fn locked<T>(&self, f: impl FnOnce(&mut Locked) -> T) -> T {
        let mut held = Held { recorder: self, log: lock(&self.log) };
        let readable = held.log.hold().inspect_err(|err| eprintln!("otto-track: reading the log: {err}")).is_ok();
        f(&mut Locked { recorder: self, log: readable.then_some(&mut *held.log) })
    }

    /// Where the log has been read up to, which changes after it are past. As of the last time it was held, without
    /// waiting for whoever holds it now, which a change starting meanwhile doesn't follow anyway
    pub fn read_offset(&self) -> u64 {
        self.read.load(Ordering::Relaxed)
    }

    /// A line of `op` that happened now, by `by`, or from outside for none
    fn line(&self, op: Op, by: Option<&By>) -> Line {
        Line {
            at: now(),
            agent: by.map(|_| self.agent.clone()),
            pid: by.map(|by| by.pid),
            cmd: by.map(|by| by.cmd.clone()),
            commands: by.and_then(|by| by.commands.clone()),
            ..Line::new(op)
        }
    }

    /// Starts the agent with `spawn`, holding the log so its `start` comes before its changes
    pub fn start(&self, spawn: impl FnOnce() -> io::Result<Pid>) -> io::Result<Pid> {
        self.locked(|log| {
            let pid = spawn()?;
            let raw = pid.as_raw_pid().cast_unsigned();
            self.agent_pid.store(raw, Ordering::Relaxed);
            log.append(Line { at: now(), agent: Some(self.agent.clone()), pid: Some(raw), ..Line::new(Op::Start) });
            Ok(pid)
        })
    }

    /// Of the thread `tid`, which is what the kernel tells us of, by its process
    pub fn by(&self, tid: u32) -> By {
        let status = std::fs::read_to_string(format!("/proc/{tid}/status")).unwrap_or_default();
        let group = status.lines().find_map(|line| line.strip_prefix("Tgid:")).and_then(|pid| pid.trim().parse().ok());
        let pid = group.unwrap_or(tid);
        let cmd = std::fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
        let agent = self.agent_pid.load(Ordering::Relaxed);
        let (mut child, mut commands) = (pid, vec![]);
        let commands = loop {
            if child == agent {
                break None;
            }
            let argv = std::fs::read(format!("/proc/{child}/cmdline")).unwrap_or_default();
            let argv = argv.split(|&b| b == 0).filter(|arg| !arg.is_empty());
            commands.push(argv.map(|arg| String::from_utf8_lossy(arg).into_owned()).collect());
            match parent(child) {
                Some(parent) if parent == agent => break Some(commands.into_iter().rev().collect()),
                Some(parent) if parent > 1 => child = parent,
                _ => break None,
            }
        };
        By { pid, cmd: cmd.trim_end().to_string(), commands }
    }

    /// Whether the process that made the change has `path` open, which it sees at the same path as we do
    pub fn has_open(&self, by: &By, path: &str) -> bool {
        let Ok(fds) = std::fs::read_dir(format!("/proc/{}/fd", by.pid)) else { return false };
        let path = self.root_path.join(path);
        fds.flatten().any(|fd| std::fs::read_link(fd.path()).is_ok_and(|link| link == path))
    }

    /// The path of what `fd` points to, relative to the workspace, if its changes are recorded
    pub fn path(&self, fd: BorrowedFd) -> Option<String> {
        let link = std::fs::read_link(fd_path(fd)).ok()?;
        let st = rustix::fs::fstat(fd).ok()?;
        if st.st_nlink == 0 || rustix::fs::FileType::from_raw_mode(st.st_mode) != rustix::fs::FileType::RegularFile {
            return None;
        }
        // which, of a file with several names, is the one it was last looked up by, which may be gone
        let path = self.recorded_path(&link, false)?;
        let at = rustix::fs::statat(&self.root, path.as_str(), AtFlags::SYMLINK_NOFOLLOW).ok()?;
        ((at.st_dev, at.st_ino) == (st.st_dev, st.st_ino)).then_some(path)
    }

    /// The path of `name` in the directory `dir`, relative to the workspace, unless it's ignored, whatever is there, if
    /// anything. `is_dir` says which of the ignores' rules match it
    pub fn child_path(&self, dir: BorrowedFd, name: &OsStr, is_dir: bool) -> Option<String> {
        self.recorded_path(&std::fs::read_link(fd_path(dir)).ok()?.join(name), is_dir)
    }

    /// `path` relative to the workspace, unless it's outside it, or ignored
    fn recorded_path(&self, path: &Path, is_dir: bool) -> Option<String> {
        let path = path.strip_prefix(&self.root_path).ok()?.to_str()?;
        (!path.is_empty() && !self.ignores.ignored(path, is_dir)).then(|| path.to_string())
    }
}

/// The log, held across processes, until this drops, even when what's recorded panics, which would hold up the
/// other wrappers
struct Held<'a> {
    recorder: &'a Recorder,
    log: MutexGuard<'a, Log>,
}

impl Drop for Held<'_> {
    fn drop(&mut self) {
        self.recorder.read.store(self.log.read, Ordering::Relaxed);
        self.log.release();
    }
}

/// Of a change to `path` that couldn't be recorded, which the agent's change mustn't fail with
fn report(path: &str, err: &io::Error) {
    eprintln!("otto-track: recording {path}: {err}");
}

#[cfg(test)]
mod tests {
    use std::os::fd::AsFd;

    use rustix::fs::{Mode, OFlags};

    use super::*;
    use crate::test_util::Temp;

    #[test]
    fn parent_of_this_process() {
        let ppid = rustix::process::Pid::as_raw(rustix::process::getppid()).cast_unsigned();
        assert_eq!(parent(std::process::id()), Some(ppid));
        assert_eq!(parent(u32::MAX), None);
    }

    #[test]
    fn parent_past_a_command_with_parentheses() {
        // of a thread, which shares its process's parent
        let ppid = rustix::process::Pid::as_raw(rustix::process::getppid()).cast_unsigned();
        let found = std::thread::spawn(|| {
            rustix::thread::set_name(c"a) b (c").unwrap();
            parent(rustix::thread::gettid().as_raw_nonzero().get().cast_unsigned())
        });
        assert_eq!(found.join().unwrap(), Some(ppid));
    }

    /// A workspace, the top of its repo, and a store beside it
    pub(super) fn recorder(temp: &Temp) -> (PathBuf, OwnedFd, Recorder) {
        let ws = temp.0.join("ws");
        std::fs::create_dir_all(ws.join(".git")).unwrap();
        std::fs::create_dir_all(ws.join("sub")).unwrap();
        temp.write("ws/.gitignore", "*.gen\n/out/\n");
        let root = rustix::fs::open(&ws, OFlags::PATH | OFlags::DIRECTORY | OFlags::CLOEXEC, Mode::empty()).unwrap();
        let recorder = Recorder::new(&temp.0.join("store"), "x".into(), root.as_fd()).unwrap();
        (ws, root, recorder)
    }

    pub(super) fn open_path(path: &Path) -> OwnedFd {
        rustix::fs::open(path, OFlags::PATH | OFlags::CLOEXEC, Mode::empty()).unwrap()
    }

    #[test]
    fn path_of_recorded_files_only() {
        let temp = Temp::new("record-path");
        let (ws, root, recorder) = recorder(&temp);
        temp.write("ws/sub/a.txt", "a");
        temp.write("ws/a.gen", "a");
        temp.write("store/elsewhere", "a");
        assert_eq!(recorder.path(open_path(&ws.join("sub/a.txt")).as_fd()).as_deref(), Some("sub/a.txt"));
        assert_eq!(recorder.path(open_path(&ws.join("a.gen")).as_fd()), None);
        assert_eq!(recorder.path(open_path(&ws.join("sub")).as_fd()), None);
        assert_eq!(recorder.path(root.as_fd()), None);
        assert_eq!(recorder.path(open_path(&temp.0.join("store/elsewhere")).as_fd()), None);
        assert!(temp.0.join("store/log.jsonl").exists());
        assert!(temp.0.join("store/blobs").is_dir());
    }

    #[test]
    fn path_follows_renames_but_not_removals() {
        let temp = Temp::new("record-path-moved");
        let (ws, _root, recorder) = recorder(&temp);
        temp.write("ws/a.txt", "a");
        let fd = open_path(&ws.join("a.txt"));
        std::fs::rename(ws.join("a.txt"), ws.join("sub/b.txt")).unwrap();
        assert_eq!(recorder.path(fd.as_fd()).as_deref(), Some("sub/b.txt"));
        std::fs::remove_file(ws.join("sub/b.txt")).unwrap();
        assert_eq!(recorder.path(fd.as_fd()), None);
    }

    #[test]
    fn child_path_unless_ignored() {
        let temp = Temp::new("record-child-path");
        let (ws, root, recorder) = recorder(&temp);
        let sub = open_path(&ws.join("sub"));
        assert_eq!(recorder.child_path(sub.as_fd(), "new.txt".as_ref(), false).as_deref(), Some("sub/new.txt"));
        assert_eq!(recorder.child_path(sub.as_fd(), "new.gen".as_ref(), false), None);
        assert_eq!(recorder.child_path(root.as_fd(), "out".as_ref(), true), None);
        assert_eq!(recorder.child_path(root.as_fd(), "out".as_ref(), false).as_deref(), Some("out"));
        assert_eq!(recorder.child_path(root.as_fd(), ".git".as_ref(), true), None);
    }
}
