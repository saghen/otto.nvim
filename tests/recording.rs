//! What the log records of agents' changes, and who it says made them

mod common;

use std::os::unix::process::ExitStatusExt;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use rustix::process::Signal;

use common::*;

#[test]
fn records_changes_by_agent() {
    let ws = Workspace::new("record");
    std::fs::write(ws.path().join("a.txt"), "hello\n").unwrap();
    std::fs::write(ws.path().join(".gitignore"), "target/\n*.log\n").unwrap();
    ws.sh(
        "claude",
        "echo more >> a.txt; sed -i s/hello/bye/ a.txt; echo new > b.txt; mv b.txt c.txt; unlink c.txt
        mkdir -p target .git d; echo x > target/out; echo y > x.log; echo z > .git/HEAD; echo f > d/f; mv d e
        truncate -s 0 e/f; mkdir t; echo t > t/f; mv t target",
    );
    let sed = ops(&ws).iter().find(|op| op.contains(" write sed")).unwrap().split(' ').nth(2).unwrap().to_string();
    assert_eq!(
        ops(&ws),
        [
            "- write a.txt".to_string(),
            "claude write a.txt".into(),
            format!("claude write {sed}"),
            format!("claude rename {sed} -> a.txt"),
            "claude write b.txt".into(),
            "claude rename b.txt -> c.txt".into(),
            "claude remove c.txt".into(),
            "claude write d/f".into(),
            "claude rename d -> e".into(),
            "claude write e/f".into(),
            "claude write t/f".into(),
            "claude remove t/f".into(),
        ]
    );
    let start = &log(&ws)[0];
    assert_eq!((start["op"].as_str(), start["agent"].as_str()), (Some("start"), Some("claude")));
    // The agent's own writes have its pid, and its commands' their own
    let lines = log(&ws);
    assert_eq!(lines[2]["pid"], start["pid"]);
    assert_eq!(lines[3]["cmd"], "sed");
    // And the command lines from the agent's child down, which tell its tool calls apart
    assert_eq!(lines[3]["commands"], serde_json::json!([["sed", "-i", "s/hello/bye/", "a.txt"]]));
    assert!(lines[2].get("commands").is_none());
    for line in &lines {
        if let Some(hash) = line["hash"].as_str() {
            assert!(ws.0.join("store/blobs").join(hash).exists());
        }
    }
    assert_eq!(replay(&ws)["a.txt"], hash(&ws, "a.txt"));
}

#[test]
fn catches_up_on_changes_from_outside() {
    let ws = Workspace::new("outside");
    ws.sh("a", "echo one > f");
    std::fs::write(ws.path().join("f"), "two\n").unwrap();
    // Before `O_TRUNC` loses it
    ws.sh("a", "echo three > f");
    // Nothing changed outside, so nothing to catch up on
    ws.sh("b", "echo four >> f");
    assert_eq!(ops(&ws), ["a write f", "- write f", "a write f", "b write f"]);
    let blobs = ws.0.join("store/blobs");
    let outside = log(&ws)[3]["hash"].as_str().unwrap().to_string();
    assert_eq!(std::fs::read_to_string(blobs.join(outside)).unwrap(), "two\n");
}

#[test]
fn agents_writing_one_file_give_one_log() {
    let ws = Workspace::new("race");
    let script = "for i in $(seq 100); do echo $AGENT$i >> f; [ $((i % 10)) = 0 ] && sed -i 1d f; done; true";
    let children: Vec<_> = ["a", "b"]
        .into_iter()
        .map(|agent| ws.track(agent, &["sh", "-c", script]).env("AGENT", agent).spawn().unwrap())
        .collect();
    for mut child in children {
        assert!(child.wait().unwrap().success());
    }
    assert_eq!(replay(&ws).get("f"), Some(&hash(&ws, "f")));
    let ops = ops(&ws);
    // each, but fewer than each wrote, since one's record covers the other's appends when they come between, as many
    // as the scheduler puts there
    assert!(ops.iter().any(|op| op.starts_with("a write f")));
    assert!(ops.iter().any(|op| op.starts_with("b write f")));
}

#[test]
fn records_files_only_created_or_truncated() {
    let ws = Workspace::new("touch");
    std::fs::write(ws.path().join("full"), "full\n").unwrap();
    ws.sh("a", "touch new; : > full");
    assert_eq!(ops(&ws), ["a write new", "- write full", "a write full"]);
}

#[test]
fn threads_count_as_their_process() {
    if skip_unless(&["python3"]) {
        return;
    }
    let ws = Workspace::new("threads");
    let script =
        "import threading; t = threading.Thread(target=lambda: open('t', 'w').write('x')); t.start(); t.join()";
    let output = ws.track("a", &["python3", "-c", script]).output().unwrap();
    assert!(output.status.success());
    let lines = log(&ws);
    assert_eq!((lines[1]["op"].as_str(), &lines[1]["pid"]), (Some("write"), &lines[0]["pid"]));
}

/// Every blob holds what its name says
fn assert_blobs_whole(ws: &Workspace) {
    for blob in std::fs::read_dir(ws.0.join("store/blobs")).unwrap().flatten() {
        let name = blob.file_name().into_string().unwrap();
        assert_eq!(blake3::hash(&std::fs::read(blob.path()).unwrap()).to_hex().as_str(), name);
    }
}

#[test]
fn blobs_stay_whole_while_files_change() {
    let ws = Workspace::new("blobs");
    std::fs::write(ws.path().join("f"), vec![b'x'; 4 << 20]).unwrap();
    let path = ws.path().join("f");
    let stop = Arc::new(AtomicBool::new(false));
    // until the agent's done, so each of its catch-ups copies the file while it changes
    let writer = std::thread::spawn({
        let stop = stop.clone();
        move || {
            let mut i = 0u8;
            while !stop.load(Ordering::Relaxed) {
                std::fs::write(&path, vec![i; 4 << 20]).unwrap();
                i = i.wrapping_add(1);
            }
        }
    });
    ws.sh("a", "for i in $(seq 20); do : >> f; done");
    stop.store(true, Ordering::Relaxed);
    writer.join().unwrap();
    assert_blobs_whole(&ws);
}

#[test]
fn fallocate_is_a_write() {
    if skip_unless(&["fallocate"]) {
        return;
    }
    let ws = Workspace::new("fallocate");
    std::fs::write(ws.path().join("f"), "x").unwrap();
    // without writing, or truncating it
    ws.sh("a", "fallocate -l 4096 f");
    assert_eq!(ops(&ws), ["- write f", "a write f"]);
    assert_eq!(std::fs::metadata(ws.path().join("f")).unwrap().len(), 4096);
    assert_eq!(replay(&ws).get("f"), Some(&hash(&ws, "f")));
}

/// Runs `script` in Python under `agent`, until it's written, then `between`, then the rest
fn written_then(ws: &Workspace, agent: &str, script: &str, between: impl FnOnce()) {
    let script = script.replace("WRITTEN", "print('written', flush=True); input()");
    let mut agent = Paused::spawn(&mut ws.track(agent, &["python3", "-c", &script]));
    agent.wait_until("written");
    between();
    agent.resume();
    assert!(agent.wait().success());
}

#[test]
fn claims_what_another_wrapper_caught_up_on() {
    if skip_unless(&["python3"]) {
        return;
    }
    // b opens f for writing while a's write is in it but not recorded, and records it as from outside
    let ws = Workspace::new("claim");
    std::fs::write(ws.path().join("f"), "").unwrap();
    let script = "import os; fd = os.open('f', os.O_WRONLY); os.write(fd, b'from a'); WRITTEN; os.close(fd)";
    written_then(&ws, "a", script, || drop(ws.sh("b", ": >> f")));
    let claimed = log(&ws).into_iter().find(|line| line["agent"] == "a" && line["op"] == "write").unwrap();
    assert_eq!(claimed["hash"], blake3::hash(b"from a").to_hex().as_str());
    assert_eq!(claimed["before"], blake3::hash(b"").to_hex().as_str());
}

#[test]
fn claims_what_another_wrapper_caught_up_on_in_part() {
    if skip_unless(&["python3"]) {
        return;
    }
    let ws = Workspace::new("claim-part");
    std::fs::write(ws.path().join("f"), "base\n").unwrap();
    let script = "import os; fd = os.open('f', os.O_WRONLY | os.O_APPEND); os.write(fd, b'part\\n'); WRITTEN; \
        os.write(fd, b'rest\\n'); os.close(fd)";
    written_then(&ws, "a", script, || drop(ws.sh("b", "touch f")));
    let claimed = log(&ws).into_iter().find(|line| line["agent"] == "a" && line["op"] == "write").unwrap();
    assert_eq!(claimed["before"], blake3::hash(b"base\n").to_hex().as_str());
}

#[test]
fn claims_a_new_file_with_nothing_before() {
    if skip_unless(&["python3"]) {
        return;
    }
    let ws = Workspace::new("claim-new");
    let script = "import os; fd = os.open('f', os.O_WRONLY | os.O_CREAT); os.write(fd, b'from a'); WRITTEN; \
        os.close(fd)";
    written_then(&ws, "a", script, || drop(ws.sh("b", ": >> f")));
    let claimed = log(&ws).into_iter().find(|line| line["agent"] == "a" && line["op"] == "write").unwrap();
    assert_eq!(claimed["before"], "");
}

#[test]
fn commands_run_under_others_have_their_lines() {
    let ws = Workspace::new("commands");
    ws.sh("a", "sh -c 'touch f; :'; :");
    let line = log(&ws).into_iter().find(|line| line["op"] == "write").unwrap();
    assert_eq!(line["commands"], serde_json::json!([["sh", "-c", "touch f; :"], ["touch", "f"]]));
}

#[test]
fn records_mmap_writes_of_an_agent_that_dies() {
    if skip_unless(&["python3"]) {
        return;
    }
    let ws = Workspace::new("mmap");
    std::fs::write(ws.path().join("f"), "x").unwrap();
    // Without the fd that Python's `mmap` keeps, so only `release` sees the write
    let script = "import os; from ctypes import *; fd = os.open('f', os.O_RDWR); mmap = CDLL(None).mmap; \
        mmap.restype, mmap.argtypes = c_void_p, [c_void_p, c_size_t, c_int, c_int, c_int, c_long]; \
        p = mmap(None, 1, 3, 1, fd, 0); os.close(fd); memset(p, ord('y'), 1); os.kill(os.getpid(), 9)";
    let output = ws.track("a", &["python3", "-c", script]).output().unwrap();
    assert_eq!(output.status.signal(), Some(Signal::KILL.as_raw()));
    assert_eq!(ws.read("f"), "y");
    assert_eq!(replay(&ws)["f"], hash(&ws, "f"));
}

#[test]
fn temp_files_of_the_agent_are_its_own() {
    if skip_unless(&["python3"]) {
        return;
    }
    let ws = Workspace::new("temp");
    let script = "import os, tempfile; fd, path = tempfile.mkstemp(dir='.'); os.write(fd, b'x'); os.unlink(path)";
    ws.sh("a", &format!("python3 -c \"{script}\""));
    assert!(ops(&ws).iter().all(|op| !op.starts_with("- ")), "{:?}", ops(&ws));
}

#[test]
fn temp_files_moved_before_closing_are_written_first() {
    if skip_unless(&["python3"]) {
        return;
    }
    let ws = Workspace::new("open-temp");
    std::fs::write(ws.path().join("f"), "old").unwrap();
    let script = "import os\nfor name in ['f', 'g']:\n    t = open(name + '.tmp', 'w'); t.write('new'); t.flush()\n    \
        os.replace(name + '.tmp', name); t.write('er'); t.close()";
    assert!(ws.track("a", &["python3", "-c", script]).status().unwrap().success());
    assert_eq!(
        ops(&ws),
        [
            "- write f",
            "a write f.tmp",
            "a rename f.tmp -> f",
            "a write f",
            "a write g.tmp",
            "a rename g.tmp -> g",
            "a write g"
        ]
    );
    assert_eq!(replay(&ws)["g"], hash(&ws, "g"));
}

#[test]
fn symlinks_over_files_remove_them() {
    let ws = Workspace::new("symlink-over");
    std::fs::write(ws.path().join("f"), "old").unwrap();
    ws.sh("a", "echo t > t; ln -sf t f");
    assert_eq!(ops(&ws), ["a write t", "- write f", "a remove f"]);
}

#[test]
fn files_change_by_their_other_names() {
    let ws = Workspace::new("hardlink");
    ws.sh("a", "echo a > f; ln f g; unlink f; echo b >> g");
    assert_eq!(ops(&ws), ["a write f", "a write g", "a remove f", "a write g"]);
    assert_eq!(replay(&ws)["g"], hash(&ws, "g"));
}

#[test]
fn exchanges_swap_both() {
    let ws = Workspace::new("exchange");
    // Outside the mount, since it needs coreutils 9.5, and a filesystem that can
    let probe = ws.0.join("probe");
    std::fs::create_dir(&probe).unwrap();
    std::fs::write(probe.join("a"), "").unwrap();
    std::fs::write(probe.join("b"), "").unwrap();
    let probed = Command::new("mv").args(["--exchange", "a", "b"]).current_dir(&probe).stderr(Stdio::null()).status();
    if !probed.unwrap().success() {
        return skip("mv can't --exchange here");
    }
    std::fs::write(ws.path().join("a"), "one\n").unwrap();
    std::fs::write(ws.path().join("b"), "two\n").unwrap();
    let output = ws.track("x", &["mv", "--exchange", "a", "b"]).output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!((ws.read("a"), ws.read("b")), ("two\n".into(), "one\n".into()));
    let files = replay(&ws);
    assert_eq!((&files["a"], &files["b"]), (&hash(&ws, "a"), &hash(&ws, "b")));
}
