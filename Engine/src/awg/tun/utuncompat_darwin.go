/* SPDX-License-Identifier: MIT
 *
 * utuncompat_darwin.go — Mavericks port (Go 1.10) support code.
 *
 * The June-2019 x/sys/unix (the newest version whose darwin port still uses
 * plain syscalls and therefore builds with Go 1.10) predates the addition of
 * unix.CtlInfo, unix.SockaddrCtl and the IfreqMTU ioctl helpers, so the
 * utun control-socket dance is done here with raw syscalls instead.
 */

package tun

import (
	"fmt"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	// sys/kern_control.h
	maxKctlName    = 96
	ctlIOCGINFO    = 0xc0644e03 // _IOWR('N', 3, struct ctl_info)
	afSysControl   = 2          // AF_SYS_CONTROL
	sysprotoCtrl   = 2          // SYSPROTO_CONTROL
	utunOptIfName  = 2          // UTUN_OPT_IFNAME
)

type ctlInfoStruct struct {
	ID   uint32
	Name [maxKctlName]byte
}

type sockaddrCtl struct {
	Len       uint8
	Family    uint8
	Sysaddr   uint16
	ID        uint32
	Unit      uint32
	Reserved  [5]uint32
}

// ioctlCtlInfo resolves the control id of the utun kernel control.
func ioctlCtlInfo(fd int, name string) (uint32, error) {
	var info ctlInfoStruct
	copy(info.Name[:], name)
	_, _, errno := unix.Syscall(
		unix.SYS_IOCTL,
		uintptr(fd),
		uintptr(ctlIOCGINFO),
		uintptr(unsafe.Pointer(&info)),
	)
	if errno != 0 {
		return 0, errno
	}
	return info.ID, nil
}

// connectCtl connects fd (an AF_SYSTEM/SYSPROTO_CONTROL socket) to the
// control identified by id, requesting unit (0 = kernel picks utunN).
func connectCtl(fd int, id, unit uint32) error {
	sc := sockaddrCtl{
		Len:     uint8(unsafe.Sizeof(sockaddrCtl{})),
		Family:  unix.AF_SYSTEM,
		Sysaddr: afSysControl,
		ID:      id,
		Unit:    unit,
	}
	_, _, errno := unix.Syscall(
		unix.SYS_CONNECT,
		uintptr(fd),
		uintptr(unsafe.Pointer(&sc)),
		unsafe.Sizeof(sc),
	)
	if errno != 0 {
		return errno
	}
	return nil
}

type ifreqMTU struct {
	Name [unix.IFNAMSIZ]byte
	MTU  int32
}

func ioctlSetIfreqMTU(fd int, ifname string, mtu int32) error {
	var ifr ifreqMTU
	copy(ifr.Name[:], ifname)
	ifr.MTU = mtu
	_, _, errno := unix.Syscall(
		unix.SYS_IOCTL,
		uintptr(fd),
		uintptr(unix.SIOCSIFMTU),
		uintptr(unsafe.Pointer(&ifr)),
	)
	if errno != 0 {
		return fmt.Errorf("SIOCSIFMTU: %v", errno)
	}
	return nil
}

func ioctlGetIfreqMTU(fd int, ifname string) (int32, error) {
	var ifr ifreqMTU
	copy(ifr.Name[:], ifname)
	_, _, errno := unix.Syscall(
		unix.SYS_IOCTL,
		uintptr(fd),
		uintptr(unix.SIOCGIFMTU),
		uintptr(unsafe.Pointer(&ifr)),
	)
	if errno != 0 {
		return 0, fmt.Errorf("SIOCGIFMTU: %v", errno)
	}
	return ifr.MTU, nil
}
