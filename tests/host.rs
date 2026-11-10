//! Commands that run on the host rather than in the agent's namespace

mod common;

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output};
use std::time::Duration;

use common::*;

/// Runs `agent` with `script` on the `PATH` as `name`, which runs on the host
fn on_host(ws: &Workspace, name: &str, script: &str, agent: &str) -> Output {
    let bin = ws.0.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(bin.join(name), format!("#!/bin/sh\n{script}\n")).unwrap();
    std::fs::set_permissions(bin.join(name), std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap());
    let mut command = Command::new(BIN);
    command.current_dir(ws.path()).env("PATH", path).arg("run").arg("--store").arg(ws.0.join("store"));
    command.args(["--agent", "a", "--host", name, "--", "sh", "-c", agent]).output().unwrap()
}

#[test]
fn runs_chosen_commands_on_the_host() {
    let ws = Workspace::new("host");
    let script = "read x; echo \"$x $# [$1] $FOO $(pwd)\"; cat /proc/self/uid_map; exit 4";
    let output = on_host(&ws, "probe", script, "echo hi | FOO=bar probe '' b; echo $?; cat /proc/self/uid_map");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let lines: Vec<_> = stdout.lines().map(str::trim).collect();
    let host = std::fs::read_to_string("/proc/self/uid_map").unwrap();
    assert_eq!(lines[..3], [&format!("hi 2 [] bar {}", ws.path().display()), host.trim(), "4"]);
    assert_ne!(lines[3], host.trim());
}

#[test]
fn commands_on_the_host_get_the_signals() {
    let ws = Workspace::new("host-signals");
    let pids = ws.0.join("pids");
    let script = format!("echo $$ >> {}; exec sleep 30", pids.display());
    // Once each is running on the host, as its line in `pids` says
    let started =
        |n| format!("until [ \"$(cat {} 2>/dev/null | wc -l)\" -ge {n} ]; do sleep 0.01; done", pids.display());
    let agent = format!(
        "sleeper & {}; kill $!; wait $! || echo $?; sleeper & {}; kill -9 $!; wait $! || echo $?",
        started(1),
        started(2)
    );
    let output = on_host(&ws, "sleeper", &script, &agent);
    assert_eq!(String::from_utf8_lossy(&output.stdout), "143\n137\n");
    // the second by hangup, once its shim is gone
    for pid in std::fs::read_to_string(pids).unwrap().lines() {
        until(Duration::from_secs(5), &format!("{pid} still running"), || !Path::new("/proc").join(pid).exists());
    }
}
