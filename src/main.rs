//! Runs an agent with a FUSE passthrough over its workspace, in a mount namespace of its own,
//! so every change the agent makes there passes through us
//!
//!   otto-track run --store <dir> --agent <name> [--host <cmd>]... -- <cmd>...
//!   otto-track --protocol

mod fs;
mod host;
mod record;
mod signals;
#[cfg(test)]
mod test_util;

use std::ffi::OsString;
use std::fmt::Display;
use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use rustix::fs::{Mode, OFlags};
use rustix::mount::{MountFlags, MountPropagationFlags};
use rustix::process::{Pid, Signal};
use rustix::thread::{CapabilitySet, CapabilitySets, UnshareFlags};

/// Of the CLI and the log's format, which otto checks before it runs us, so an old build says to rebuild rather than
/// failing on new flags or dropping lines it can't read. Bump it with either
const PROTOCOL: u32 = 1;

enum Cli {
    Run(Args),
    Protocol,
}

struct Args {
    store: PathBuf,
    agent: String,
    host: Vec<OsString>,
    cmd: Vec<OsString>,
}

fn parse_args(mut parser: lexopt::Parser) -> Result<Cli, lexopt::Error> {
    use lexopt::prelude::*;
    match parser.next()? {
        Some(Value(cmd)) if cmd == "run" => {}
        Some(Long("protocol")) => return Ok(Cli::Protocol),
        Some(arg) => return Err(arg.unexpected()),
        None => return Err("expected a subcommand: run".into()),
    }
    let (mut store, mut agent, mut host, mut cmd) = (None, None, Vec::new(), Vec::new());
    while let Some(arg) = parser.next()? {
        match arg {
            Long("store") => store = Some(PathBuf::from(parser.value()?)),
            Long("agent") => agent = Some(parser.value()?.string()?),
            Long("host") => host.push(parser.value()?),
            Value(value) => {
                cmd.push(value);
                cmd.extend(parser.raw_args()?);
            }
            _ => return Err(arg.unexpected()),
        }
    }
    if cmd.is_empty() {
        return Err("expected a command after --".into());
    }
    Ok(Cli::Run(Args { store: store.ok_or("missing --store")?, agent: agent.ok_or("missing --agent")?, host, cmd }))
}

fn main() -> ExitCode {
    let result = match std::env::current_exe() {
        Ok(exe) if exe.file_name() != Some("otto-track".as_ref()) => host::shim(&exe),
        _ => match parse_args(lexopt::Parser::from_env()) {
            Ok(Cli::Run(args)) => run(args),
            Ok(Cli::Protocol) => {
                println!("{PROTOCOL}");
                return ExitCode::SUCCESS;
            }
            Err(err) => {
                eprintln!("otto-track: {err}");
                return ExitCode::from(2);
            }
        },
    };
    result.unwrap_or_else(|err| {
        eprintln!("otto-track: {err}");
        ExitCode::from(1)
    })
}

fn run(args: Args) -> io::Result<ExitCode> {
    let host = host::start(&args.host).map_err(context("starting the host helper"))?;
    let workspace = std::env::current_dir().map_err(context("finding the workspace"))?;
    // While it's still the real directory, since the mount hides it
    let root = rustix::fs::open(&workspace, OFlags::PATH | OFlags::DIRECTORY | OFlags::CLOEXEC, Mode::empty())
        .map_err(context(format_args!("opening {}", workspace.display())))?;
    let store = std::fs::create_dir_all(&args.store)
        .and_then(|()| args.store.canonicalize())
        .map_err(context(format_args!("creating the store {}", args.store.display())))?;
    // Or recording a change would make another
    if store.starts_with(workspace.canonicalize().map_err(context("finding the workspace"))?) {
        return Err(io::Error::other("the store can't be in the workspace"));
    }
    // Before the mount hides the workspace, where `Ignores` looks for the repo by path
    let recorder = record::Recorder::new(&args.store, args.agent, root.as_fd())
        .map_err(context(format_args!("opening the store {}", args.store.display())))?;
    let recorder = Arc::new(recorder);
    let fuse = enter_namespace(&workspace, host.as_ref().map_or(&[], |host| &host.targets))?;
    drop_capabilities().map_err(context("dropping the namespace's capabilities"))?;
    let fd_limit = raise_fd_limit();

    // Before any thread starts, so only `wait_forwarding` gets them
    debug_assert!(single_threaded(), "blocking signals after a thread started");
    let signals = signals::block();
    // The kernel already applies the agent's umask
    let umask = rustix::process::umask(Mode::empty());
    let session = fs::serve(fuse, root, recorder.clone()).map_err(context("serving the mount"))?;

    // Into the mount, from the directory under it, and with its root's attributes, which are root's until the kernel
    // first asks for them, so that creating in it would be refused
    std::env::set_current_dir(&workspace)
        .and_then(|()| std::fs::metadata(&workspace))
        .map_err(context("entering the mount"))?;
    let mut cmd = agent_command(&args.cmd, host.as_ref(), umask, fd_limit, signals);
    let running = format!("running {}", args.cmd[0].display());
    let pid = recorder.start(|| Ok(Pid::from_child(&cmd.spawn().map_err(context(running))?)))?;
    let status = signals::wait_forwarding(pid, &signals);
    // Before dying of the agent's signal, which would lose them
    session.settle();
    Ok(signals::exit_like(status.map_err(context("waiting for the agent"))?))
}

/// The agent's `cmd`, which runs with the umask, fd limit and signals as they were before we changed them for us
fn agent_command(
    cmd: &[OsString],
    host: Option<&host::Host>,
    umask: Mode,
    fd_limit: rustix::process::Rlimit,
    signals: signals::Set,
) -> Command {
    let mut command = Command::new(&cmd[0]);
    command.args(&cmd[1..]);
    // Since git stops at the mount, when the workspace is in a repo rather than its top
    command.env("GIT_DISCOVERY_ACROSS_FILESYSTEM", "1");
    if let Some(host) = host {
        command.env(host::SOCKET_ENV, &host.socket_name);
    }
    // SAFETY: all are async-signal-safe: rustix's are bare syscalls, whose errors convert without allocating
    unsafe {
        command.pre_exec(move || {
            rustix::process::umask(umask);
            rustix::process::setrlimit(rustix::process::Resource::Nofile, fd_limit)?;
            signals::unblock(&signals)?;
            // Since the mount dies with us
            rustix::process::set_parent_process_death_signal(Some(Signal::TERM))?;
            Ok(())
        })
    };
    command
}

/// Says what failed, keeping the error's kind
fn context<E: Into<io::Error>>(what: impl Display) -> impl FnOnce(E) -> io::Error {
    move |err| {
        let err = err.into();
        io::Error::new(err.kind(), format!("{what}: {err}"))
    }
}

/// Whether this process has no thread but this one, which forking, unsharing, and setting what's per thread need
fn single_threaded() -> bool {
    std::fs::read_to_string("/proc/self/status").is_ok_and(|status| status.contains("\nThreads:\t1\n"))
}

/// Mounts FUSE over the workspace in new user and mount namespaces, before any thread starts
fn enter_namespace(workspace: &Path, on_host: &[PathBuf]) -> io::Result<OwnedFd> {
    debug_assert!(single_threaded(), "entering a namespace after a thread started");
    let (uid, gid) = (rustix::process::getuid().as_raw(), rustix::process::getgid().as_raw());
    // SAFETY: still single threaded, and not unsharing the fd table
    unsafe { rustix::thread::unshare_unsafe(UnshareFlags::NEWUSER | UnshareFlags::NEWNS) }
        .map_err(context("entering a user namespace (are unprivileged user namespaces enabled?)"))?;
    let write_map = |file: &str, map: String| {
        std::fs::write(format!("/proc/self/{file}"), map).map_err(context(format_args!("writing {file}")))
    };
    write_map("setgroups", "deny".into())?;
    write_map("uid_map", format!("{uid} {uid} 1"))?;
    write_map("gid_map", format!("{gid} {gid} 1"))?;
    // So the mount stays in the namespace
    rustix::mount::mount_change("/", MountPropagationFlags::PRIVATE | MountPropagationFlags::REC)
        .map_err(context("making the namespace's mounts private"))?;
    // Before the mount, which hides us if we're in the workspace
    let exe = std::env::current_exe().map_err(context("finding otto-track's executable"))?;
    for target in on_host {
        rustix::mount::mount_bind(&exe, target).map_err(context(format_args!("binding over {}", target.display())))?;
    }

    let fuse = rustix::fs::open("/dev/fuse", OFlags::RDWR | OFlags::CLOEXEC, Mode::empty())
        .map_err(context("opening /dev/fuse"))?;
    // The kernel checks the agent's permissions against the attributes we give it, including to search directories
    // it looked up before, since they're the real ones
    let options = format!("fd={},rootmode=40000,user_id={uid},group_id={gid},default_permissions", fuse.as_raw_fd());
    rustix::mount::mount(
        "otto-track",
        workspace,
        "fuse.otto-track",
        MountFlags::NOSUID | MountFlags::NODEV,
        Some(std::ffi::CString::new(options)?.as_c_str()),
    )
    .map_err(context(format_args!("mounting over {}", workspace.display())))?;
    Ok(fuse)
}

/// Leaves us the agent's permissions in the workspace, so what we do for it is what it could do itself. Before any
/// thread starts, since each has its own
fn drop_capabilities() -> io::Result<()> {
    debug_assert!(single_threaded(), "dropping capabilities after a thread started");
    let none = CapabilitySet::empty();
    Ok(rustix::thread::set_capabilities(None, CapabilitySets { effective: none, permitted: none, inheritable: none })?)
}

/// Locks `mutex` even after a thread panicked holding it, so one failed request doesn't fail every one after
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Where the kernel says `fd` points, which is current across renames, and through which it opens for real
fn fd_path(fd: BorrowedFd) -> PathBuf {
    PathBuf::from(format!("/proc/self/fd/{}", fd.as_raw_fd()))
}

/// Each node holds an fd, and builds open many. Returns the limit as it was, for the agent, since some tools close
/// every fd up to it
fn raise_fd_limit() -> rustix::process::Rlimit {
    use rustix::process::{Resource, getrlimit, setrlimit};
    let limit = getrlimit(Resource::Nofile);
    // Or the agent may run out of fds sooner, which is no reason not to run it
    let _ = setrlimit(Resource::Nofile, rustix::process::Rlimit { current: limit.maximum, ..limit });
    limit
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<Args, lexopt::Error> {
        match parse_args(lexopt::Parser::from_args(args))? {
            Cli::Run(args) => Ok(args),
            Cli::Protocol => Err("not a run".into()),
        }
    }

    fn error(args: &[&str]) -> String {
        parse(args).err().unwrap().to_string()
    }

    #[test]
    fn parses_a_run() {
        let args =
            parse(&["run", "--store", "/s", "--agent", "a", "--host", "sudo", "--host=ssh", "--", "sh", "-c", "x"])
                .unwrap();
        assert_eq!(args.store, PathBuf::from("/s"));
        assert_eq!(args.agent, "a");
        assert_eq!(args.host, ["sudo", "ssh"]);
        assert_eq!(args.cmd, ["sh", "-c", "x"]);
    }

    #[test]
    fn leaves_the_commands_options_to_it() {
        let args = parse(&["run", "--agent", "a", "--store", "/s", "--", "cmd", "--store", "x", "--"]).unwrap();
        assert_eq!(args.store, PathBuf::from("/s"));
        assert_eq!(args.cmd, ["cmd", "--store", "x", "--"]);
        // and without `--`, from the first value
        let args = parse(&["run", "--agent", "a", "--store", "/s", "cmd", "--agent", "b"]).unwrap();
        assert_eq!(args.agent, "a");
        assert_eq!(args.cmd, ["cmd", "--agent", "b"]);
        assert_eq!(args.host, Vec::<OsString>::new());
    }

    #[test]
    fn parses_a_protocol_query() {
        assert!(matches!(parse_args(lexopt::Parser::from_args(["--protocol"])), Ok(Cli::Protocol)));
    }

    #[test]
    fn refuses_what_isnt_a_run() {
        assert_eq!(error(&[]), "expected a subcommand: run");
        assert!(matches!(parse(&["walk", "--", "sh"]), Err(lexopt::Error::UnexpectedArgument(arg)) if arg == "walk"));
        assert!(matches!(parse(&["--store", "/s"]), Err(lexopt::Error::UnexpectedOption(_))));
    }

    #[test]
    fn refuses_a_run_missing_something() {
        assert_eq!(error(&["run", "--agent", "a", "--", "sh"]), "missing --store");
        assert_eq!(error(&["run", "--store", "/s", "--", "sh"]), "missing --agent");
        assert_eq!(error(&["run", "--store", "/s", "--agent", "a"]), "expected a command after --");
        assert_eq!(error(&["run", "--store", "/s", "--agent", "a", "--"]), "expected a command after --");
        assert!(matches!(parse(&["run", "--store"]), Err(lexopt::Error::MissingValue { .. })));
        assert!(matches!(parse(&["run", "--other", "--", "sh"]), Err(lexopt::Error::UnexpectedOption(_))));
    }
}
