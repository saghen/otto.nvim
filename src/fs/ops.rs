//! What the kernel asks of the filesystem

use std::ffi::OsStr;
use std::io;
use std::os::fd::AsFd;
use std::os::unix::fs::FileExt;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use fuser::{
    AccessFlags, Errno, FileHandle, Filesystem, FopenFlags, Generation, INodeNo, InitFlags, KernelConfig, LockOwner,
    OpenFlags, RenameFlags, ReplyAttr, ReplyCreate, ReplyData, ReplyDirectory, ReplyEmpty, ReplyEntry, ReplyOpen,
    ReplyStatfs, ReplyWrite, Request, TimeOrNow, WriteFlags,
};
use rustix::fs::{AtFlags, CWD, FlockOperation, Mode, OFlags, Timestamps};

use super::attr::{NOTHING, timespec};
use super::{Dir, Passthrough, reply_attr, reply_data, reply_empty, reply_entry};
use crate::{fd_path, lock};

impl Filesystem for Passthrough {
    fn init(&mut self, _req: &Request, config: &mut KernelConfig) -> io::Result<()> {
        // Not POSIX locks, which fuser doesn't tell from flock, so they stay local to the mount
        let wanted = InitFlags::FUSE_FLOCK_LOCKS
            | InitFlags::FUSE_ATOMIC_O_TRUNC
            | InitFlags::FUSE_AUTO_INVAL_DATA
            | InitFlags::FUSE_PARALLEL_DIROPS;
        let _ = config.add_capabilities(wanted & config.capabilities());
        Ok(())
    }

    fn lookup(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEntry) {
        match self.lookup_child(parent, name) {
            // which the kernel keeps too, like for each `.gitignore` that git looks for
            Err(err) if err.raw_os_error() == Some(rustix::io::Errno::NOENT.raw_os_error()) => {
                match lock(&self.nodes).cache_entry(parent, name) {
                    ttl if ttl.is_zero() => reply.error(Errno::ENOENT),
                    ttl => reply.entry_with_ttls(&Duration::ZERO, &ttl, &NOTHING, Generation(0)),
                }
            }
            result => reply_entry(reply, result),
        }
    }

    fn forget(&self, _req: &Request, id: INodeNo, nlookup: u64) {
        lock(&self.nodes).forget(id, nlookup);
    }

    fn getattr(&self, _req: &Request, id: INodeNo, _fh: Option<FileHandle>, reply: ReplyAttr) {
        reply_attr(reply, self.with_node(id, |fd| self.get_attr(id, fd)));
    }

    fn setattr(
        &self,
        req: &Request,
        id: INodeNo,
        mode: Option<u32>,
        uid: Option<u32>,
        gid: Option<u32>,
        size: Option<u64>,
        atime: Option<TimeOrNow>,
        mtime: Option<TimeOrNow>,
        _ctime: Option<SystemTime>,
        fh: Option<FileHandle>,
        _crtime: Option<SystemTime>,
        _chgtime: Option<SystemTime>,
        _bkuptime: Option<SystemTime>,
        _flags: Option<fuser::BsdFileFlags>,
        reply: ReplyAttr,
    ) {
        let result = self.with_node(id, |fd| {
            // through which an `O_PATH` fd's inode can be changed for real
            let path = fd_path(fd);
            if let Some(mode) = mode {
                rustix::fs::chmodat(CWD, &path, Mode::from_raw_mode(mode), AtFlags::empty())?;
            }
            if uid.is_some() || gid.is_some() {
                let (uid, gid) = (uid.map(rustix::fs::Uid::from_raw), gid.map(rustix::fs::Gid::from_raw));
                rustix::fs::chownat(CWD, &path, uid, gid, AtFlags::empty())?;
            }
            if let Some(size) = size {
                self.set_size(req.pid(), id, fd, fh, size)?;
            }
            if atime.is_some() || mtime.is_some() {
                let times = Timestamps { last_access: timespec(atime), last_modification: timespec(mtime) };
                rustix::fs::utimensat(CWD, &path, &times, AtFlags::empty())?;
            }
            self.get_attr(id, fd)
        });
        reply_attr(reply, result);
    }

    fn readlink(&self, _req: &Request, id: INodeNo, reply: ReplyData) {
        reply_data(reply, self.with_node(id, |fd| Ok(rustix::fs::readlinkat(fd, "", Vec::new())?.into_bytes())));
    }

    fn mknod(
        &self,
        _req: &Request,
        parent: INodeNo,
        name: &OsStr,
        mode: u32,
        _umask: u32,
        rdev: u32,
        reply: ReplyEntry,
    ) {
        let kind = rustix::fs::FileType::from_raw_mode(mode);
        reply_entry(
            reply,
            self.make(parent, name, |dir| rustix::fs::mknodat(dir, name, kind, Mode::from_raw_mode(mode), rdev.into())),
        );
    }

    fn mkdir(&self, _req: &Request, parent: INodeNo, name: &OsStr, mode: u32, _umask: u32, reply: ReplyEntry) {
        reply_entry(reply, self.make(parent, name, |dir| rustix::fs::mkdirat(dir, name, Mode::from_raw_mode(mode))));
    }

    fn unlink(&self, req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
        let result = self.with_node(parent, |dir| {
            let unlink = || Ok(rustix::fs::unlinkat(dir, name, AtFlags::empty())?);
            match self.recorded_name(dir, name) {
                Some(named) => self.remove_recorded(req.pid(), named, unlink),
                None => unlink(),
            }
        });
        reply_empty(reply, result);
    }

    fn rmdir(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEmpty) {
        reply_empty(reply, self.with_node(parent, |dir| Ok(rustix::fs::unlinkat(dir, name, AtFlags::REMOVEDIR)?)));
    }

    fn symlink(&self, _req: &Request, parent: INodeNo, name: &OsStr, target: &Path, reply: ReplyEntry) {
        reply_entry(reply, self.make(parent, name, |dir| rustix::fs::symlinkat(target, dir, name)));
    }

    fn rename(
        &self,
        req: &Request,
        parent: INodeNo,
        name: &OsStr,
        newparent: INodeNo,
        newname: &OsStr,
        flags: RenameFlags,
        reply: ReplyEmpty,
    ) {
        let flags = rustix::fs::RenameFlags::from_bits_retain(flags.bits());
        let result = self.with_node(parent, |from| {
            self.with_node(newparent, |to| self.rename_recording(req.pid(), from, name, to, newname, flags))
        });
        reply_empty(reply, result);
    }

    fn link(&self, req: &Request, id: INodeNo, newparent: INodeNo, newname: &OsStr, reply: ReplyEntry) {
        // Linking the fd itself (`AT_EMPTY_PATH`) needs a capability
        let result = self.with_node(id, |fd| {
            let found = self.make(newparent, newname, |dir| {
                rustix::fs::linkat(CWD, fd_path(fd), dir, newname, AtFlags::SYMLINK_FOLLOW)
            })?;
            // as written there
            if found.attr.kind == fuser::FileType::RegularFile
                && let Some(path) =
                    self.with_node(newparent, |dir| Ok(self.recorder.child_path(dir, newname, false)))?
            {
                self.recorder.locked(|log| log.write(&path, fd, &self.recorder.by(req.pid()), None));
            }
            Ok(found)
        });
        reply_entry(reply, result);
    }

    fn open(&self, req: &Request, id: INodeNo, flags: OpenFlags, reply: ReplyOpen) {
        if lock(&self.nodes).first_open_of_removed(id) {
            return reply.error(Errno::ESTALE);
        }
        let flags = OFlags::from_bits_retain(flags.0.cast_unsigned());
        let writes = flags.intersects(OFlags::WRONLY | OFlags::RDWR | OFlags::TRUNC);
        // Changes from outside since the log last saw it, before `O_TRUNC` loses them
        if writes {
            self.catch_up(self.with_node(id, |fd| Ok(self.node_to_catch_up(id, fd))).ok().flatten());
        }
        let change = flags.contains(OFlags::TRUNC).then(|| self.new_change(req.pid()));
        match self.reopen(id, flags) {
            Ok(fd) => reply.opened(self.add_file(fd, id, change), self.cache_flags(id)),
            Err(err) => reply.error(Errno::from(err)),
        }
    }

    fn create(
        &self,
        req: &Request,
        parent: INodeNo,
        name: &OsStr,
        mode: u32,
        _umask: u32,
        flags: i32,
        reply: ReplyCreate,
    ) {
        let flags = (OFlags::from_bits_retain(flags.cast_unsigned()) - (OFlags::NOFOLLOW | OFlags::DIRECT))
            | OFlags::CREATE
            | OFlags::CLOEXEC;
        let result = self.with_node(parent, |dir| {
            // Like the user's removing it, which a stale before would hide
            self.catch_up(self.name_to_catch_up(dir, name));
            let file = rustix::fs::openat(dir, name, flags, Mode::from_raw_mode(mode))?;
            // Of the inode we opened, whatever has the name by now
            let node = rustix::fs::open(fd_path(file.as_fd()), OFlags::PATH | OFlags::CLOEXEC, Mode::empty())?;
            Ok((file, self.add_lookup(parent, name, node)?))
        });
        match result {
            Ok((file, found)) => {
                let id = found.attr.ino;
                let fh = self.add_file(file, id, Some(self.new_change(req.pid())));
                let ttl = found.attr_ttl.min(found.entry_ttl);
                reply.created(&ttl, &found.attr, Generation(0), fh, self.cache_flags(id));
            }
            Err(err) => reply.error(Errno::from(err)),
        }
    }

    fn read(
        &self,
        _req: &Request,
        _id: INodeNo,
        fh: FileHandle,
        offset: u64,
        size: u32,
        _flags: OpenFlags,
        _lock_owner: Option<LockOwner>,
        reply: ReplyData,
    ) {
        let result = self.file(fh).and_then(|open| {
            let mut buf = vec![0; size as usize];
            let n = open.file.read_at(&mut buf, offset)?;
            buf.truncate(n);
            Ok(buf)
        });
        reply_data(reply, result);
    }

    fn write(
        &self,
        req: &Request,
        _id: INodeNo,
        fh: FileHandle,
        offset: u64,
        data: &[u8],
        _write_flags: WriteFlags,
        _flags: OpenFlags,
        _lock_owner: Option<LockOwner>,
        reply: ReplyWrite,
    ) {
        // With `O_APPEND`, Linux appends whatever the offset
        let result = self.file(fh).and_then(|open| {
            open.mark_written(|| self.new_change(req.pid()));
            open.file.write_at(data, offset)
        });
        match result {
            // at most the request's size, which is a u32
            Ok(n) => reply.written(u32::try_from(n).unwrap_or(u32::MAX)),
            Err(err) => reply.error(Errno::from(err)),
        }
    }

    /// On each `close()`, which waits for it, unlike for `release`
    fn flush(&self, _req: &Request, _id: INodeNo, fh: FileHandle, _lock_owner: LockOwner, reply: ReplyEmpty) {
        if let Ok(open) = self.file(fh) {
            self.record(&open, false);
        }
        reply.ok();
    }

    fn release(
        &self,
        _req: &Request,
        _id: INodeNo,
        fh: FileHandle,
        _flags: OpenFlags,
        _lock_owner: Option<LockOwner>,
        _flush: bool,
        reply: ReplyEmpty,
    ) {
        // What the last `close()` left, like writes through `mmap`, before `settle` stops waiting for it
        if let Ok(open) = self.file(fh) {
            self.record(&open, true);
        }
        self.files.remove(fh);
        reply.ok();
    }

    fn fsync(&self, _req: &Request, _id: INodeNo, fh: FileHandle, datasync: bool, reply: ReplyEmpty) {
        let result = self.file(fh).and_then(|open| if datasync { open.file.sync_data() } else { open.file.sync_all() });
        reply_empty(reply, result);
    }

    fn opendir(&self, _req: &Request, id: INodeNo, _flags: OpenFlags, reply: ReplyOpen) {
        match self.reopen(id, OFlags::RDONLY | OFlags::DIRECTORY) {
            Ok(fd) => {
                let fh = self.next_handle();
                lock(&self.dirs).insert(fh, Arc::new(Dir { fd, listing: Mutex::default() }));
                let flags = self.cache_flags(id);
                reply.opened(fh, if flags.is_empty() { flags } else { flags | FopenFlags::FOPEN_CACHE_DIR });
            }
            Err(err) => reply.error(Errno::from(err)),
        }
    }

    fn readdir(&self, _req: &Request, _id: INodeNo, fh: FileHandle, offset: u64, mut reply: ReplyDirectory) {
        let dir = match self.dir(fh) {
            Ok(dir) => dir,
            Err(err) => return reply.error(Errno::from(err)),
        };
        let mut listing = lock(&dir.listing);
        // From the start, like after `rewinddir`, reads it anew
        if offset == 0 {
            match Self::read_dir(&dir.fd) {
                Ok(read) => *listing = read,
                Err(err) => return reply.error(Errno::from(err)),
            }
        }
        for (i, (ino, kind, name)) in listing.iter().enumerate().skip(usize::try_from(offset).unwrap_or(usize::MAX)) {
            if reply.add(INodeNo(*ino), i as u64 + 1, *kind, name) {
                break;
            }
        }
        reply.ok();
    }

    fn releasedir(&self, _req: &Request, _id: INodeNo, fh: FileHandle, _flags: OpenFlags, reply: ReplyEmpty) {
        lock(&self.dirs).remove(&fh);
        reply.ok();
    }

    fn fsyncdir(&self, _req: &Request, _id: INodeNo, fh: FileHandle, _datasync: bool, reply: ReplyEmpty) {
        reply_empty(reply, self.dir(fh).and_then(|dir| Ok(rustix::fs::fsync(&dir.fd)?)));
    }

    fn statfs(&self, _req: &Request, id: INodeNo, reply: ReplyStatfs) {
        match self.with_node(id, |fd| Ok(rustix::fs::fstatvfs(fd)?)) {
            Ok(st) => reply.statfs(
                st.f_blocks,
                st.f_bfree,
                st.f_bavail,
                st.f_files,
                st.f_ffree,
                u32::try_from(st.f_bsize).unwrap_or(u32::MAX),
                u32::try_from(st.f_namemax).unwrap_or(u32::MAX),
                u32::try_from(st.f_frsize).unwrap_or(u32::MAX),
            ),
            Err(err) => reply.error(Errno::from(err)),
        }
    }

    fn access(&self, _req: &Request, id: INodeNo, mask: AccessFlags, reply: ReplyEmpty) {
        let access = rustix::fs::Access::from_bits_retain(mask.bits().cast_unsigned());
        let result = self.with_node(id, |fd| Ok(rustix::fs::accessat(CWD, fd_path(fd), access, AtFlags::empty())?));
        reply_empty(reply, result);
    }

    /// Only `flock`s reach us, which go to the real file so they hold across mounts
    fn setlk(
        &self,
        _req: &Request,
        _id: INodeNo,
        fh: FileHandle,
        _lock_owner: LockOwner,
        _start: u64,
        _end: u64,
        typ: i32,
        _pid: u32,
        sleep: bool,
        reply: ReplyEmpty,
    ) {
        let open = match self.file(fh) {
            Ok(open) => open,
            Err(err) => return reply.error(Errno::from(err)),
        };
        let op = flock_op(typ, sleep);
        let lock = move || reply_empty(reply, rustix::fs::flock(&open.file, op).map_err(io::Error::from));
        // Waiting on one would hold a thread that other requests need
        if sleep { drop(std::thread::spawn(lock)) } else { lock() }
    }

    fn fallocate(
        &self,
        req: &Request,
        _id: INodeNo,
        fh: FileHandle,
        offset: u64,
        length: u64,
        mode: i32,
        reply: ReplyEmpty,
    ) {
        let mode = rustix::fs::FallocateFlags::from_bits_retain(mode.cast_unsigned());
        let result = self.file(fh).and_then(|open| {
            open.mark_written(|| self.new_change(req.pid()));
            Ok(rustix::fs::fallocate(&open.file, mode, offset, length)?)
        });
        reply_empty(reply, result);
    }
}

/// The `flock` that a lock request of `typ` asks for, waiting for it when `sleep`
fn flock_op(typ: i32, sleep: bool) -> FlockOperation {
    match (typ, sleep) {
        (libc::F_RDLCK, true) => FlockOperation::LockShared,
        (libc::F_RDLCK, false) => FlockOperation::NonBlockingLockShared,
        (libc::F_WRLCK, true) => FlockOperation::LockExclusive,
        (libc::F_WRLCK, false) => FlockOperation::NonBlockingLockExclusive,
        _ => FlockOperation::Unlock,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flock_op_of_each_lock() {
        assert_eq!(flock_op(libc::F_RDLCK, true), FlockOperation::LockShared);
        assert_eq!(flock_op(libc::F_RDLCK, false), FlockOperation::NonBlockingLockShared);
        assert_eq!(flock_op(libc::F_WRLCK, true), FlockOperation::LockExclusive);
        assert_eq!(flock_op(libc::F_WRLCK, false), FlockOperation::NonBlockingLockExclusive);
        assert_eq!(flock_op(libc::F_UNLCK, false), FlockOperation::Unlock);
    }
}
