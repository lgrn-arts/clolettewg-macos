//go:build darwin || freebsd

// +build darwin freebsd

/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2017-2021 WireGuard LLC. All Rights Reserved.
 */

package tun

func (tun *NativeTun) operateOnFd(fn func(fd uintptr)) {
	// Mavericks port: os.File.SyscallConn requires Go 1.11. Fd() is equivalent
	// for the raw ioctl/sockopt uses in this package.
	//
	// Note: the old comment here claimed Fd() "marks the fd blocking for the
	// runtime poller". It does not -- Fd() only reverts to blocking if Go
	// itself put the descriptor into non-blocking mode, which never happens
	// for a file built by os.NewFile (kindNewFile is not pollable). The utun
	// fd is therefore left exactly as CreateTUN made it, which is why
	// CreateTUN must NOT set it non-blocking; see the comment there.
	fn(tun.tunFile.Fd())
}
