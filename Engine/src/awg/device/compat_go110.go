/* SPDX-License-Identifier: MIT
 *
 * compat_go110.go — Go 1.10 compatibility shim (Mavericks port).
 * Provides the error classification that upstream code does with
 * errors.Is(err, net.ErrClosed) / errors.Is(err, os.ErrClosed).
 */

package device

import (
	"os"
	"strings"
	"syscall"
)

// errnoIs reports whether err, unwrapped through the standard error wrappers,
// is the errno target. Backport of errors.Is for errno targets.
func errnoIs(err error, target syscall.Errno) bool {
	for err != nil {
		if e, ok := err.(syscall.Errno); ok {
			return e == target
		}
		switch t := err.(type) {
		case *os.PathError:
			err = t.Err
		case *os.SyscallError:
			err = t.Err
		default:
			return false
		}
	}
	return false
}

// errIsNetClosed reports whether err indicates that the underlying socket or
// file has been closed. Go 1.10 replacement for errors.Is(err, net.ErrClosed).
func errIsNetClosed(err error) bool {
	if err == nil {
		return false
	}
	if errnoIs(err, syscall.EBADF) {
		return true
	}
	s := err.Error()
	return strings.Contains(s, "use of closed network connection") ||
		strings.Contains(s, "file already closed") ||
		strings.Contains(s, "bind closed")
}

// errIsTemporary reports whether err is a transient "try again" condition
// rather than a real failure.
//
// A non-blocking descriptor that has nothing queued reports EAGAIN; a signal
// delivered mid-syscall reports EINTR. Neither means the tunnel is broken, and
// callers such as RoutineReadFromTUN must retry instead of tearing the device
// down. (Written with || rather than a switch because EAGAIN and EWOULDBLOCK
// are the same constant on darwin, which would make a duplicate case.)
func errIsTemporary(err error) bool {
	if err == nil {
		return false
	}
	return errnoIs(err, syscall.EAGAIN) ||
		errnoIs(err, syscall.EWOULDBLOCK) ||
		errnoIs(err, syscall.EINTR)
}

// errIsFileClosed reports whether err indicates that the underlying file has
// been closed. Go 1.10 replacement for errors.Is(err, os.ErrClosed).
func errIsFileClosed(err error) bool {
	if err == nil {
		return false
	}
	if perr, ok := err.(*os.PathError); ok {
		return perr.Err == os.ErrClosed
	}
	if err == os.ErrClosed {
		return true
	}
	return errnoIs(err, syscall.EBADF)
}
