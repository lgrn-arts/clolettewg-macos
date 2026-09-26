// SPDX-License-Identifier: MIT
//
// net_stub.go — no-op network configurator for non-darwin builds.
// (The daemon's service mode only runs on macOS; this stub exists so that
// -validate/-genkey builds work on any OS for testing.)
//
// +build !darwin

package main

type netConfigurator struct {
	iface string
	log   *ringLogger
}

func (n *netConfigurator) bringUp(conf *Conf) error { return nil }
func (n *netConfigurator) bringDown()               {}
