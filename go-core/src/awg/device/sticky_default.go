//go:build !linux

// +build !linux

package device

import (
	"awg/conn"
	"awg/rwcancel"
)

func (device *Device) startRouteListener(bind conn.Bind) (*rwcancel.RWCancel, error) {
	return nil, nil
}
