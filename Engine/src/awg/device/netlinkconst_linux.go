//go:build linux

// +build linux

/* SPDX-License-Identifier: MIT
 *
 * netlinkconst_linux.go — Mavericks port: rtnetlink group constant missing
 * from the June-2019 x/sys/unix snapshot. (Linux-only file; the darwin build
 * never compiles this.)
 */

package device

const rtmgrpIPv4Route = 0x040
