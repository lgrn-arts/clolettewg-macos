/* SPDX-License-Identifier: MIT
 *
 * compat_go110.go — Go 1.10 compatibility shim (Mavericks port).
 * Replaces errors.Is-style checks that require Go 1.13+.
 */

package conn

import (
	"errors"
	"net"
	"os"
	"syscall"
)

// errnoIs reports whether err, unwrapped through the standard error wrappers,
// is the errno target. Backport of errors.Is for the cases used in this package.
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
		case *net.OpError:
			err = t.Err
		default:
			return false
		}
	}
	return false
}

// errBindClosed is returned by receive functions after Close. Go 1.10 has no
// net.ErrClosed (added in Go 1.16); the message matches what the net package
// produces so that device-side classification also works.
var errBindClosed = errors.New("use of closed network connection")
