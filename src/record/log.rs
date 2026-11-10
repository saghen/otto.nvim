//! The log that every agent's wrapper appends to, a line per change, and what it says of each path as read so far

use std::collections::HashMap;
use std::fs::File;
use std::io::{self, Write};
use std::os::unix::fs::FileExt;

use rustix::fs::FlockOperation;
use serde::{Deserialize, Serialize};

/// What a line says happened, with what each kind of change says. On disk, its fields beside the line's, and its kind
/// as `op`
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Debug)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum Op {
    /// Of an agent, before its changes
    Start,
    /// A version of the file `path`
    Write {
        path: String,
        hash: String,
        /// What the path held before, only when it isn't its last hash in the log, see `Locked::write`. `""` for
        /// nothing, which the Lua reader turns back into none
        #[serde(default, skip_serializing_if = "Option::is_none")]
        before: Option<String>,
    },
    Remove {
        path: String,
    },
    /// From `from` to `path`, with the hash of a file, or none for a directory, which moves everything under it
    Rename {
        from: String,
        path: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        hash: Option<String>,
    },
}

#[derive(Serialize, Deserialize)]
pub struct Line {
    #[serde(default)]
    pub at: u64,
    /// None for a change from outside, like the user's, which a wrapper caught up on
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cmd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub commands: Option<Vec<Vec<String>>>,
    #[serde(flatten)]
    pub op: Op,
}

impl Op {
    /// The path it changed, of any but a start
    pub fn path(&self) -> Option<&str> {
        match self {
            Self::Start => None,
            Self::Write { path, .. } | Self::Remove { path } | Self::Rename { path, .. } => Some(path),
        }
    }
}

impl Line {
    /// Of `op`, by no one yet
    pub fn new(op: Op) -> Self {
        Self { at: 0, agent: None, pid: None, cmd: None, commands: None, op }
    }
}

/// What the log says a path holds, as of its last line
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Last<'a> {
    /// It says nothing of it
    Unknown,
    Hash(&'a str),
    Removed,
}

impl Last<'_> {
    /// Whether it says the path holds `hash`, or nothing for none
    pub fn holds(self, hash: Option<&str>) -> bool {
        match (self, hash) {
            (Self::Hash(last), Some(hash)) => last == hash,
            (Self::Unknown | Self::Removed, None) => true,
            _ => false,
        }
    }
}

/// A path whose last line is a change from outside
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Outside {
    /// Where its line starts
    pub offset: u64,
    /// What was there before it, `""` for nothing
    pub before: String,
}

/// The log as far as we've read it, which other wrappers append to as well
pub struct Log {
    file: File,
    /// Where it's been read up to, which changes after are past
    pub read: u64,
    /// The last hash of each path, or none once removed
    last: HashMap<String, Option<String>>,
    /// Each path whose last line is a change from outside
    pub outside: HashMap<String, Outside>,
}

impl Log {
    /// Of the log `file`, opened to read and append, read from its start
    pub fn new(file: File) -> Self {
        Self { file, read: 0, last: HashMap::new(), outside: HashMap::new() }
    }

    /// Takes the log's lock, across processes, and reads what was appended before it, so what's appended while it's
    /// held follows what's been read. Until `release`
    pub fn hold(&mut self) -> io::Result<()> {
        rustix::fs::flock(&self.file, FlockOperation::LockExclusive)?;
        self.read_appended()
    }

    pub fn release(&self) {
        // which the kernel does anyway once the file's closed
        let _ = rustix::fs::flock(&self.file, FlockOperation::Unlock);
    }

    /// Reads what's been appended since we last looked, whole lines only
    fn read_appended(&mut self) -> io::Result<()> {
        let mut buf = Vec::new();
        let mut chunk = vec![0; 1 << 16];
        loop {
            let n = self.file.read_at(&mut chunk, self.read + buf.len() as u64)?;
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&chunk[..n]);
        }
        let Some(end) = buf.iter().rposition(|&b| b == b'\n') else { return Ok(()) };
        for line in buf[..end].split(|&b| b == b'\n') {
            let offset = self.read;
            self.read += line.len() as u64 + 1;
            if let Ok(line) = serde_json::from_slice::<Line>(line) {
                self.apply(line, offset);
            }
        }
        Ok(())
    }

    /// Appends `line`, and reads it. Only while it's held, so nothing comes between
    pub fn append(&mut self, line: Line) -> io::Result<()> {
        let mut json = serde_json::to_vec(&line)?;
        json.push(b'\n');
        // One write, which `O_APPEND` keeps whole across processes
        (&self.file).write_all(&json)?;
        let offset = self.read;
        self.read += json.len() as u64;
        self.apply(line, offset);
        Ok(())
    }

    pub fn last(&self, path: &str) -> Last<'_> {
        match self.last.get(path) {
            None => Last::Unknown,
            Some(Some(hash)) => Last::Hash(hash),
            Some(None) => Last::Removed,
        }
    }

    /// The files under `dir` that the log says exist, in order
    pub fn files_under(&self, dir: &str) -> Vec<String> {
        let prefix = format!("{dir}/");
        let mut paths: Vec<_> = self
            .last
            .iter()
            .filter(|(path, hash)| path.starts_with(&prefix) && hash.is_some())
            .map(|(path, _)| path.clone())
            .collect();
        paths.sort();
        paths
    }

    fn apply(&mut self, line: Line, offset: u64) {
        let outside = line.agent.is_none();
        let path = match line.op {
            Op::Start => return,
            Op::Write { path, hash, .. } => {
                let before = self.last.insert(path.clone(), Some(hash)).flatten();
                if outside {
                    self.outside.insert(path, Outside { offset, before: before.unwrap_or_default() });
                    return;
                }
                path
            }
            Op::Remove { path } => {
                self.last.insert(path.clone(), None);
                path
            }
            Op::Rename { from, path, hash: Some(hash) } => {
                self.last.insert(from, None);
                self.last.insert(path.clone(), Some(hash));
                path
            }
            // a directory, which moves everything under it
            Op::Rename { from, path, hash: None } => {
                let prefix = format!("{from}/");
                let moved: Vec<_> = self.last.keys().filter(|key| key.starts_with(&prefix)).cloned().collect();
                for key in moved {
                    let hash = self.last.insert(key.clone(), None).flatten();
                    self.last.insert(format!("{path}/{}", &key[prefix.len()..]), hash);
                }
                path
            }
        };
        self.outside.remove(&path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_util::Temp;

    fn log(temp: &Temp) -> Log {
        Log::new(File::options().read(true).append(true).create(true).open(temp.0.join("log.jsonl")).unwrap())
    }

    /// By the agent `agent`, or from outside for none
    fn line(op: Op, agent: Option<&str>) -> Line {
        Line { agent: agent.map(Into::into), ..Line::new(op) }
    }

    fn write(path: &str, hash: &str) -> Op {
        Op::Write { path: path.into(), hash: hash.into(), before: None }
    }

    fn remove(path: &str) -> Op {
        Op::Remove { path: path.into() }
    }

    fn rename(from: &str, path: &str, hash: Option<&str>) -> Op {
        Op::Rename { from: from.into(), path: path.into(), hash: hash.map(Into::into) }
    }

    fn outside(offset: u64, before: Option<&str>) -> Outside {
        Outside { offset, before: before.unwrap_or_default().into() }
    }

    #[test]
    fn apply_writes_and_removes() {
        let temp = Temp::new("log-write");
        let mut log = log(&temp);
        log.apply(line(write("a", "h1"), Some("x")), 0);
        assert_eq!(log.last("a"), Last::Hash("h1"));
        log.apply(line(write("a", "h2"), Some("x")), 0);
        assert_eq!(log.last("a"), Last::Hash("h2"));
        log.apply(line(remove("a"), Some("x")), 0);
        assert_eq!(log.last("a"), Last::Removed);
        // nor a start
        log.apply(line(Op::Start, Some("x")), 0);
        assert_eq!(log.last.len(), 1);
    }

    #[test]
    fn apply_renames_a_file() {
        let temp = Temp::new("log-rename-file");
        let mut log = log(&temp);
        log.apply(line(write("a", "h1"), Some("x")), 0);
        log.apply(line(rename("a", "b", Some("h1")), Some("x")), 0);
        assert_eq!(log.last("a"), Last::Removed);
        assert_eq!(log.last("b"), Last::Hash("h1"));
    }

    #[test]
    fn apply_renames_a_dir() {
        let temp = Temp::new("log-rename-dir");
        let mut log = log(&temp);
        log.apply(line(write("d/a", "h1"), Some("x")), 0);
        log.apply(line(write("d/b/c", "h2"), Some("x")), 0);
        log.apply(line(remove("d/gone"), Some("x")), 0);
        log.apply(line(write("dx/a", "h3"), Some("x")), 0);
        log.apply(line(rename("d", "e", None), Some("x")), 0);
        assert_eq!(log.last("d/a"), Last::Removed);
        assert_eq!(log.last("d/b/c"), Last::Removed);
        assert_eq!(log.last("e/a"), Last::Hash("h1"));
        assert_eq!(log.last("e/b/c"), Last::Hash("h2"));
        assert_eq!(log.last("e/gone"), Last::Removed);
        // which only shares a prefix
        assert_eq!(log.last("dx/a"), Last::Hash("h3"));
        assert_eq!(log.last("ex/a"), Last::Unknown);
        assert_eq!(log.last("e"), Last::Unknown);
        assert_eq!(log.files_under("e"), ["e/a", "e/b/c"]);
        assert_eq!(log.files_under("d"), Vec::<String>::new());
    }

    #[test]
    fn last_holds() {
        assert!(Last::Hash("h").holds(Some("h")));
        assert!(!Last::Hash("h").holds(Some("g")));
        assert!(!Last::Hash("h").holds(None));
        assert!(Last::Removed.holds(None));
        assert!(Last::Unknown.holds(None));
        assert!(!Last::Unknown.holds(Some("h")));
    }

    #[test]
    fn apply_tracks_changes_from_outside() {
        let temp = Temp::new("log-outside");
        let mut log = log(&temp);
        log.apply(line(write("a", "h1"), Some("x")), 0);
        log.apply(line(write("a", "h2"), None), 10);
        assert_eq!(log.outside.get("a"), Some(&outside(10, Some("h1"))));
        // with nothing before
        log.apply(line(write("new", "h3"), None), 20);
        assert_eq!(log.outside.get("new"), Some(&outside(20, None)));
        // until an agent changes it
        log.apply(line(write("a", "h4"), Some("x")), 30);
        assert_eq!(log.outside.get("a"), None);
        // and a removal from outside isn't one
        log.apply(line(remove("new"), None), 40);
        assert_eq!(log.outside.get("new"), None);
    }

    #[test]
    fn read_appended_reads_whole_lines() {
        let temp = Temp::new("log-catch-up");
        let mut log = log(&temp);
        let first = r#"{"op":"write","agent":"x","path":"a","hash":"h1"}"#;
        let second = r#"{"op":"write","path":"a","hash":"h2"}"#;
        let partial = r#"{"op":"write","agent":"x","path":"b","#;
        (&log.file).write_all(format!("{first}\nnot json\n{second}\n{partial}").as_bytes()).unwrap();
        log.read_appended().unwrap();
        let through_second = (first.len() + "not json".len() + second.len() + 3) as u64;
        assert_eq!(log.read, through_second);
        assert_eq!(log.last("a"), Last::Hash("h2"));
        // at the offset its line starts
        assert_eq!(log.outside.get("a"), Some(&outside((first.len() + "not json".len() + 2) as u64, Some("h1"))));
        assert_eq!(log.last("b"), Last::Unknown);
        (&log.file).write_all(br#""hash":"h3"}"#).unwrap();
        (&log.file).write_all(b"\n").unwrap();
        log.read_appended().unwrap();
        assert_eq!(log.last("b"), Last::Hash("h3"));
        assert_eq!(log.read, std::fs::metadata(temp.0.join("log.jsonl")).unwrap().len());
    }

    #[test]
    fn append_writes_a_line_and_reads_it() {
        let temp = Temp::new("log-append");
        let mut log = log(&temp);
        let before = Some("h0".into());
        log.append(line(Op::Write { path: "a".into(), hash: "h1".into(), before }, Some("x"))).unwrap();
        let before = Some(String::new());
        log.append(line(Op::Write { path: "b".into(), hash: "h2".into(), before }, Some("x"))).unwrap();
        log.append(line(rename("b", "c", Some("h2")), Some("x"))).unwrap();
        let text = std::fs::read_to_string(temp.0.join("log.jsonl")).unwrap();
        assert_eq!(log.read, text.len() as u64);
        assert_eq!(log.last("a"), Last::Hash("h1"));
        assert_eq!(log.last("b"), Last::Removed);
        // in the format the Lua reader reads
        let lines: Vec<_> = text.lines().collect();
        assert_eq!(lines[0], r#"{"at":0,"agent":"x","op":"write","path":"a","hash":"h1","before":"h0"}"#);
        assert_eq!(lines[1], r#"{"at":0,"agent":"x","op":"write","path":"b","hash":"h2","before":""}"#);
        assert_eq!(lines[2], r#"{"at":0,"agent":"x","op":"rename","from":"b","path":"c","hash":"h2"}"#);
        // and back
        let mut again = Log::new(File::open(temp.0.join("log.jsonl")).unwrap());
        again.read_appended().unwrap();
        assert_eq!(again.last("c"), Last::Hash("h2"));
        let parsed: Line = serde_json::from_str(lines[1]).unwrap();
        assert_eq!(parsed.op, Op::Write { path: "b".into(), hash: "h2".into(), before: Some(String::new()) });
        // and a line missing what its op needs is none
        assert!(serde_json::from_str::<Line>(r#"{"op":"rename","path":"c"}"#).is_err());
    }
}
