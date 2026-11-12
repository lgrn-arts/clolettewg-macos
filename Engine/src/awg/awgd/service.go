/* SPDX-License-Identifier: MIT
 *
 * service.go — privileged awgd service (launchd / root mode).
 *
 * Listens on a local UNIX socket and speaks newline-delimited JSON.
 * The socket and the shared token file are root:admin 0660/0640, so only
 * admin users on this Mac can talk to the daemon.
 *
 * Requests:  {"cmd":"up","name":"Home","conf":"[Interface]..."}
 *            {"cmd":"down"}  {"cmd":"status"}  {"cmd":"log","n":100}
 *            {"cmd":"stop"}  {"cmd":"ping"}
 * Responses: {"ok":true,"data":{...}} | {"ok":false,"error":"..."}
 */

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"awg/device"
	"awg/tun"
)

const (
	socketPath = "/var/run/clolette-wg.sock"
	stateDir   = "/Library/Application Support/CloletteWG"
	tokenPath  = stateDir + "/token"
	serviceLog = stateDir + "/clolettewgd.log"
)

type tunnelState struct {
	mu      sync.Mutex
	log     *ringLogger
	name    string
	dev     *device.Device
	iface   string
	nc      *netConfigurator
	started time.Time
	// stop closes when this tunnel is torn down; it cancels the handshake
	// watchdog (and any other per-tunnel goroutine).
	stop chan struct{}
}

type Server struct {
	tun   tunnelState
	log   *ringLogger
	token string
}

func newServer(log *ringLogger) *Server {
	s := &Server{log: log, tun: tunnelState{log: log}}
	data, err := readFirstLine(tokenPath)
	if err == nil && len(data) >= 32 {
		s.token = data
	}
	return s
}

// ensureToken generates the shared secret once (root-owned, admin group read).
func ensureToken() (string, error) {
	if err := os.MkdirAll(stateDir, 0750); err != nil {
		return "", err
	}
	if t, err := readFirstLine(tokenPath); err == nil && len(t) >= 32 {
		return t, nil
	}
	tok, err := randomToken()
	if err != nil {
		return "", err
	}
	if err := writeFilePrivate(tokenPath, tok+"\n", 0640); err != nil {
		return "", err
	}
	// group admin on stock macOS is gid 80
	runCmd("/usr/sbin/chown", "root:admin", tokenPath)
	return tok, nil
}

func (s *Server) Serve(ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Temporary() {
				time.Sleep(100 * time.Millisecond)
				continue
			}
			return
		}
		go s.handleConn(conn)
	}
}

type request struct {
	Cmd   string          `json:"cmd"`
	Name  string          `json:"name,omitempty"`  // tunnel name (up), tunnel id, etc.
	Token string          `json:"token,omitempty"` // shared secret — required on every request
	Conf  string          `json:"conf,omitempty"`
	N     int             `json:"n,omitempty"`
	Next  json.RawMessage `json:"-"`
}

type reply struct {
	OK    bool        `json:"ok"`
	Error string      `json:"error,omitempty"`
	Data  interface{} `json:"data,omitempty"`
}

func sendReply(c net.Conn, r reply) {
	buf, _ := json.Marshal(r)
	c.Write(append(buf, '\n'))
}

func (s *Server) handleConn(c net.Conn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(30 * time.Second))

	// Auth protocol: every request — including the very first one — must
	// carry `name=<token>`. The server checks the token on each command;
	// there is no separate "auth" handshake. (Earlier versions of this code
	// required the first message to be `cmd="auth"`, but the IPCClient
	// never sent one before its actual command, leading to every "up"
	// failing with "authentication failed".)
	dec := json.NewDecoder(bufio.NewReader(c))
	c.SetDeadline(time.Time{})
	for {
		var req request
		if err := dec.Decode(&req); err != nil {
			return
		}
		if !secureEqual(req.Token, s.token) {
			s.log.Warnf("IPC auth failed: cmd=%q token-len=%d expected-len=%d",
				req.Cmd, len(req.Token), len(s.token))
			sendReply(c, reply{OK: false, Error: "authentication failed"})
			continue
		}
		switch req.Cmd {
		case "auth":
			// explicit auth: just confirms the token is good and
			// returns the service banner. Useful as a liveness probe.
			sendReply(c, reply{OK: true, Data: map[string]string{"service": versionString}})
		case "ping":
			sendReply(c, reply{OK: true, Data: map[string]string{"pong": "awgd"}})
		case "up":
			s.log.Infof("IPC: up %q requested", req.Name)
			if err := s.up(req.Name, req.Conf); err != nil {
				s.log.Errorf("IPC: up %q failed: %v", req.Name, err)
				sendReply(c, reply{OK: false, Error: err.Error()})
			} else {
				s.log.Infof("IPC: up %q succeeded", req.Name)
				sendReply(c, reply{OK: true, Data: s.statusLocked()})
			}
		case "down":
			err := s.down()
			if err != nil {
				sendReply(c, reply{OK: false, Error: err.Error()})
			} else {
				sendReply(c, reply{OK: true})
			}
		case "status":
			sendReply(c, reply{OK: true, Data: s.status()})
		case "log":
			n := req.N
			if n <= 0 || n > 1000 {
				n = 200
			}
			sendReply(c, reply{OK: true, Data: map[string]interface{}{"lines": s.log.tail(n)}})
		case "stop":
			sendReply(c, reply{OK: true})
			go func() {
				time.Sleep(200 * time.Millisecond)
				s.down()
				os.Exit(0)
			}()
			return
		default:
			sendReply(c, reply{OK: false, Error: "unknown command: " + req.Cmd})
		}
	}
}

func secureEqual(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	var v byte
	for i := 0; i < len(a); i++ {
		v |= a[i] ^ b[i]
	}
	return v == 0
}

// up brings the named tunnel up, replacing any active one.
func (s *Server) up(name, confText string) error {
	s.tun.mu.Lock()
	defer s.tun.mu.Unlock()

	if err := downLocked(&s.tun); err != nil {
		s.log.Errorf("replacing previous tunnel: %v", err)
	}

	conf, err := ParseConf(confText)
	if err != nil {
		return fmt.Errorf("config: %v", err)
	}

	// If the endpoint is a hostname (rather than a literal IP) we resolve
	// it here, then substitute the resolved IP back into the config.
	//
	// wireguard-go's UAPI path explicitly refuses non-literal hosts in
	// `endpoint=`. Some AmneziaWG servers hand out a hostname regardless
	// of what `wg-quick` would have done, and we have to fill the gap.
	// Resolving up front also surfaces a clean error to the user — "DNS
	// lookup failed for X" — instead of the cryptic "IPC error -22:
	// failed to set endpoint ... Failed to parse IP address" that the
	// device returns when handed a hostname.
	if conf.Endpoint != "" {
		if host, port, err := net.SplitHostPort(conf.Endpoint); err == nil {
			if net.ParseIP(host) == nil {
				ip, rerr := resolveEndpoint(host, 3 /*attempts*/)
				if rerr != nil {
					return fmt.Errorf("endpoint %q: DNS lookup failed: %v", conf.Endpoint, rerr)
				}
				s.log.Infof("resolved endpoint %s -> %s", host, ip)
				conf.Endpoint = net.JoinHostPort(ip, port)
			}
		} else {
			// bad host:port shape (we already validated on parse; should be unreachable)
			s.log.Warnf("endpoint %q not in host:port form", conf.Endpoint)
		}
	}

	tdev, err := tun.CreateTUN("utun", conf.MTU)
	if err != nil {
		return fmt.Errorf("create utun: %v", err)
	}
	iface, err := tdev.Name()
	if err != nil {
		tdev.Close()
		return fmt.Errorf("utun name: %v", err)
	}

	nc := &netConfigurator{iface: iface, log: s.log}
	if err := nc.bringUp(conf); err != nil {
		// bringUp may have installed some routes before it failed. Leaving
		// them behind is what turns one bad connect into a poisoned routing
		// table: a stale 0/1 + 128/1 pair pointing at a dead utun black-holes
		// the next attempt too. Always undo whatever we managed to do.
		nc.bringDown()
		tdev.Close()
		return fmt.Errorf("network config: %v", err)
	}

	logger := s.log.deviceLogger()
	dev := device.NewDevice(tdev, connNewBind(), logger)
	if err := dev.IpcSet(conf.IpcSetString()); err != nil {
		nc.bringDown()
		dev.Close()
		return fmt.Errorf("apply config: %v", err)
	}
	if err := dev.Up(); err != nil {
		nc.bringDown()
		dev.Close()
		return fmt.Errorf("device up: %v", err)
	}

	s.tun.name = name
	s.tun.dev = dev
	s.tun.iface = iface
	s.tun.nc = nc
	s.tun.started = time.Now()
	s.tun.stop = make(chan struct{})

	// The device gives up permanently once MaxHandshakeAttempts is exhausted
	// (it deletes its keepalive timer and flushes staged packets). On a flaky
	// link that leaves the tunnel "up" but dead until the user reconnects by
	// hand. The watchdog keeps retrying so recovery is automatic.
	peerHex, hexErr := b64ToHex(conf.PublicKey)
	if hexErr == nil && peerHex != "" {
		go s.handshakeWatchdog(s.tun.stop, dev, peerHex, conf.PersistentKeepalive)
	}

	s.log.Infof("tunnel %q up on %s", name, iface)
	return nil
}

// handshakeWatchdog keeps nudging the peer while the tunnel is up but has
// never completed a handshake. It stops as soon as a handshake succeeds, or
// when stop is closed by downLocked.
//
// The nudge re-issues `persistent_keepalive_interval` on the peer. UAPI sends
// an immediate keepalive when the value goes 0 -> non-zero, and with no
// keypair that turns into a fresh handshake initiation.
func (s *Server) handshakeWatchdog(stop <-chan struct{}, dev *device.Device, peerHex string, keepalive string) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	warned := false
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
		}

		s.tun.mu.Lock()
		if s.tun.dev == nil || s.tun.dev != dev {
			s.tun.mu.Unlock()
			return
		}
		st := s.statusLocked()
		s.tun.mu.Unlock()

		if st.Handshake > 0 {
			if warned {
				s.log.Infof("handshake completed with peer %s", st.Endpoint)
			}
			return
		}

		if !warned {
			s.log.Warnf("tunnel is up but no handshake yet — the peer has not answered; "+
				"keeping the handshake alive (check that UDP %s is reachable)", st.Endpoint)
			warned = true
		}

		if keepalive == "" || keepalive == "0" || keepalive == "0-0" {
			continue
		}

		// re-check stop right before touching the device
		select {
		case <-stop:
			return
		default:
		}

		sel := "public_key=" + peerHex + "\n"
		dev.IpcSet(sel + "persistent_keepalive_interval=0\n")
		dev.IpcSet(sel + "persistent_keepalive_interval=" + keepalive + "\n")
	}
}

// down tears the tunnel down; safe when nothing is up.
func (s *Server) down() error {
	s.tun.mu.Lock()
	defer s.tun.mu.Unlock()
	return downLocked(&s.tun)
}

func downLocked(t *tunnelState) error {
	if t.dev == nil {
		return nil
	}
	// stop per-tunnel goroutines before the device disappears
	if t.stop != nil {
		close(t.stop)
		t.stop = nil
	}
	t.dev.Down()
	t.dev.Close()
	if t.nc != nil {
		t.nc.bringDown()
	}
	t.log.Infof("tunnel %q down (was on %s)", t.name, t.iface)
	t.dev = nil
	t.name = ""
	t.iface = ""
	t.nc = nil
	return nil
}

type statusInfo struct {
	Name       string `json:"name,omitempty"`
	State      string `json:"state"`
	Iface      string `json:"iface,omitempty"`
	ListenPort int    `json:"listen_port,omitempty"`
	Handshake  int64  `json:"last_handshake,omitempty"`
	TxBytes    int64  `json:"tx_bytes,omitempty"`
	RxBytes    int64  `json:"rx_bytes,omitempty"`
	Endpoint   string `json:"endpoint,omitempty"`
	Started    string `json:"started,omitempty"`
	AWGEnabled bool   `json:"obfuscation_enabled,omitempty"`
}

func (s *Server) status() *statusInfo {
	s.tun.mu.Lock()
	defer s.tun.mu.Unlock()
	return s.statusLocked()
}

func (s *Server) statusLocked() *statusInfo {
	st := &statusInfo{State: "disconnected"}
	if s.tun.dev == nil {
		return st
	}
	st.State = "connected"
	st.Name = s.tun.name
	st.Iface = s.tun.iface
	st.Started = s.tun.started.Format(time.RFC3339)
	out, err := s.tun.dev.IpcGet()
	if err != nil {
		return st
	}
	for _, ln := range strings.Split(out, "\n") {
		kv := strings.SplitN(ln, "=", 2)
		if len(kv) != 2 {
			continue
		}
		switch kv[0] {
		case "listen_port":
			st.ListenPort, _ = strconv.Atoi(kv[1])
		case "last_handshake_time_sec":
			v, _ := strconv.ParseInt(kv[1], 10, 64)
			if v > 0 {
				st.Handshake = v
			}
		case "tx_bytes":
			st.TxBytes, _ = strconv.ParseInt(kv[1], 10, 64)
		case "rx_bytes":
			st.RxBytes, _ = strconv.ParseInt(kv[1], 10, 64)
		case "endpoint":
			st.Endpoint = kv[1]
		case "jc":
			if kv[1] != "0" {
				st.AWGEnabled = true
			}
		}
	}
	if st.Handshake == 0 {
		st.State = "connecting"
	}
	return st
}

// helpers ------------------------------------------------------------

func readFirstLine(path string) (string, error) {
	data, err := readFileLimited(path, 4096)
	if err != nil {
		return "", err
	}
	line := strings.TrimSpace(strings.SplitN(string(data), "\n", 2)[0])
	if line == "" {
		return "", fmt.Errorf("empty file")
	}
	return line, nil
}

func writeFilePrivate(path, data string, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0750); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	_, err = f.WriteString(data)
	f.Close()
	return err
}

// resolveEndpoint turns a hostname into a single literal IP suitable for
// use as the wireguard endpoint. It prefers IPv4 (because that is what
// most AWG servers actually run on) but falls back to IPv6. We retry
// briefly because users sometimes click "Connect" while DNS is still
// coming up after waking their Mac from sleep.
func resolveEndpoint(host string, attempts int) (string, error) {
	if net.ParseIP(host) != nil {
		// already an IP — caller should have caught this but be defensive
		return host, nil
	}
	var lastErr error
	for i := 0; i < attempts; i++ {
		if i > 0 {
			time.Sleep(500 * time.Millisecond)
		}
		ips, err := net.LookupIP(host)
		if err != nil {
			lastErr = err
			continue
		}
		for _, ip := range ips {
			if v4 := ip.To4(); v4 != nil {
				return v4.String(), nil
			}
		}
		if len(ips) > 0 {
			return ips[0].String(), nil
		}
		lastErr = fmt.Errorf("no addresses returned for %s", host)
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("DNS lookup for %s returned no addresses", host)
	}
	return "", lastErr
}
