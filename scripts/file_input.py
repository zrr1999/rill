"""Bounded reads from one regular-file descriptor for development scripts."""

import os
from pathlib import Path
import stat


def read_regular_file(
    path: Path, *, max_bytes: int, follow_symlinks: bool
) -> bytes:
    # Do not wait for a FIFO writer before rejecting non-regular files.
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK
    if not follow_symlinks:
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f"File must be a regular file: {path}")
        if before.st_size > max_bytes:
            raise ValueError(f"File exceeds the {max_bytes}-byte limit: {path}")
        data = source.read(max_bytes + 1)
        after = os.fstat(source.fileno())
    if len(data) > max_bytes:
        raise ValueError(f"File exceeds the {max_bytes}-byte limit: {path}")
    before_identity = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
    )
    after_identity = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    )
    if len(data) != before.st_size or before_identity != after_identity:
        raise ValueError(f"File changed while it was being read: {path}")
    return data
