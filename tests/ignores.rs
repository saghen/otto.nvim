//! What git ignores, which isn't recorded, as it changes

mod common;

use std::process::Command;
use std::time::Duration;

use common::*;

#[test]
fn ignores_what_another_wrapper_ignored_since() {
    let ws = Workspace::new("gitignore");
    let script = "echo x > early; echo ready; read x; mkdir -p dist; echo y > dist/y";
    let mut a = Paused::spawn(&mut ws.track("a", &["sh", "-ec", script]));
    a.wait_until("ready");
    ws.sh("b", "echo dist/ >> .gitignore");
    a.resume();
    assert!(a.wait().success());
    assert!(!ops(&ws).iter().any(|op| op.contains("dist/")), "{:?}", ops(&ws));
}

#[test]
fn directories_moved_out_of_ignored_ones_are_written() {
    let ws = Workspace::new("unignore");
    std::fs::write(ws.path().join(".gitignore"), "tmp/\n").unwrap();
    ws.sh("a", "mkdir -p tmp/gen/sub; echo g > tmp/gen/x; echo s > tmp/gen/sub/y; mv tmp/gen gen");
    assert_eq!(ops(&ws), ["a write gen/sub/y", "a write gen/x"]);
}

#[test]
fn files_removed_outside_are_recreated_after_a_remove() {
    let ws = Workspace::new("recreate");
    ws.sh("a", "echo one > f; echo one > g");
    std::fs::remove_file(ws.path().join("f")).unwrap();
    std::fs::remove_file(ws.path().join("g")).unwrap();
    // Directly, and like editors and Claude Code save
    ws.sh("b", "echo two > f; echo two > g.tmp; mv g.tmp g");
    let ops = ops(&ws);
    assert_eq!(&ops[2..], ["- remove f", "b write f", "b write g.tmp", "- remove g", "b rename g.tmp -> g"]);
}

#[test]
fn workspaces_in_a_repo_have_git_and_its_ignores() {
    if skip_unless(&["git"]) {
        return;
    }
    let ws = Workspace::new("subdir");
    let repo = ws.path();
    let init = Command::new("git").arg("init").arg("-q").arg(&repo).output().unwrap();
    assert!(init.status.success(), "git init: {}: {}", init.status, String::from_utf8_lossy(&init.stderr));
    std::fs::write(repo.join(".gitignore"), "*.log\n").unwrap();
    std::fs::write(repo.join(".git/info/exclude"), "secret\n").unwrap();
    std::fs::create_dir(repo.join("pkg")).unwrap();
    let mut command =
        ws.track("a", &["sh", "-ec", "git status -s >/dev/null; echo > a.log; echo > secret; echo > kept"]);
    assert!(command.current_dir(repo.join("pkg")).status().unwrap().success());
    assert_eq!(ops(&ws), ["a write kept"]);
}

#[test]
fn directories_moved_onto_ignored_ones_are_ignored() {
    let ws = Workspace::new("dir-ignored");
    std::fs::write(ws.path().join(".gitignore"), "target/\n").unwrap();
    // Like cargo, which makes its build directory under another name first
    ws.sh("a", "mkdir t; echo x > t/f; mv t target; mv target back");
    assert_eq!(ops(&ws), ["a write t/f", "a remove t/f", "a write back/f"]);
}

#[test]
fn gitignores_count_as_of_now() {
    let ws = Workspace::new("gitignore-now");
    // changed from outside, and one that ignores itself, like a venv's, which comes after its directory
    let script = "echo > a.gen; echo ready; read x; echo > b.gen; mkdir v; echo '*' > v/.gitignore";
    let mut a = Paused::spawn(&mut ws.track("a", &["sh", "-ec", script]));
    a.wait_until("ready");
    std::fs::write(ws.path().join(".gitignore"), "*.gen\n").unwrap();
    a.resume();
    assert!(a.wait().success());
    assert_eq!(ops(&ws), ["a write a.gen"]);
}

#[test]
fn repos_and_linked_gitignores_are_read_from_outside_the_mount() {
    if skip_unless(&["git"]) {
        return;
    }
    let ws = Workspace::new("repo-top");
    let init = Command::new("git").arg("init").arg("-q").arg(ws.path()).output().unwrap();
    assert!(init.status.success(), "git init: {}: {}", init.status, String::from_utf8_lossy(&init.stderr));
    std::fs::write(ws.path().join(".git/info/exclude"), "secret\n").unwrap();
    std::fs::write(ws.path().join("shared"), "*.log\n").unwrap();
    std::os::unix::fs::symlink(ws.path().join("shared"), ws.path().join("sub.gitignore")).unwrap();
    std::fs::create_dir(ws.path().join("sub")).unwrap();
    std::fs::rename(ws.path().join("sub.gitignore"), ws.path().join("sub/.gitignore")).unwrap();
    // Through the mount, these would wait on the very request that reads them
    let mut child = ws.track("a", &["sh", "-ec", "echo > a; echo > secret; echo > sub/b.log"]).spawn().unwrap();
    assert!(wait_for(&mut child, Duration::from_secs(5)).success());
    // like git, which doesn't follow a linked `.gitignore`
    assert_eq!(ops(&ws), ["a write a", "a write sub/b.log"]);
}

#[test]
fn renaming_a_gitignore_away_drops_its_rules() {
    let ws = Workspace::new("unignored");
    std::fs::write(ws.path().join(".gitignore"), "ign\n").unwrap();
    ws.sh("a", "echo x > ign; mv .gitignore gitignore.bak; echo y > ign");
    assert!(ops(&ws).contains(&"a write ign".to_string()), "{:?}", ops(&ws));
}
