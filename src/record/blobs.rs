//! The store's `blobs/<hash>`, what each version of a file held, named by its blake3 hash

use std::fs::File;
use std::io::{self, Write};
use std::os::unix::fs::{FileExt, OpenOptionsExt};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

pub struct Blobs {
    dir: PathBuf,
    temp: AtomicU64,
}

impl Blobs {
    pub fn new(dir: PathBuf) -> io::Result<Self> {
        std::fs::create_dir_all(&dir)?;
        Ok(Self { dir, temp: AtomicU64::new(0) })
    }

    /// Hashes the file, and copies it to its blob unless that exists already
    pub fn store(&self, file: &File) -> io::Result<String> {
        let mut hasher = blake3::Hasher::new();
        hasher.update_reader(file)?;
        let hash = hasher.finalize().to_hex().to_string();
        if self.dir.join(&hash).exists() {
            return Ok(hash);
        }
        // Through a temp file, so a blob is whole whenever it exists, and hashed again as it's copied, since the file
        // may have changed since. Only for us, like the workspace's private files, since the umask is zeroed
        let n = self.temp.fetch_add(1, Ordering::Relaxed);
        let temp = self.dir.join(format!(".{}-{n}", std::process::id()));
        let mut out = File::options().write(true).create_new(true).mode(0o600).open(&temp)?;
        let mut hasher = blake3::Hasher::new();
        let copied = copy(file, &mut out, &mut hasher);
        let hash = hasher.finalize().to_hex().to_string();
        let blob = self.dir.join(&hash);
        match copied {
            // which matters more than a temp file left behind
            Err(err) => {
                let _ = std::fs::remove_file(&temp);
                Err(err)
            }
            Ok(()) if blob.exists() => std::fs::remove_file(&temp).map(|()| hash),
            Ok(()) => std::fs::rename(&temp, &blob).map(|()| hash),
        }
    }
}

/// Copies `file` from its start into `out`, hashing what it copies
fn copy(file: &File, out: &mut File, hasher: &mut blake3::Hasher) -> io::Result<()> {
    let mut buf = vec![0; 1 << 16];
    let mut offset = 0;
    loop {
        let read = file.read_at(&mut buf, offset)?;
        if read == 0 {
            return Ok(());
        }
        hasher.update(&buf[..read]);
        out.write_all(&buf[..read])?;
        offset += read as u64;
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;
    use crate::test_util::Temp;

    #[test]
    fn stores_each_version_once_for_us_only() {
        let temp = Temp::new("blobs-store");
        let blobs = Blobs::new(temp.0.join("blobs")).unwrap();
        temp.write("file", "hello");
        let hash = blobs.store(&File::open(temp.0.join("file")).unwrap()).unwrap();
        assert_eq!(hash, blake3::hash(b"hello").to_hex().as_str());
        let blob = temp.0.join("blobs").join(&hash);
        assert_eq!(std::fs::read_to_string(&blob).unwrap(), "hello");
        assert_eq!(std::fs::metadata(&blob).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(blobs.store(&File::open(temp.0.join("file")).unwrap()).unwrap(), hash);
        // and no temp file left
        assert_eq!(std::fs::read_dir(temp.0.join("blobs")).unwrap().count(), 1);
    }

    #[test]
    fn an_unreadable_file_says_why() {
        let temp = Temp::new("blobs-unreadable");
        let blobs = Blobs::new(temp.0.join("blobs")).unwrap();
        // which can't be read
        let dir = File::open(&temp.0).unwrap();
        let err = blobs.store(&dir).unwrap_err();
        assert_eq!(err.raw_os_error(), Some(rustix::io::Errno::ISDIR.raw_os_error()));
        assert_eq!(std::fs::read_dir(temp.0.join("blobs")).unwrap().count(), 0);
    }
}
