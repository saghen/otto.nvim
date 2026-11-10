//! What the unit tests share

use std::path::PathBuf;

/// A fresh directory for a test, named after it, removed when it's done
pub struct Temp(pub PathBuf);

impl Temp {
    /// Of a name unique across the tests, like `<module>-<test>`
    pub fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("otto-track-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    /// The ops of the log of the store under it, with their paths, and `- ` before those from outside
    pub fn ops(&self) -> Vec<String> {
        let log = std::fs::read_to_string(self.0.join("store/log.jsonl")).unwrap();
        let lines = log.lines().map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap());
        let op = |line: serde_json::Value| {
            let outside = if line["agent"].is_null() { "- " } else { "" };
            let from = line["from"].as_str().map_or_else(String::new, |from| format!("{from} -> "));
            format!("{outside}{} {from}{}", line["op"].as_str().unwrap(), line["path"].as_str().unwrap())
        };
        lines.map(op).collect()
    }

    /// Writes `text` to `path` under it, with the directories between
    pub fn write(&self, path: &str, text: &str) {
        let path = self.0.join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }
}

impl Drop for Temp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
