//! What git ignores in the workspace, which isn't recorded

use std::collections::HashMap;
use std::fs::File;
use std::io::{self, Read};
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use ignore::gitignore::{Gitignore, GitignoreBuilder};
use rustix::fs::{AtFlags, FileType, Mode, OFlags};

use crate::lock;

/// What git ignores, from each directory's `.gitignore`, read from the real workspace as needed. Only through fds
/// opened before the mount, without following symlinks, since a path into the mount would wait on the agent's
/// request that we're answering
pub struct Ignores {
    root: OwnedFd,
    /// Where it is, which reports name files by
    workspace: PathBuf,
    /// The workspace's path from the top of its repo, empty when it's the top or in none
    from_top: String,
    /// Of the repo, the `.gitignore`s above the workspace, deepest first, then `info/exclude`
    above: Mutex<Vec<Above>>,
    global: Gitignore,
    /// Of each directory in the workspace, by its path
    dirs: Mutex<HashMap<String, Rules>>,
}

/// A file of ignores outside the workspace
struct Above {
    /// The path from the repo's top that it applies under
    base: String,
    /// Its directory, and its name there
    dir: OwnedFd,
    file: &'static str,
    /// Its full path, which reports name it by
    path: PathBuf,
    rules: Rules,
}

impl Above {
    fn new(base: String, dir: OwnedFd, file: &'static str, path: PathBuf) -> Self {
        Self { base, dir, file, path, rules: Rules::default() }
    }
}

impl Ignores {
    pub fn new(root: OwnedFd, workspace: &Path) -> Self {
        let mut above = vec![];
        let mut from_top = String::new();
        let open =
            |dir: &Path| rustix::fs::open(dir, OFlags::PATH | OFlags::DIRECTORY | OFlags::CLOEXEC, Mode::empty());
        if let Some(top) = workspace.ancestors().find(|dir| dir.join(".git").exists()) {
            let base = |dir: &Path| dir.strip_prefix(top).map_or_default(|rel| rel.display().to_string());
            from_top = base(workspace);
            for dir in workspace.ancestors().skip(1).take_while(|dir| dir.starts_with(top)) {
                let path = dir.join(".gitignore");
                match open(dir) {
                    Ok(fd) => above.push(Above::new(base(dir), fd, ".gitignore", path)),
                    Err(err) => report(&path, &err.into()),
                }
            }
            let git_dir = git_dir(top);
            let path = git_dir.join("info/exclude");
            match open(&git_dir) {
                Ok(fd) => above.push(Above::new(String::new(), fd, "info/exclude", path)),
                Err(err) => report(&path, &err.into()),
            }
        }
        let (global, err) = Gitignore::global();
        if let Some(err) = err {
            eprintln!("otto-track: reading the global gitignore: {err}");
        }
        let workspace = workspace.to_path_buf();
        Self { root, workspace, from_top, above: Mutex::new(above), global, dirs: Mutex::default() }
    }

    /// Like git, which doesn't look in a directory it ignores, so nothing under one can be re-included
    pub fn ignored(&self, path: &str, is_dir: bool) -> bool {
        if path.split('/').any(|part| part == ".git") {
            return true;
        }
        let mut dirs = lock(&self.dirs);
        let mut above = lock(&self.above);
        // Each that applies, once
        for dir in parents(path) {
            let file = if dir.is_empty() { ".gitignore".to_string() } else { format!("{dir}/.gitignore") };
            let path = self.workspace.join(&file);
            dirs.entry(dir.to_string()).or_default().refresh(self.root.as_fd(), &file, &path);
        }
        for above in above.iter_mut() {
            above.rules.refresh(above.dir.as_fd(), above.file, &above.path);
        }
        // Each directory from the repo's top down, then the path itself
        let full = if self.from_top.is_empty() { path.to_string() } else { format!("{}/{path}", self.from_top) };
        let dirs_down = full.match_indices('/').map(|(i, _)| (&full[..i], true));
        dirs_down.chain([(full.as_str(), is_dir)]).any(|(path, is_dir)| self.excluded(&dirs, &above, path, is_dir))
    }

    /// Whether the rules that apply to `path` itself, from the repo's top, ignore it: the deepest `.gitignore` that
    /// says anything decides, then `info/exclude`, then the global ones
    fn excluded(&self, dirs: &HashMap<String, Rules>, above: &[Above], path: &str, is_dir: bool) -> bool {
        if let Some(rel) = under(path, &self.from_top) {
            for dir in parents(rel).rev() {
                let rules = dirs.get(dir).and_then(Rules::current);
                // past `dir` and its slash, which `parents` gives the prefixes of `rel` before
                let rest = &rel[dir.len() + usize::from(!dir.is_empty())..];
                if let Some(ignored) = decides(rules, rest, is_dir) {
                    return ignored;
                }
            }
        }
        for above in above {
            let Some(rel) = under(path, &above.base) else { continue };
            if let Some(ignored) = decides(above.rules.current(), rel, is_dir) {
                return ignored;
            }
        }
        decides(Some(&self.global), path, is_dir) == Some(true)
    }
}

/// The directories `path` is in, from the top: `""`, then each one's path
fn parents(path: &str) -> impl DoubleEndedIterator<Item = &str> {
    std::iter::once("").chain(path.match_indices('/').map(|(i, _)| &path[..i]))
}

/// The rest of `path` under the directory `dir`, if it's under it, where `""` has everything
fn under<'a>(path: &'a str, dir: &str) -> Option<&'a str> {
    if dir.is_empty() { Some(path) } else { path.strip_prefix(dir)?.strip_prefix('/') }
}

/// Whether `rules` ignore `path`, none when they say nothing of it
fn decides(rules: Option<&Gitignore>, path: &str, is_dir: bool) -> Option<bool> {
    let matched = rules?.matched(path, is_dir);
    (!matched.is_none()).then(|| matched.is_ignore())
}

fn report(file: &Path, err: &io::Error) {
    eprintln!("otto-track: reading {}: {err}", file.display());
}

/// A file's inode, size, and mtime's seconds and nanoseconds, none when it's missing
type Stamp = Option<(u64, i64, i64, u64)>;

/// A file of ignores, as of when it last changed, which anyone can, like the user, or a `mv` of its directory
#[derive(Default)]
struct Rules {
    /// Its stamp and what it held then, none before it's read, or while it can't be
    parsed: Option<(Stamp, Gitignore)>,
    /// Why it last couldn't be, so a lasting failure is reported once
    failed: Option<String>,
}

impl Rules {
    /// Reads `file` in `dir` again if it changed, or couldn't be read last time, reporting failures by its `path`
    fn refresh(&mut self, dir: BorrowedFd, file: &str, path: &Path) {
        let stamp = match rustix::fs::statat(dir, file, AtFlags::SYMLINK_NOFOLLOW) {
            // which git doesn't follow, so it has none
            Ok(st) if FileType::from_raw_mode(st.st_mode) != FileType::RegularFile => None,
            Ok(st) => Some((st.st_ino, st.st_size, st.st_mtime, st.st_mtime_nsec)),
            Err(rustix::io::Errno::NOENT | rustix::io::Errno::NOTDIR) => None,
            Err(err) => return self.fail(path, &err.into()),
        };
        if self.parsed.as_ref().is_some_and(|(parsed, _)| *parsed == stamp) {
            return;
        }
        match stamp.map_or_else(|| Ok(Gitignore::empty()), |_| parse(dir, file)) {
            Ok(rules) => {
                self.parsed = Some((stamp, rules));
                self.failed = None;
            }
            // since it was looked at, which the next look sees
            Err(err) if err.kind() == io::ErrorKind::NotFound => self.parsed = None,
            Err(err) => self.fail(path, &err),
        }
    }

    fn fail(&mut self, path: &Path, err: &io::Error) {
        self.parsed = None;
        let why = err.to_string();
        if self.failed.as_ref() != Some(&why) {
            report(path, err);
            self.failed = Some(why);
        }
    }

    /// What it held when last read, none when it couldn't be
    fn current(&self) -> Option<&Gitignore> {
        self.parsed.as_ref().map(|(_, rules)| rules)
    }
}

/// The rules in `file` in `dir`
fn parse(dir: BorrowedFd, file: &str) -> io::Result<Gitignore> {
    let flags = OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    let mut text = String::new();
    File::from(rustix::fs::openat(dir, file, flags, Mode::empty())?).read_to_string(&mut text)?;
    let mut builder = GitignoreBuilder::new("");
    for line in text.lines() {
        // like git, which skips a line it can't make sense of
        let _ = builder.add_line(None, line);
    }
    builder.build().map_err(io::Error::other)
}

/// The repo's git directory, shared by its worktrees, whose `.git` is a file that points to theirs
fn git_dir(top: &Path) -> PathBuf {
    let dot_git = top.join(".git");
    let Ok(text) = std::fs::read_to_string(&dot_git) else { return dot_git };
    let Some(dir) = text.trim().strip_prefix("gitdir: ").map(|dir| top.join(dir)) else { return dot_git };
    match std::fs::read_to_string(dir.join("commondir")) {
        Ok(common) => dir.join(common.trim()),
        Err(_) => dir,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_util::Temp;

    fn ignores(workspace: &Path) -> Ignores {
        let root = rustix::fs::open(workspace, OFlags::PATH | OFlags::DIRECTORY | OFlags::CLOEXEC, Mode::empty());
        Ignores::new(root.unwrap(), workspace)
    }

    /// A repo whose top is the workspace
    fn repo(name: &str) -> Temp {
        let temp = Temp::new(&format!("ignores-{name}"));
        std::fs::create_dir(temp.0.join(".git")).unwrap();
        temp.write(".gitignore", "*.gen\n/out/\n");
        temp.write("sub/.gitignore", "local.txt\n!keep.gen\n");
        temp
    }

    #[test]
    fn root_and_nested_gitignores() {
        let temp = repo("nested");
        let ignores = ignores(&temp.0);
        assert!(ignores.ignored("a.gen", false));
        assert!(ignores.ignored("sub/deeper/a.gen", false));
        assert!(ignores.ignored("sub/local.txt", false));
        assert!(!ignores.ignored("local.txt", false));
        assert!(!ignores.ignored("sub/kept.txt", false));
    }

    #[test]
    fn nested_negation_overrides_the_parent() {
        let temp = repo("negation");
        let ignores = ignores(&temp.0);
        assert!(!ignores.ignored("sub/keep.gen", false));
        assert!(ignores.ignored("keep.gen", false));
        assert!(ignores.ignored("other/keep.gen", false));
    }

    #[test]
    fn directories_only_when_is_dir() {
        let temp = repo("dirs");
        let ignores = ignores(&temp.0);
        assert!(ignores.ignored("out", true));
        assert!(!ignores.ignored("out", false));
        // and all under it
        assert!(ignores.ignored("out/file", false));
        assert!(ignores.ignored("out/deep/file", false));
        assert!(!ignores.ignored("sub/out", true));
    }

    #[test]
    fn under_git_always() {
        let temp = Temp::new("ignores-git");
        let ignores = ignores(&temp.0);
        assert!(ignores.ignored(".git", true));
        assert!(ignores.ignored(".git/config", false));
        assert!(ignores.ignored("sub/.git/HEAD", false));
        assert!(!ignores.ignored("sub/.gitx", false));
    }

    #[test]
    fn rereads_a_changed_gitignore() {
        let temp = repo("reread");
        let ignores = ignores(&temp.0);
        assert!(!ignores.ignored("plain.txt", false));
        assert!(!ignores.ignored("sub/plain.txt", false));
        // a different size, so the stamp differs even within the mtime's granularity
        temp.write(".gitignore", "*.gen\n/out/\nplain.txt\n");
        assert!(ignores.ignored("plain.txt", false));
        assert!(ignores.ignored("sub/plain.txt", false));
        std::fs::remove_file(temp.0.join(".gitignore")).unwrap();
        assert!(!ignores.ignored("plain.txt", false));
        assert!(!ignores.ignored("a.gen", false));
        temp.write("sub/.gitignore", "plain.txt\n");
        assert!(ignores.ignored("sub/plain.txt", false));
    }

    #[test]
    fn gitignores_above_the_workspace() {
        let temp = Temp::new("ignores-above");
        std::fs::create_dir(temp.0.join(".git")).unwrap();
        temp.write(".gitignore", "ws/top.txt\n*.above\n");
        temp.write("ws/.gitignore", "");
        temp.write(".git/info/exclude", "excluded.txt\n");
        let ignores = ignores(&temp.0.join("ws"));
        // with the workspace's path from the repo's top
        assert!(ignores.ignored("top.txt", false));
        assert!(!ignores.ignored("sub/top.txt", false));
        assert!(ignores.ignored("sub/a.above", false));
        assert!(ignores.ignored("excluded.txt", false));
        assert!(!ignores.ignored("plain.txt", false));
    }

    #[test]
    fn git_dir_of_a_worktree() {
        let temp = Temp::new("ignores-worktree");
        temp.write("main/.git/worktrees/wt/commondir", "../..\n");
        temp.write("wt/.git", "gitdir: ../main/.git/worktrees/wt\n");
        let dir = git_dir(&temp.0.join("wt"));
        assert_eq!(dir.canonicalize().unwrap(), temp.0.join("main/.git").canonicalize().unwrap());
        assert_eq!(git_dir(&temp.0.join("main")), temp.0.join("main/.git"));
    }

    #[test]
    fn nothing_under_an_ignored_directory_is_re_included() {
        let temp = repo("ignored-dir");
        temp.write("out/.gitignore", "!x\n!deep/\n");
        temp.write("sub/.gitignore", "local.txt\n!keep.gen\n/build/\n");
        temp.write("sub/build/.gitignore", "!y\n");
        let ignores = ignores(&temp.0);
        // like git, which doesn't look in out/ for a `.gitignore`
        assert!(ignores.ignored("out/x", false));
        assert!(ignores.ignored("out/deep", true));
        assert!(ignores.ignored("out/deep/x", false));
        assert!(ignores.ignored("sub/build/y", false));
        // but a directory can be, and what's under it then decides
        temp.write("sub/.gitignore", "/build/\n!/build/\n");
        assert!(!ignores.ignored("sub/build", true));
        assert!(!ignores.ignored("sub/build/y", false));
    }

    #[test]
    fn a_workspace_in_an_ignored_directory_is_ignored() {
        let temp = Temp::new("ignores-ignored-workspace");
        std::fs::create_dir(temp.0.join(".git")).unwrap();
        temp.write(".gitignore", "vendor/\n");
        temp.write("vendor/ws/.gitignore", "!x\n");
        let ignores = ignores(&temp.0.join("vendor/ws"));
        assert!(ignores.ignored("x", false));
        assert!(ignores.ignored("sub/y", false));
    }

    #[test]
    fn rereads_what_it_couldnt_read() {
        let temp = repo("unreadable");
        let ignores = ignores(&temp.0);
        // not UTF-8, which it doesn't take as no rules
        std::fs::write(temp.0.join(".gitignore"), b"*.gen\n\xff\n").unwrap();
        assert!(!ignores.ignored("a.gen", false));
        assert!(lock(&ignores.dirs)[""].failed.is_some());
        temp.write(".gitignore", "*.gen\n");
        assert!(ignores.ignored("a.gen", false));
        assert!(lock(&ignores.dirs)[""].failed.is_none());
    }
}
