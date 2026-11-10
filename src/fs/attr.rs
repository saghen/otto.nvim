//! Attributes, between what the kernel asks of FUSE and what `stat` tells us

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fuser::{FileAttr, FileType, INodeNo, TimeOrNow};
use rustix::fs::{Stat, Timespec};

/// A lookup's reply for nothing there
pub(super) const NOTHING: FileAttr = FileAttr {
    ino: INodeNo(0),
    size: 0,
    blocks: 0,
    atime: UNIX_EPOCH,
    mtime: UNIX_EPOCH,
    ctime: UNIX_EPOCH,
    crtime: UNIX_EPOCH,
    kind: FileType::RegularFile,
    perm: 0,
    nlink: 0,
    uid: 0,
    gid: 0,
    rdev: 0,
    blksize: 0,
    flags: 0,
};

pub(super) fn time(secs: i64, nanos: u64) -> SystemTime {
    match u64::try_from(secs) {
        Ok(secs) => UNIX_EPOCH + Duration::from_secs(secs) + Duration::from_nanos(nanos),
        Err(_) => UNIX_EPOCH - Duration::from_secs(secs.unsigned_abs()) + Duration::from_nanos(nanos),
    }
}

pub(super) fn kind(kind: rustix::fs::FileType) -> FileType {
    use rustix::fs::FileType as F;
    match kind {
        F::Directory => FileType::Directory,
        F::Symlink => FileType::Symlink,
        F::Fifo => FileType::NamedPipe,
        F::Socket => FileType::Socket,
        F::CharacterDevice => FileType::CharDevice,
        F::BlockDevice => FileType::BlockDevice,
        _ => FileType::RegularFile,
    }
}

/// Of the node `id`, which the kernel takes for its inode number
pub(super) fn attr(id: INodeNo, st: &Stat) -> FileAttr {
    FileAttr {
        ino: id,
        size: st.st_size.cast_unsigned(),
        blocks: st.st_blocks.cast_unsigned(),
        atime: time(st.st_atime, st.st_atime_nsec),
        mtime: time(st.st_mtime, st.st_mtime_nsec),
        ctime: time(st.st_ctime, st.st_ctime_nsec),
        crtime: time(st.st_ctime, st.st_ctime_nsec),
        kind: kind(rustix::fs::FileType::from_raw_mode(st.st_mode)),
        perm: (st.st_mode & 0o7777) as u16,
        nlink: u32::try_from(st.st_nlink).unwrap_or(u32::MAX),
        uid: st.st_uid,
        gid: st.st_gid,
        // which FUSE has 32 bits of, enough for any device whose numbers fit its encoding
        rdev: u32::try_from(st.st_rdev).unwrap_or_default(),
        blksize: u32::try_from(st.st_blksize).unwrap_or(u32::MAX),
        flags: 0,
    }
}

pub(super) fn timespec(time: Option<TimeOrNow>) -> Timespec {
    match time {
        None => Timespec { tv_sec: 0, tv_nsec: rustix::fs::UTIME_OMIT },
        Some(TimeOrNow::Now) => Timespec { tv_sec: 0, tv_nsec: rustix::fs::UTIME_NOW },
        Some(TimeOrNow::SpecificTime(time)) => {
            let since = time.duration_since(UNIX_EPOCH).unwrap_or_default();
            Timespec {
                tv_sec: i64::try_from(since.as_secs()).unwrap_or(i64::MAX),
                tv_nsec: since.subsec_nanos().into(),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;
    use crate::test_util::Temp;

    #[test]
    fn time_adds_nanos_on_either_side_of_the_epoch() {
        assert_eq!(time(5, 7), UNIX_EPOCH + Duration::new(5, 7));
        assert_eq!(time(0, 0), UNIX_EPOCH);
        // like `stat`, whose nanos always count forward
        assert_eq!(time(-1, 500_000_000), UNIX_EPOCH - Duration::from_millis(500));
        assert_eq!(time(-5, 7), UNIX_EPOCH - Duration::new(4, 999_999_993));
    }

    #[test]
    fn timespec_of_none_now_and_a_time() {
        let omit = timespec(None);
        assert_eq!((omit.tv_sec, omit.tv_nsec), (0, rustix::fs::UTIME_OMIT));
        let now = timespec(Some(TimeOrNow::Now));
        assert_eq!((now.tv_sec, now.tv_nsec), (0, rustix::fs::UTIME_NOW));
        let at = timespec(Some(TimeOrNow::SpecificTime(UNIX_EPOCH + Duration::new(1_700_000_000, 123))));
        assert_eq!((at.tv_sec, at.tv_nsec), (1_700_000_000, 123));
        // before the epoch, which it clamps to
        let before = timespec(Some(TimeOrNow::SpecificTime(UNIX_EPOCH - Duration::from_secs(1))));
        assert_eq!((before.tv_sec, before.tv_nsec), (0, 0));
    }

    #[test]
    fn kind_maps_each_type() {
        use rustix::fs::FileType as F;
        assert_eq!(kind(F::RegularFile), FileType::RegularFile);
        assert_eq!(kind(F::Directory), FileType::Directory);
        assert_eq!(kind(F::Symlink), FileType::Symlink);
        assert_eq!(kind(F::Fifo), FileType::NamedPipe);
        assert_eq!(kind(F::Socket), FileType::Socket);
        assert_eq!(kind(F::CharacterDevice), FileType::CharDevice);
        assert_eq!(kind(F::BlockDevice), FileType::BlockDevice);
        assert_eq!(kind(F::Unknown), FileType::RegularFile);
    }

    #[test]
    fn attr_of_a_file() {
        let temp = Temp::new("attr-file");
        temp.write("file", "hello");
        let file = temp.0.join("file");
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o4751)).unwrap();
        std::fs::hard_link(&file, temp.0.join("link")).unwrap();
        let attr = attr(INodeNo(42), &rustix::fs::stat(&file).unwrap());
        assert_eq!(attr.ino, INodeNo(42));
        assert_eq!(attr.size, 5);
        assert_eq!(attr.kind, FileType::RegularFile);
        assert_eq!(attr.perm, 0o4751);
        assert_eq!(attr.nlink, 2);
        assert_eq!(attr.mtime, std::fs::metadata(&file).unwrap().modified().unwrap());
        assert_eq!(attr.uid, rustix::process::getuid().as_raw());
    }

    #[test]
    fn attr_of_a_dir() {
        let temp = Temp::new("attr-dir");
        let dir = temp.0.join("dir");
        std::fs::create_dir(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o750)).unwrap();
        let attr = attr(INodeNo(7), &rustix::fs::stat(&dir).unwrap());
        assert_eq!(attr.kind, FileType::Directory);
        assert_eq!(attr.perm, 0o750);
        assert!(attr.nlink >= 1);
    }

    #[test]
    fn attr_of_a_symlink() {
        let temp = Temp::new("attr-symlink");
        let link = temp.0.join("link");
        std::os::unix::fs::symlink("some/target", &link).unwrap();
        let attr = attr(INodeNo(7), &rustix::fs::lstat(&link).unwrap());
        assert_eq!(attr.kind, FileType::Symlink);
        // its target's length
        assert_eq!(attr.size, 11);
        assert_eq!(attr.nlink, 1);
    }
}
