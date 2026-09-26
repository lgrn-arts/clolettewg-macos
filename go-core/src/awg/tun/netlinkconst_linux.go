//go:build linux

// +build linux

/* SPDX-License-Identifier: MIT
 *
 * netlinkconst_linux.go — Mavericks port: rtnetlink group constants missing
 * from the June-2019 x/sys/unix snapshot used for Go 1.10 compatibility.
 */

package tun

const (
	rtmgrpLink       = 0x001
	rtmgrpIPv4Ifaddr = 0x010
	rtmgrpIPv6Ifaddr = 0x100
)
