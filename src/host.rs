//! Runs chosen commands, like `sudo` and `ssh`, on the host rather than in the agent's user namespace, where others'
//! files look owned by nobody and setuid does nothing. The wrapper binds itself over each, and run as one it asks a
//! helper, forked before the namespace, to run the real one with its arguments, environment, directory and stdio.
//! What they change isn't the agent's

use std::ffi::{OsStr, OsString};
use std::io::{self, IoSlice, IoSliceMut, Read, Write};
use std::mem::MaybeUninit;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, IntoRawFd, OwnedFd};
use std::os::linux::net::SocketAddrExt;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::{SocketAddr, UnixListener, UnixStream};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, ExitStatus};

use rustix::event::{PollFd, PollFlags};
use rustix::fs::{Mode, OFlags};
use rustix::net::{RecvAncillaryBuffer, RecvAncillaryMessage, RecvFlags, SendAncillaryBuffer, SendAncillaryMessage};
use rustix::process::{Pid, PidfdFlags, Signal};
use serde::{Deserialize, Serialize};

use crate::signals;

/// The helper's socket, for the shims
pub const SOCKET_ENV: &str = "OTTO_TRACK_HOST";

pub struct Host {
    /// The abstract name of the helper's socket
    pub socket_name: String,
    /// What to bind over
    pub targets: Vec<PathBuf>,
    /// Closed when the wrapper exits, after which the helper takes no more
    _alive: io::PipeWriter,
}

#[derive(Serialize, Deserialize)]
struct Request {
    exe: OsString,
    argv: Vec<OsString>,
    env: Vec<(OsString, OsString)>,
    cwd: OsString,
}

/// Forks the helper, before the namespace and any thread, and before anything else is open, so it holds none of it
pub fn start(names: &[OsString]) -> io::Result<Option<Host>> {
    debug_assert!(crate::single_threaded(), "forking the host helper after a thread started");
    let targets = find_targets(names, &std::env::var_os("PATH").unwrap_or_default());
    if targets.is_empty() {
        return Ok(None);
    }
    let socket_name = format!("otto-track.{}", std::process::id());
    let listener = UnixListener::bind_addr(&SocketAddr::from_abstract_name(&socket_name)?)?;
    let (alive_read, alive) = io::pipe()?;
    // SAFETY: still single threaded
    match unsafe { libc::fork() } {
        -1 => Err(io::Error::last_os_error()),
        0 => {
            drop(alive);
            let code = match detach() {
                Ok(()) => {
                    serve(&listener, &alive_read, &targets);
                    0
                }
                // after which shims can't connect, and say so
                Err(err) => {
                    eprintln!("otto-track: starting the host helper: {err}");
                    1
                }
            };
            // SAFETY: the threads are done
            unsafe { libc::_exit(code) }
        }
        _ => Ok(Some(Host { socket_name, targets, _alive: alive })),
    }
}

/// Puts the helper in a session of its own, away from the terminal's signals, and without the agent's stdio, which
/// otto waits on
fn detach() -> io::Result<()> {
    rustix::process::setsid()?;
    let null = rustix::fs::open(c"/dev/null", OFlags::RDWR | OFlags::CLOEXEC, Mode::empty())?;
    rustix::stdio::dup2_stdin(&null)?;
    rustix::stdio::dup2_stdout(&null)?;
    rustix::stdio::dup2_stderr(&null)?;
    // unless it's one of them, when they were closed
    if null.as_raw_fd() < 3 {
        let _ = null.into_raw_fd();
    }
    Ok(())
}

/// Each on `path`, a `PATH`, that isn't another name of a multicall binary, like `su` of busybox, which would run
/// all of it on the host
fn find_targets(names: &[OsString], path: &OsStr) -> Vec<PathBuf> {
    let mut found = Vec::new();
    for dir in std::env::split_paths(path) {
        for name in names {
            let Ok(target) = dir.join(name).canonicalize() else { continue };
            if target.file_name() == Some(name.as_os_str()) && target.is_file() && !found.contains(&target) {
                found.push(target);
            }
        }
    }
    found
}

fn serve(listener: &UnixListener, alive: &io::PipeReader, targets: &[PathBuf]) {
    let uid = rustix::process::getuid();
    std::thread::scope(|scope| {
        loop {
            let mut fds = [PollFd::new(listener, PollFlags::IN), PollFd::new(alive, PollFlags::IN)];
            // Any other error would repeat, so the helper stops, and shims say they can't reach it
            match rustix::event::poll(&mut fds, None) {
                Err(rustix::io::Errno::INTR) => continue,
                Err(_) => return,
                Ok(_) => {}
            }
            if !fds[1].revents().is_empty() {
                return;
            }
            let conn = match listener.accept() {
                Ok((conn, _)) => conn,
                // a shim gone before it was accepted
                Err(err) if matches!(err.kind(), io::ErrorKind::Interrupted | io::ErrorKind::ConnectionAborted) => {
                    continue;
                }
                Err(_) => return,
            };
            if rustix::net::sockopt::socket_peercred(&conn).is_ok_and(|cred| cred.uid == uid) {
                scope.spawn(move || run_request(conn, targets));
            }
        }
    });
}

fn run_request(mut conn: UnixStream, targets: &[PathBuf]) {
    // Without its stdio there's nowhere to say why, so the shim says it got no status
    let Ok((request, fds)) = receive(&mut conn) else { return };
    let Ok(stdio) = <[OwnedFd; 3]>::try_from(fds) else { return };
    let status = run_to_exit(&conn, request, &stdio, targets).unwrap_or_else(|err| {
        // which fails only when the shim's stderr is closed, leaving nowhere else to say it
        let _ = rustix::io::write(&stdio[2], format!("otto-track: {err}\n").as_bytes());
        // like a command that exited with 1
        ExitStatus::from_raw(1 << 8)
    });
    // which fails only once the shim is gone, like when it was killed
    let _ = conn.write_all(&status.into_raw().to_le_bytes());
}

/// Sends `request`, with the shim's `stdio`, as `receive` reads it: the body's length, with the fds, then the body
fn send(conn: &mut UnixStream, request: &Request, stdio: [BorrowedFd; 3]) -> io::Result<()> {
    let body = serde_json::to_vec(request)?;
    let mut space = [MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(3))];
    let mut ancillary = SendAncillaryBuffer::new(&mut space);
    ancillary.push(SendAncillaryMessage::ScmRights(&stdio));
    let len = u32::try_from(body.len()).map_err(io::Error::other)?.to_le_bytes();
    rustix::net::sendmsg(&*conn, &[IoSlice::new(&len)], &mut ancillary, rustix::net::SendFlags::empty())?;
    conn.write_all(&body)
}

/// Reads a request as `send` sends it
fn receive(conn: &mut UnixStream) -> io::Result<(Request, Vec<OwnedFd>)> {
    let mut len = [0; 4];
    let mut space = [MaybeUninit::uninit(); rustix::cmsg_space!(ScmRights(3))];
    let mut ancillary = RecvAncillaryBuffer::new(&mut space);
    let received =
        rustix::net::recvmsg(&*conn, &mut [IoSliceMut::new(&mut len)], &mut ancillary, RecvFlags::CMSG_CLOEXEC)?;
    let fds = ancillary
        .drain()
        .flat_map(|message| match message {
            RecvAncillaryMessage::ScmRights(fds) => fds.collect(),
            _ => Vec::new(),
        })
        .collect();
    conn.read_exact(&mut len[received.bytes..])?;
    let mut body = vec![0; u32::from_le_bytes(len) as usize];
    conn.read_exact(&mut body)?;
    Ok((serde_json::from_slice(&body)?, fds))
}

/// Runs it until it exits, with the signals the shim gets, and returns its status
fn run_to_exit(
    conn: &UnixStream,
    request: Request,
    stdio: &[OwnedFd; 3],
    targets: &[PathBuf],
) -> io::Result<ExitStatus> {
    let exe = Path::new(&request.exe);
    if !targets.iter().any(|target| target == exe) {
        return Err(io::Error::other(format!("{} doesn't run on the host", exe.display())));
    }
    let Some((arg0, rest)) = request.argv.split_first() else {
        return Err(io::Error::other(format!("{} was run without even its name as an argument", exe.display())));
    };
    let mut child = Command::new(exe)
        .arg0(arg0)
        .args(rest)
        .env_clear()
        .envs(request.env)
        .current_dir(&request.cwd)
        .stdin(stdio[0].try_clone()?)
        .stdout(stdio[1].try_clone()?)
        .stderr(stdio[2].try_clone()?)
        .spawn()
        .map_err(crate::context(format_args!("running {} on the host", exe.display())))?;
    // Rather than its pid, which another may have once it's waited on
    let pidfd = rustix::process::pidfd_open(Pid::from_child(&child), PidfdFlags::empty())?;
    let mut signals = conn.try_clone()?;
    std::thread::spawn(move || {
        let mut sig = [0];
        while signals.read(&mut sig).is_ok_and(|n| n == 1) {
            if let Some(sig) = Signal::from_named_raw(i32::from(sig[0])) {
                // which fails only once it's exited
                let _ = rustix::process::pidfd_send_signal(&pidfd, sig);
            }
        }
        // The shim is gone, or it has exited
        let _ = rustix::process::pidfd_send_signal(&pidfd, Signal::HUP);
    });
    child.wait()
}

/// What the wrapper runs as when bound over a command
pub fn shim(exe: &Path) -> io::Result<ExitCode> {
    let Some(socket_name) = std::env::var_os(SOCKET_ENV) else {
        return Err(io::Error::other(format!("{} runs on the host, but {SOCKET_ENV} isn't set", exe.display())));
    };
    let mut conn = UnixStream::connect_addr(&SocketAddr::from_abstract_name(socket_name.as_bytes())?)
        .map_err(crate::context("reaching the host helper"))?;
    let request = Request {
        exe: exe.into(),
        argv: std::env::args_os().collect(),
        env: std::env::vars_os().collect(),
        cwd: std::env::current_dir().map_err(crate::context("finding the directory it runs in"))?.into(),
    };
    let (stdin, stdout, stderr) = (io::stdin(), io::stdout(), io::stderr());
    send(&mut conn, &request, [stdin.as_fd(), stdout.as_fd(), stderr.as_fd()])?;

    let signals = signals::block();
    let mut forward = conn.try_clone()?;
    std::thread::spawn(move || {
        loop {
            let Some(sig) = signals::wait(&signals).filter(|&sig| sig != Signal::CHILD) else { continue };
            // which all fit
            let Ok(sig) = u8::try_from(sig.as_raw()) else { continue };
            if forward.write_all(&[sig]).is_err() {
                return;
            }
        }
    });
    let mut status = [0; 4];
    conn.read_exact(&mut status)
        .map_err(crate::context(format_args!("the host helper gave no status for {}", exe.display())))?;
    Ok(signals::exit_like(ExitStatus::from_raw(i32::from_le_bytes(status))))
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::test_util::Temp;

    /// With the dirs that the tests put commands in
    fn temp(name: &str) -> Temp {
        let temp = Temp::new(&format!("host-{name}"));
        for bin in ["a", "b", "c"] {
            std::fs::create_dir(temp.0.join(bin)).unwrap();
        }
        temp
    }

    /// The given dirs, as a `PATH`
    fn path(temp: &Temp, dirs: &[&str]) -> OsString {
        std::env::join_paths(dirs.iter().map(|dir| temp.0.join(dir))).unwrap()
    }

    fn exe(temp: &Temp, path: &str) -> PathBuf {
        temp.write(path, "#!/bin/sh\n");
        let path = temp.0.join(path);
        std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        path.canonicalize().unwrap()
    }

    fn names(names: &[&str]) -> Vec<OsString> {
        names.iter().map(OsString::from).collect()
    }

    #[test]
    fn finds_each_on_the_path() {
        let temp = temp("find");
        let sudo = exe(&temp, "b/sudo");
        let ssh = exe(&temp, "a/ssh");
        std::fs::create_dir(temp.0.join("a/sudo")).unwrap();
        let found = find_targets(&names(&["sudo", "ssh", "missing"]), &path(&temp, &["a", "b"]));
        // in the path's order, and not the directory
        assert_eq!(found, vec![ssh, sudo]);
        assert_eq!(find_targets(&names(&["sudo"]), &path(&temp, &["a", "c"])), Vec::<PathBuf>::new());
        assert_eq!(find_targets(&names(&["sudo"]), OsStr::new("")), Vec::<PathBuf>::new());
    }

    #[test]
    fn finds_each_once() {
        let temp = temp("dedup");
        let sudo = exe(&temp, "a/sudo");
        // another name for it that isn't another command
        std::os::unix::fs::symlink(temp.0.join("a/sudo"), temp.0.join("b/sudo")).unwrap();
        assert_eq!(find_targets(&names(&["sudo"]), &path(&temp, &["a", "b", "a"])), vec![sudo.clone()]);
        assert_eq!(find_targets(&names(&["sudo", "sudo"]), &path(&temp, &["a"])), vec![sudo]);
    }

    #[test]
    fn skips_names_of_a_multicall_binary() {
        let temp = temp("multicall");
        exe(&temp, "a/busybox");
        std::os::unix::fs::symlink("../a/busybox", temp.0.join("b/su")).unwrap();
        assert_eq!(find_targets(&names(&["su"]), &path(&temp, &["b"])), Vec::<PathBuf>::new());
        let su = exe(&temp, "c/su");
        assert_eq!(find_targets(&names(&["su"]), &path(&temp, &["b", "c"])), vec![su]);
    }
}
