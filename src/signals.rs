//! The signals that the wrapper and the shims wait for and forward, rather than die of

use std::io;
use std::mem::MaybeUninit;
use std::os::unix::process::ExitStatusExt;
use std::process::{ExitCode, ExitStatus};

use rustix::process::{DumpableBehavior, Pid, Signal, WaitOptions};

/// The agent's exit, and what's forwarded to it
const SIGNALS: [Signal; 5] = [Signal::CHILD, Signal::INT, Signal::TERM, Signal::HUP, Signal::QUIT];

pub type Set = libc::sigset_t;

/// A set of `signals`, through `sigemptyset`, since all zeroes needn't be an empty set. Async-signal-safe
fn set_of(signals: &[Signal]) -> Set {
    let mut set = MaybeUninit::<Set>::uninit();
    // SAFETY: `sigemptyset` initializes the whole set, which `sigaddset` then only changes
    unsafe {
        libc::sigemptyset(set.as_mut_ptr());
        for sig in signals {
            libc::sigaddset(set.as_mut_ptr(), sig.as_raw());
        }
        set.assume_init()
    }
}

/// Blocks them in this thread, and the threads it starts after, so only `wait` gets them. Before any thread starts
pub fn block() -> Set {
    let set = set_of(&SIGNALS);
    // SAFETY: a set we own. It fails only for a bad `how`
    unsafe { libc::pthread_sigmask(libc::SIG_BLOCK, &raw const set, std::ptr::null_mut()) };
    set
}

/// Unblocks them again, like in a child before it runs its command. Async-signal-safe
pub fn unblock(set: &Set) -> io::Result<()> {
    // SAFETY: a set we own
    match unsafe { libc::pthread_sigmask(libc::SIG_UNBLOCK, set, std::ptr::null_mut()) } {
        0 => Ok(()),
        err => Err(io::Error::from_raw_os_error(err)),
    }
}

/// Waits for the next of `set`, which must be blocked. None when the wait failed, like when interrupted
pub fn wait(set: &Set) -> Option<Signal> {
    // SAFETY: a set we own, and no info asked for
    let sig = unsafe { libc::sigwaitinfo(set, std::ptr::null_mut()) };
    Signal::from_named_raw(sig)
}

/// Forwards signals to the agent until it exits, and returns its status
pub fn wait_forwarding(pid: Pid, set: &Set) -> io::Result<ExitStatus> {
    loop {
        let mut info = MaybeUninit::<libc::siginfo_t>::uninit();
        // SAFETY: a set we own, and room for the info, which it fills when it returns a signal
        let sig = Signal::from_named_raw(unsafe { libc::sigwaitinfo(set, info.as_mut_ptr()) });
        match sig {
            Some(Signal::CHILD) => {
                if let Some((_, status)) = rustix::process::waitpid(Some(pid), WaitOptions::NOHANG)? {
                    return Ok(ExitStatus::from_raw(status.as_raw()));
                }
            }
            // Sent with `kill`, since ones from the terminal reach the agent's process group already
            // SAFETY: filled, since it returned a signal
            Some(sig) if unsafe { info.assume_init_ref() }.si_code <= 0 => {
                // which fails only once it's exited, which the next SIGCHLD tells us of
                let _ = rustix::process::kill_process(pid, sig);
            }
            // from the terminal, or interrupted
            _ => {}
        }
    }
}

/// Dies of `status`'s signal, if it has one, or else returns its code for main to exit with
pub fn exit_like(status: ExitStatus) -> ExitCode {
    let Some(raw) = status.signal() else {
        // with a code, since a wait for its exit returns no stops
        return ExitCode::from(status.code().and_then(|code| u8::try_from(code).ok()).unwrap_or(1));
    };
    // SAFETY: one the kernel killed a process with, so a real one, which may be a realtime one, unlike a named one
    let sig = unsafe { Signal::from_raw_unchecked(raw) };
    // Dying of the same signal tells our parent what happened
    // with the agent's core dump, if any, not ours, which only costs that if it fails
    let _ = rustix::process::set_dumpable_behavior(DumpableBehavior::NotDumpable);
    let set = set_of(&[sig]);
    // SAFETY: plain libc calls on values we own. No handler is ever set, so resetting one races nothing
    unsafe {
        libc::signal(raw, libc::SIG_DFL);
        libc::pthread_sigmask(libc::SIG_UNBLOCK, &raw const set, std::ptr::null_mut());
        libc::raise(raw);
    }
    // if it didn't
    ExitCode::from(u8::try_from(128 + raw).unwrap_or(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Whether `set` has `sig`
    fn has(set: &Set, sig: i32) -> bool {
        // SAFETY: an initialized set
        unsafe { libc::sigismember(set, sig) == 1 }
    }

    #[test]
    fn set_of_has_just_those() {
        let set = set_of(&[Signal::HUP, Signal::INT]);
        assert!(has(&set, libc::SIGHUP) && has(&set, libc::SIGINT));
        assert!(!has(&set, libc::SIGTERM) && !has(&set, libc::SIGKILL));
        assert!(!has(&set_of(&[]), libc::SIGHUP));
    }

    #[test]
    fn exit_like_an_exit_has_its_code() {
        // as `waitpid` puts them
        assert_eq!(exit_like(ExitStatus::from_raw(0)), ExitCode::SUCCESS);
        assert_eq!(exit_like(ExitStatus::from_raw(3 << 8)), ExitCode::from(3));
        assert_eq!(exit_like(ExitStatus::from_raw(255 << 8)), ExitCode::from(255));
    }

    #[test]
    fn exit_like_a_signal_dies_of_it() {
        // In a child, which only makes async-signal-safe calls before it dies, since this process has threads
        // SAFETY: as above
        let pid = unsafe { libc::fork() };
        if pid == 0 {
            let _ = exit_like(ExitStatus::from_raw(libc::SIGTERM));
            // SAFETY: still the child, which shouldn't get here
            unsafe { libc::_exit(1) }
        }
        let (_, status) = rustix::process::waitpid(Pid::from_raw(pid), WaitOptions::empty()).unwrap().unwrap();
        assert_eq!(status.terminating_signal(), Some(libc::SIGTERM));
    }

    #[test]
    fn block_then_wait_for_one() {
        // On a thread of its own, since the mask is per thread, and sent to that thread only
        let got = std::thread::spawn(|| {
            let set = block();
            // SAFETY: to this thread, which blocks it
            unsafe { libc::raise(libc::SIGHUP) };
            let got = wait(&set);
            unblock(&set).unwrap();
            got
        });
        assert_eq!(got.join().unwrap(), Some(Signal::HUP));
    }
}
