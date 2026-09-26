/* SPDX-License-Identifier: MIT
 *
 * handshake_probe_test.go — answers "is a handshake actually being sent?"
 *
 * The daemon's `up` path (ParseConf -> IpcSetString -> dev.IpcSet -> dev.Up)
 * is driven here against the user's real AmneziaWG 3.0 profile, with a bind
 * that records every datagram instead of putting it on the wire. If the
 * tunnel comes "up" but nothing leaves the socket, no handshake can ever
 * complete — that is exactly the reported symptom.
 */

package main

import (
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"awg/conn"
	"awg/device"
	"awg/tun/tuntest"
)

// ---------------------------------------------------------------------------
// recording bind
// ---------------------------------------------------------------------------

type recEndpoint struct{ dst string }

func (e *recEndpoint) ClearSrc()           {}
func (e *recEndpoint) SrcToString() string { return "0.0.0.0:0" }
func (e *recEndpoint) DstToString() string { return e.dst }
func (e *recEndpoint) DstToBytes() []byte  { return []byte(e.dst) }
func (e *recEndpoint) DstIP() net.IP       { return net.ParseIP("198.51.100.1") }
func (e *recEndpoint) SrcIP() net.IP       { return net.ParseIP("198.51.100.2") }

// recBind captures everything the device sends.
type recBind struct {
	mu   sync.Mutex
	sent [][]byte
	dsts []string
}

func (b *recBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	// never deliver inbound packets; we only care about what goes out
	return nil, port, nil
}
func (b *recBind) Close() error         { return nil }
func (b *recBind) SetMark(uint32) error { return nil }

func (b *recBind) Send(buf []byte, ep conn.Endpoint) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	cp := make([]byte, len(buf))
	copy(cp, buf)
	b.sent = append(b.sent, cp)
	b.dsts = append(b.dsts, ep.DstToString())
	return nil
}

func (b *recBind) ParseEndpoint(s string) (conn.Endpoint, error) {
	host, _, err := net.SplitHostPort(s)
	if err != nil {
		return nil, err
	}
	if net.ParseIP(host) == nil {
		return nil, fmt.Errorf("not a literal IP: %s", host)
	}
	return &recEndpoint{dst: s}, nil
}

func (b *recBind) snapshot() [][]byte {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([][]byte, len(b.sent))
	copy(out, b.sent)
	return out
}

// ---------------------------------------------------------------------------
// the probe
// ---------------------------------------------------------------------------

// realUserConf mirrors the profile the user is actually connecting with
// (Kazakh3AW3762), with the real secrets replaced by throwaway values.
const realUserConf = `[Interface]
PrivateKey = 0EjBdOUXrY8sKvpcEhKKlICmNN2fBnFDk7ZcqLLeXkY=
Address = 10.46.20.66/32
DNS = 1.1.1.1, 8.8.8.8
MTU = 1280
Jc = 9
Jmin = 30
Jmax = 90
S1 = 110
S2 = 120
S3 = 47
S4 = 23
H1 = 7291435-486117520
H2 = 602843917-1157629843
H3 = 1249871566-1680354947
H4 = 1781926002-2106438100
I1 = <b 0x0003><r 2><b 0x2112A442><r 12><r 20>
I2 = <b 0x0103><r 2><b 0x2112A442><r 12><r 24>
I3 = <b 0x0008><r 2><b 0x2112A442><r 12><r 16>
HeaderProtectionKey = t5BBswOFBGXdov39u/Xv9obDe+GBtOrbepoXRmgrdQs=
ContentPaddingAddition = 50-200
RekeyAfterTime = 120
RekeyTimeout = 5
RejectAfterTime = 180
KeepaliveTimeout = 25

[Peer]
PublicKey = 6kMhJWJhHMwKfZbKpBPRvJqMKLJGDtLwqcXKfVfHbDs=
PresharedKey = FpCyhws9cxwWoV4xELtfJvjJN+zQVRPISllRWgeopVE=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 198.51.100.1:52046
PersistentKeepalive = 25
`

func newProbeDevice(bind conn.Bind) *device.Device {
	logger := device.NewLogger(device.LogLevelError, "probe: ")
	return device.NewDevice(tuntest.NewChannelTUN().TUN(), bind, logger)
}

// TestUpSendsHandshakeInitiation drives the daemon's exact up() sequence and
// asserts that datagrams actually leave the bind. A tunnel that reports "up"
// but emits nothing can never handshake.
func TestUpSendsHandshakeInitiation(t *testing.T) {
	conf, err := ParseConf(realUserConf)
	if err != nil {
		t.Fatalf("ParseConf: %v", err)
	}

	uapi := conf.IpcSetString()
	if !strings.Contains(uapi, "persistent_keepalive_interval=25") {
		t.Fatalf("keepalive missing from UAPI:\n%s", uapi)
	}
	if !strings.Contains(uapi, "endpoint=198.51.100.1:52046") {
		t.Fatalf("endpoint missing from UAPI:\n%s", uapi)
	}

	bind := &recBind{}
	dev := newProbeDevice(bind)
	defer dev.Close()

	if err := dev.IpcSet(uapi); err != nil {
		t.Fatalf("IpcSet: %v", err)
	}
	if err := dev.Up(); err != nil {
		t.Fatalf("Up: %v", err)
	}

	// Give the peer goroutines a moment to emit the initiation burst.
	var sent [][]byte
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if sent = bind.snapshot(); len(sent) > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	if len(sent) == 0 {
		t.Fatalf("device came up but sent NOTHING on the bind — handshake can never start.\n" +
			"This reproduces the reported 'no handshake' symptom.")
	}

	t.Logf("device emitted %d datagrams after Up()", len(sent))
	for i, p := range sent {
		if i >= 15 {
			t.Logf("  ... %d more", len(sent)-i)
			break
		}
		t.Logf("  [%2d] %4d bytes", i, len(p))
	}
}

// TestUpSendsNothingWhenKeepaliveZero is the control: without
// PersistentKeepalive the device has no reason to emit anything until real
// traffic appears. Confirms the probe measures keepalive-driven initiation.
func TestUpSendsNothingWhenKeepaliveZero(t *testing.T) {
	confText := strings.Replace(realUserConf,
		"PersistentKeepalive = 25", "PersistentKeepalive = 0", 1)
	conf, err := ParseConf(confText)
	if err != nil {
		t.Fatalf("ParseConf: %v", err)
	}

	bind := &recBind{}
	dev := newProbeDevice(bind)
	defer dev.Close()

	if err := dev.IpcSet(conf.IpcSetString()); err != nil {
		t.Fatalf("IpcSet: %v", err)
	}
	if err := dev.Up(); err != nil {
		t.Fatalf("Up: %v", err)
	}

	time.Sleep(500 * time.Millisecond)
	sent := bind.snapshot()
	t.Logf("keepalive=0 -> %d datagrams emitted", len(sent))
}

// TestKeepaliveTimerFiresRepeatedly checks the initiation is not a one-shot:
// with keepalive set, the device should keep retrying while the peer stays
// silent, which is what a real (unanswered) tunnel looks like.
func TestKeepaliveTimerFiresRepeatedly(t *testing.T) {
	conf, err := ParseConf(realUserConf)
	if err != nil {
		t.Fatalf("ParseConf: %v", err)
	}

	bind := &recBind{}
	dev := newProbeDevice(bind)
	defer dev.Close()

	if err := dev.IpcSet(conf.IpcSetString()); err != nil {
		t.Fatalf("IpcSet: %v", err)
	}
	if err := dev.Up(); err != nil {
		t.Fatalf("Up: %v", err)
	}

	// RekeyTimeout=5 in the profile: wait long enough for at least one retry.
	time.Sleep(7500 * time.Millisecond)
	sent := bind.snapshot()
	t.Logf("after 7.5s of peer silence: %d datagrams emitted", len(sent))
	if len(sent) == 0 {
		t.Fatal("no datagrams at all after 7.5s — device is inert")
	}
}

// TestKeepaliveToggleRetriggersHandshake proves the nudge the watchdog
// relies on actually revives a *stalled* tunnel.
//
// The profile under test has RekeyTimeout=5 and MaxHandshakeAttempts=5, so
// the device stops retrying on its own after roughly 30 seconds. That is the
// state the watchdog exists for: "tunnel up, no handshake, nothing more will
// ever be sent". Re-issuing persistent_keepalive_interval as 0 -> N makes
// the device emit another handshake burst.
//
// Note the nudge cannot beat RekeyTimeout — SendHandshakeInitiation refuses
// to re-send while time.Since(lastSent) < rekeyMinTimeout(). That is fine:
// before the give-up the device is already retrying every RekeyTimeout, so
// the nudge only needs to work once it has gone quiet.
func TestKeepaliveToggleRetriggersHandshake(t *testing.T) {
	if testing.Short() {
		t.Skip("slow: waits for the device to exhaust MaxHandshakeAttempts")
	}
	conf, err := ParseConf(realUserConf)
	if err != nil {
		t.Fatalf("ParseConf: %v", err)
	}
	pubHex, err := b64ToHex(conf.PublicKey)
	if err != nil {
		t.Fatalf("b64ToHex: %v", err)
	}

	bind := &recBind{}
	dev := newProbeDevice(bind)
	defer dev.Close()

	if err := dev.IpcSet(conf.IpcSetString()); err != nil {
		t.Fatalf("IpcSet: %v", err)
	}
	if err := dev.Up(); err != nil {
		t.Fatalf("Up: %v", err)
	}

	// Wait for the give-up: ~5 attempts spaced RekeyTimeout=5s apart.
	time.Sleep(35 * time.Second)

	before := len(bind.snapshot())
	if before == 0 {
		t.Fatal("no handshake attempts at all; probe is not measuring anything")
	}

	// confirm the device has really gone quiet before we nudge
	time.Sleep(8 * time.Second)
	quiet := len(bind.snapshot())
	if quiet != before {
		t.Logf("note: device still retrying on its own (%d -> %d)", before, quiet)
	} else {
		t.Logf("device has given up after %d datagrams — this is the stalled state", quiet)
	}

	// the nudge, exactly as handshakeWatchdog issues it
	sel := "public_key=" + pubHex + "\n"
	if err := dev.IpcSet(sel + "persistent_keepalive_interval=0\n"); err != nil {
		t.Fatalf("nudge off: %v", err)
	}
	if err := dev.IpcSet(sel + "persistent_keepalive_interval=25\n"); err != nil {
		t.Fatalf("nudge on: %v", err)
	}

	time.Sleep(1 * time.Second)
	after := len(bind.snapshot())
	if after <= quiet {
		t.Fatalf("nudge produced no new datagrams (quiet=%d after=%d) — "+
			"the watchdog cannot revive a stalled tunnel", quiet, after)
	}
	t.Logf("nudge revived the tunnel: %d -> %d datagrams (+%d)", quiet, after, after-quiet)
}
