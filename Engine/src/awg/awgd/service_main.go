/* SPDX-License-Identifier: MIT
 *
 * service_main.go — runService: socket lifecycle for the root daemon.
 */

package main

import (
	"fmt"
	"net"
	"os"
	"os/signal"
	"os/user"
	"syscall"
)

func runService() {
	ring := newRingLogger(2000)
	ring.Infof("awgd service starting (%s)", versionString)

	tok, err := ensureToken()
	if err != nil {
		fmt.Fprintf(os.Stderr, "awgd: token setup failed: %v\n", err)
		os.Exit(1)
	}

	if err := os.Remove(socketPath); err != nil && !os.IsNotExist(err) {
		fmt.Fprintf(os.Stderr, "awgd: stale socket: %v\n", err)
	}
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "awgd: listen %s: %v\n", socketPath, err)
		os.Exit(1)
	}
	if err := os.Chmod(socketPath, 0660); err != nil {
		fmt.Fprintf(os.Stderr, "awgd: chmod socket: %v\n", err)
	}
	if gid := adminGID(); gid >= 0 {
		os.Chown(socketPath, 0, gid)
		os.Chown(tokenPath, 0, gid)
	}

	srv := newServer(ring)
	srv.token = tok

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		ring.Infof("SIGTERM: shutting down tunnel")
		srv.down()
		ln.Close()
		os.Remove(socketPath)
		os.Exit(0)
	}()

	ring.Infof("listening on %s", socketPath)
	srv.Serve(ln)
}

// adminGID returns the gid of the "admin" group (80 on stock macOS).
func adminGID() int {
	g, err := user.LookupGroup("admin")
	if err != nil {
		return -1
	}
	var gid int
	for i := 0; i < len(g.Gid); i++ {
		c := g.Gid[i]
		if c < '0' || c > '9' {
			return -1
		}
		gid = gid*10 + int(c-'0')
	}
	return gid
}
