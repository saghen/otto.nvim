//! The harness the integration tests share: throwaway workspaces, the wrapper over them, and its log
#![allow(dead_code, reason = "each test file uses some of it")]

use std::io::{BufRead, BufReader, Lines, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, ExitStatus, Output, Stdio};
use std::time::{Duration, Instant};

pub const BIN: &str = env!("CARGO_BIN_EXE_otto-track");

pub struct Workspace(pub PathBuf);

impl Workspace {
    pub fn new(name: &str) -> Self {
        warn_of_rttime();
        let dir = std::env::temp_dir().join(format!("otto-track-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("ws")).unwrap();
        Self(dir)
    }

    pub fn path(&self) -> PathBuf {
        self.0.join("ws")
    }

    pub fn track(&self, agent: &str, cmd: &[&str]) -> Command {
        let mut command = Command::new(BIN);
        command.current_dir(self.path()).arg("run").arg("--store").arg(self.0.join("store"));
        command.args(["--agent", agent, "--"]).args(cmd);
        command
    }

    pub fn sh(&self, agent: &str, script: &str) -> Output {
        let output = self.track(agent, &["sh", "-ec", script]).output().unwrap();
        assert!(output.status.success(), "{script}: {}: {}", output.status, String::from_utf8_lossy(&output.stderr));
        output
    }

    pub fn read(&self, path: &str) -> String {
        std::fs::read_to_string(self.path().join(path)).unwrap()
    }
}

impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Says, once, when the realtime CPU limit is finite, like 0 in some desktop sessions. The kernel boosts a task that
/// holds up RCU to realtime under load, and then kills it at that limit, so a test's processes die of SIGKILL at random
fn warn_of_rttime() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let limit = rustix::process::getrlimit(rustix::process::Resource::Rttime);
        if let Some(max) = limit.maximum {
            let _ = writeln!(
                std::io::stderr(),
                "warning: RLIMIT_RTTIME is {max}us, so the kernel may SIGKILL processes of these tests under load. \
                 Run them with it unlimited, like under `systemd-run --user --pipe --wait`"
            );
        }
    });
}

pub fn has(tool: &str) -> bool {
    Command::new("sh").args(["-c", &format!("command -v {tool}")]).stdout(Stdio::null()).status().unwrap().success()
}

/// Says the test is skipped, and why, on the real stderr, which the harness doesn't capture, unlike `eprintln!`
pub fn skip(why: &str) {
    let test = std::thread::current().name().unwrap_or("a test").to_string();
    let _ = writeln!(std::io::stderr(), "skipped {test}: {why}");
}

/// Whether to skip the test, which it says, since a tool it needs isn't on the `PATH`. Rather than fail, since not
/// everyone has every tool
pub fn skip_unless(tools: &[&str]) -> bool {
    let missing: Vec<_> = tools.iter().copied().filter(|tool| !has(tool)).collect();
    if !missing.is_empty() {
        skip(&format!("no {}", missing.join(", ")));
    }
    !missing.is_empty()
}

/// Polls `done` until it is, failing after `within`
pub fn until(within: Duration, what: &str, mut done: impl FnMut() -> bool) {
    let start = Instant::now();
    while !done() {
        assert!(start.elapsed() < within, "{what}, not after {within:?}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

pub fn wait_for(child: &mut Child, within: Duration) -> ExitStatus {
    let mut status = None;
    until(within, "still running", || {
        status = child.try_wait().unwrap();
        status.is_some()
    });
    status.unwrap()
}

/// A process that says on its stdout when it's ready, and then waits for a line on its stdin, so a test can do
/// something in between without guessing how long to wait
pub struct Paused {
    pub child: Child,
    pub stdin: Option<ChildStdin>,
    pub stdout: Lines<BufReader<ChildStdout>>,
}

impl Paused {
    pub fn spawn(command: &mut Command) -> Self {
        let mut child = command.stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
        let (stdin, stdout) = (child.stdin.take(), BufReader::new(child.stdout.take().unwrap()).lines());
        Self { child, stdin, stdout }
    }

    pub fn line(&mut self) -> String {
        let line = self.stdout.next();
        assert!(line.is_some(), "exited before saying anything");
        line.unwrap().unwrap()
    }

    /// Waits for it to say `line`
    pub fn wait_until(&mut self, line: &str) {
        assert_eq!(self.line(), line);
    }

    pub fn resume(&mut self) {
        writeln!(self.stdin.as_ref().unwrap()).unwrap();
    }

    pub fn wait(mut self) -> ExitStatus {
        drop(self.stdin.take());
        wait_for(&mut self.child, Duration::from_secs(10))
    }
}

impl Drop for Paused {
    /// Of a test that failed before it waited, so nothing's left running after it
    fn drop(&mut self) {
        if self.child.try_wait().is_ok_and(|status| status.is_none()) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

/// The store's log, one JSON object per line
pub fn log(ws: &Workspace) -> Vec<serde_json::Value> {
    let log = std::fs::read_to_string(ws.0.join("store/log.jsonl")).unwrap_or_default();
    log.lines().map(|line| serde_json::from_str(line).unwrap()).collect()
}

/// The ops of the log, with their agent or "-" for outside, and paths
pub fn ops(ws: &Workspace) -> Vec<String> {
    log(ws)
        .iter()
        .filter(|line| line["op"] != "start")
        .map(|line| {
            let agent = line["agent"].as_str().unwrap_or("-");
            let from = line["from"].as_str().map_or_else(String::new, |from| format!("{from} -> "));
            format!("{agent} {} {from}{}", line["op"].as_str().unwrap(), line["path"].as_str().unwrap())
        })
        .collect()
}

/// What each path holds after replaying the log, by hash
pub fn replay(ws: &Workspace) -> std::collections::BTreeMap<String, String> {
    let mut files = std::collections::BTreeMap::new();
    for line in log(ws) {
        let (path, hash) = (line["path"].as_str().map(String::from), line["hash"].as_str().map(String::from));
        match line["op"].as_str().unwrap() {
            "write" => drop(files.insert(path.unwrap(), hash.unwrap())),
            "remove" => drop(files.remove(&path.unwrap())),
            "rename" => {
                let (from, path) = (line["from"].as_str().unwrap(), path.unwrap());
                if let Some(hash) = hash {
                    files.remove(from);
                    files.insert(path, hash);
                } else {
                    let prefix = format!("{from}/");
                    let moved: Vec<_> = files.keys().filter(|key| key.starts_with(&prefix)).cloned().collect();
                    for key in moved {
                        let hash = files.remove(&key).unwrap();
                        files.insert(format!("{path}/{}", &key[prefix.len()..]), hash);
                    }
                }
            }
            _ => {}
        }
    }
    files
}

pub fn hash(ws: &Workspace, path: &str) -> String {
    blake3::hash(&std::fs::read(ws.path().join(path)).unwrap()).to_hex().to_string()
}
