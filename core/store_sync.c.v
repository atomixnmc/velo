module core

import os

// Durable file replacement for Store.save.

#include <stdio.h>

$if windows {
	#include <io.h>
}

fn C._commit(fd int) int
fn C.fsync(fd int) int
fn C.MoveFileExW(existing &u16, new &u16, flags u32) int

// sync_fd flushes a file's data to the disk.
fn sync_fd(fd int) {
	$if windows {
		C._commit(fd)
	} $else {
		C.fsync(fd)
	}
}

// replace_file moves `src` over `dst` in one step (dst may exist): readers see the old or the new file.
fn replace_file(src string, dst string) ! {
	$if windows {
		// MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH: unlike rename / os.mv, it replaces an existing
		// file without deleting it first
		if C.MoveFileExW(src.to_wide(), dst.to_wide(), u32(0x1 | 0x8)) == 0 {
			return error('cannot replace ${dst} (MoveFileEx failed)')
		}
	} $else {
		os.rename(src, dst)! // POSIX rename replaces atomically
	}
}
