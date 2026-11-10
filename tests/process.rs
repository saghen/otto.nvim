//! The wrapper as a process: its exit, stdio, mount, signals and limits

mod common;

use std::io::Write;
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

use rustix::process::{Pid, Signal};

use common::*;

#[test]
fn exits_like_the_agent_with_its_stdio() {
    let ws = Workspace::new("exit");
    let mut child = ws.track("a", &["sh", "-c", "read x; echo \"got $x\"; exit 3"]);
    let mut child = child.stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    child.stdin.take().unwrap().write_all(b"hi\n").unwrap();
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(3));
    assert_eq!(String::from_utf8_lossy(&output.stdout), "got hi\n");
}

#[test]
fn runs_in_its_own_mount() {
    let ws = Workspace::new("mount");
    let output = ws.sh("a", "grep ' fuse.otto-track ' /proc/self/mountinfo");
    assert!(String::from_utf8_lossy(&output.stdout).contains(ws.path().to_str().unwrap()));
    let outside = std::fs::read_to_string("/proc/self/mountinfo").unwrap();
    assert!(!outside.contains(ws.path().to_str().unwrap()));
}

#[test]
fn forwards_signals_and_dies_of_them() {
    let ws = Workspace::new("signals");
    let mut agent = Paused::spawn(&mut ws.track("a", &["sh", "-c", "echo ready; exec sleep 30"]));
    agent.wait_until("ready");
    rustix::process::kill_process(Pid::from_child(&agent.child), Signal::TERM).unwrap();
    assert_eq!(agent.wait().signal(), Some(Signal::TERM.as_raw()));
}

#[test]
fn the_agent_dies_with_the_wrapper() {
    let ws = Workspace::new("orphan");
    let mut wrapper = Paused::spawn(&mut ws.track("a", &["sh", "-c", "echo $$; exec sleep 30"]));
    let agent = wrapper.line();
    wrapper.child.kill().unwrap();
    wrapper.child.wait().unwrap();
    let gone = || !Path::new("/proc").join(&agent).exists();
    until(Duration::from_secs(5), "the agent outlived its wrapper", gone);
}

#[test]
fn the_agent_keeps_its_fd_limit() {
    let ws = Workspace::new("limit");
    let outside = Command::new("sh").args(["-c", "ulimit -n"]).output().unwrap().stdout;
    assert_eq!(ws.sh("a", "ulimit -n").stdout, outside);
}

#[test]
fn refuses_a_store_in_the_workspace() {
    let ws = Workspace::new("inside");
    let mut command = Command::new(BIN);
    command.current_dir(ws.path()).args(["run", "--store", "store", "--agent", "a", "--", "true"]);
    assert!(!command.output().unwrap().status.success());
}
