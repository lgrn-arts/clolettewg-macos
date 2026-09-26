/* SPDX-License-Identifier: MIT
 *
 * compat_go110.go — Go 1.10 compatibility shim (Mavericks port).
 */

package tun

import (
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
