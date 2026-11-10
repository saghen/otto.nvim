//! Files under the wrapper behave like on the real directory, with the tools agents use

mod common;

use std::io::Write;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use common::*;

#[test]
fn files_change_like_on_the_real_directory() {
    let ws = Workspace::new("files");
    std::fs::write(ws.path().join("a.txt"), "hello\n").unwrap();
    ws.sh(
        "a",
        "echo more >> a.txt; sed -i s/hello/bye/ a.txt
        ln -s a.txt link; ln a.txt hard; mkdir -p d/e; mv hard d/e/; mkfifo pipe
        printf new > d/e/hard; chmod 600 a.txt; touch -d 2001-01-01T00:00:00Z a.txt",
    );
    assert_eq!(ws.read("a.txt"), "new");
    assert_eq!(std::fs::read_link(ws.path().join("link")).unwrap(), Path::new("a.txt"));
    let meta = std::fs::metadata(ws.path().join("a.txt")).unwrap();
    assert_eq!((meta.nlink(), meta.permissions().mode() & 0o777), (2, 0o600));
    assert_eq!(meta.mtime(), 978_307_200);

    // The same inode numbers inside as out, which git's index keeps
    let inside = ws.sh("a", "stat -c %i a.txt").stdout;
    assert_eq!(String::from_utf8_lossy(&inside).trim(), meta.ino().to_string());
}

/// Sets `path`'s mode
fn chmod(path: &Path, mode: u32) {
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
}

/// Of each of `steps`, what it said on stderr, or `ok`, in a workspace with a read-only file and directory, and a
/// directory `open` with a file
fn outcomes(ws: &Workspace, steps: &[&str]) -> Vec<String> {
    let (ro, rodir, open) = (ws.path().join("ro"), ws.path().join("rodir"), ws.path().join("open"));
    std::fs::write(&ro, "kept").unwrap();
    std::fs::create_dir(&rodir).unwrap();
    std::fs::write(rodir.join("f"), "").unwrap();
    std::fs::create_dir(&open).unwrap();
    std::fs::write(open.join("f"), "").unwrap();
    chmod(&ro, 0o444);
    chmod(&rodir, 0o555);
    let script =
        "for step; do if said=$( (eval \"$step\") 2>&1); then echo ok; else echo \"$said\" | head -n 1; fi; done";
    let mut cmd = vec!["sh", "-c", script, "sh"];
    cmd.extend(steps);
    let output = ws.track("a", &cmd).output().unwrap();
    // or the workspace can't be removed
    chmod(&rodir, 0o755);
    chmod(&open, 0o755);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap().lines().map(str::to_string).collect()
}

#[test]
fn read_only_files_and_directories_stay_so() {
    const DENIED: &str = "Permission denied";
    if rustix::process::getuid().is_root() {
        return skip("root may change anything");
    }
    let ws = Workspace::new("read-only");
    let steps = [
        ("echo changed > ro", DENIED),
        ("mv rodir/f rodir/g", DENIED),
        ("rm rodir/f", DENIED),
        ("touch rodir/new", DENIED),
        // like the real directory, where only its owner may chmod it
        ("chmod 600 rodir/f", "ok"),
        // nor searched once it can't be, even through what was looked up before
        ("cat open/f", "ok"),
        ("chmod 600 open", "ok"),
        ("cat open/f", DENIED),
        ("chmod 700 open", "ok"),
        ("cat open/f", "ok"),
    ];
    let said = outcomes(&ws, &steps.map(|(step, _)| step));
    assert_eq!(said.len(), steps.len());
    for ((step, expected), said) in steps.iter().zip(&said) {
        assert!(said.contains(expected), "{step}: {said}");
    }
    assert_eq!(ws.read("ro"), "kept");
    assert!(ws.path().join("rodir/f").exists() && !ws.path().join("rodir/g").exists());
}

#[test]
fn creates_before_anything_else() {
    if skip_unless(&["python3"]) {
        return;
    }
    // Without a lookup of the root first, unlike most commands
    let ws = Workspace::new("first");
    let output = ws.track("a", &["python3", "-I", "-c", "open('f', 'w').close()"]).output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
}

#[test]
fn direct_io_works() {
    let ws = Workspace::new("direct");
    ws.sh("a", "dd if=/dev/zero of=d bs=4096 count=1 oflag=direct; dd if=d of=/dev/null bs=4096 iflag=direct");
}

#[test]
fn open_files_outlive_their_names() {
    if skip_unless(&["python3"]) {
        return;
    }
    let ws = Workspace::new("unlinked");
    let script = "
import mmap, os
fd = os.open('gone', os.O_RDWR | os.O_CREAT, 0o644)
os.unlink('gone')
os.write(fd, b'abc')
assert os.pread(fd, 3, 0) == b'abc'
assert open(f'/proc/self/fd/{fd}').read() == 'abc'
fd = os.open('mapped', os.O_RDWR | os.O_CREAT, 0o644)
os.ftruncate(fd, 4096)
m = mmap.mmap(fd, 4096)
os.rename('mapped', 'moved')
m[0:5] = b'mmap!'
m.close()
os.close(fd)
";
    ws.sh("a", &format!("python3 -c \"{script}\""));
    assert!(!ws.path().join("gone").exists());
    assert_eq!(&ws.read("moved")[..5], "mmap!");
}

#[test]
fn git_works() {
    if skip_unless(&["git"]) {
        return;
    }
    let ws = Workspace::new("git");
    ws.sh(
        "a",
        "git init -q; echo x > f; git add f
        git -c user.email=a@b -c user.name=a -c commit.gpgsign=false commit -qm init; echo y > f; git status --short > status",
    );
    assert_eq!(ws.read("status"), " M f\n?? status\n");
}

#[test]
fn editors_save() {
    if skip_unless(&["nvim"]) {
        return;
    }
    // Writing a new file and renaming it over the old, like most editors save
    let ws = Workspace::new("editor");
    std::fs::write(ws.path().join("e.txt"), "old\n").unwrap();
    ws.sh("a", "nvim --clean --headless -c 'set backupcopy=no' -c '%s/old/edited/' -c wq e.txt");
    assert_eq!(ws.read("e.txt"), "edited\n");
}

#[test]
fn nested_sandboxes_write_through() {
    if skip_unless(&["bwrap"]) {
        return;
    }
    let ws = Workspace::new("bwrap");
    ws.sh("a", "bwrap --dev-bind / / --unshare-user --unshare-pid sh -c 'echo sandboxed > b.txt'");
    assert_eq!(ws.read("b.txt"), "sandboxed\n");
}

#[test]
fn agents_share_one_live_file() {
    let ws = Workspace::new("shared");
    let script = "for i in $(seq 200); do echo $AGENT >> log; done";
    let children: Vec<_> = ["a", "b"]
        .into_iter()
        .map(|agent| ws.track(agent, &["sh", "-c", script]).env("AGENT", agent).spawn().unwrap())
        .collect();
    for mut child in children {
        assert!(child.wait().unwrap().success());
    }
    let log = ws.read("log");
    assert_eq!(log.lines().filter(|line| *line == "a").count(), 200);
    assert_eq!(log.lines().filter(|line| *line == "b").count(), 200);
}

#[test]
fn sees_changes_from_outside_at_once() {
    let ws = Workspace::new("fresh");
    std::fs::write(ws.path().join("f"), "0").unwrap();
    // What the file holds, whether the file the test made is there, and the next, which isn't yet
    let script = "while read n; do echo $(cat f) $(ls new$n) $(ls new$((n + 1)) 2>&1 | wc -l); done";
    let mut agent = ws.track("a", &["sh", "-c", script]).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    let mut stdin = agent.stdin.take().unwrap();
    let mut lines = std::io::BufRead::lines(std::io::BufReader::new(agent.stdout.take().unwrap()));
    for i in 1..300 {
        let (f, tmp) = (ws.path().join("f"), ws.path().join("tmp"));
        // in place, replaced, and moved away and back
        match i % 3 {
            0 => std::fs::write(&f, i.to_string()).unwrap(),
            1 => {
                std::fs::write(&tmp, i.to_string()).unwrap();
                std::fs::rename(&tmp, &f).unwrap();
            }
            _ => {
                std::fs::rename(&f, &tmp).unwrap();
                std::fs::write(&tmp, i.to_string()).unwrap();
                std::fs::rename(&tmp, &f).unwrap();
            }
        }
        std::fs::write(ws.path().join(format!("new{i}")), "").unwrap();
        writeln!(stdin, "{i}").unwrap();
        assert_eq!(lines.next().unwrap().unwrap(), format!("{i} new{i} 1"));
    }
    drop(stdin);
    assert!(agent.wait().unwrap().success());
}

/// How many flocks `by` waits on for the file at `path`, as the kernel lists them, by the process and inode, since the
/// list has every process's locks, of every filesystem
fn flock_waiters(by: &Child, path: &Path) -> usize {
    let (pid, ino) = (by.id().to_string(), std::fs::metadata(path).unwrap().ino().to_string());
    let locks = std::fs::read_to_string("/proc/locks").unwrap();
    let waits = |line: &&str| {
        // like `1: -> FLOCK  ADVISORY  WRITE <pid> <major>:<minor>:<inode> 0 EOF`
        let fields: Vec<_> = line.split_whitespace().collect();
        fields.get(1) == Some(&"->")
            && fields.get(2) == Some(&"FLOCK")
            && fields.get(5) == Some(&pid.as_str())
            && fields.get(6).and_then(|id| id.rsplit(':').next()) == Some(ino.as_str())
    };
    locks.lines().filter(waits).count()
}

#[test]
fn locks_hold_across_agents_and_outside() {
    if skip_unless(&["flock"]) {
        return;
    }
    let ws = Workspace::new("locks");
    let lock = ws.path().join("lock");
    std::fs::write(&lock, "").unwrap();
    let hold = ["flock", "-x", "lock", "sh", "-c", "echo held; read x"];
    let mut holder = Paused::spawn(&mut ws.track("a", &hold));
    holder.wait_until("held");

    let other = ws.track("b", &["flock", "-n", "lock", "true"]).status().unwrap();
    let outside = Command::new("flock").args(["-n", "lock", "true"]).current_dir(ws.path()).status().unwrap();
    assert_eq!((other.code(), outside.code()), (Some(1), Some(1)));

    // Waiting ones, more than it has threads, don't hold up the rest of the filesystem
    let waiters =
        "for i in $(seq 64); do flock -x lock true & done; read x; timeout 10 ls > /dev/null && echo listed; wait";
    let mut waiters = Paused::spawn(&mut ws.track("b", &["sh", "-c", waiters]));
    // through its wrapper, which waits on the real file for each
    until(Duration::from_secs(10), "the waiters aren't all waiting", || flock_waiters(&waiters.child, &lock) == 64);
    waiters.resume();
    waiters.wait_until("listed");
    holder.resume();
    assert!(holder.wait().success());
    assert!(waiters.wait().success());

    let mut outside = Paused::spawn(Command::new(hold[0]).args(&hold[1..]).current_dir(ws.path()));
    outside.wait_until("held");
    let inside = ws.track("a", &["flock", "-n", "lock", "true"]).status().unwrap();
    assert_eq!(inside.code(), Some(1));
    outside.resume();
    assert!(outside.wait().success());
}
