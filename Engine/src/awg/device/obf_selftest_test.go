/* SPDX-License-Identifier: MIT
 *
 * obf_selftest_test.go — end-to-end AmneziaWG obfuscation self-test
 * (Mavericks port).
 *
 * Two full Device instances are wired together over the in-memory channel
 * bind and channel TUN, both configured with identical AmneziaWG parameters
 * (Jc/Jmin/Jmax/S1/S2/H1..H4). A successful bidirectional ping proves that:
 *   - junk datagrams and S1/S2-prefixed, H-typed handshake packets are
 *     accepted by the receiving side (junk stripped, type resolved),
 *   - transport packets typed with H4 flow through both directions.
 */

package device

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"strings"
	"testing"
	"time"

	"awg/conn/bindtest"
	"awg/tun"
	"awg/tun/tuntest"

	"golang.org/x/crypto/curve25519"
)

type obfTestPair struct {
	devs [2]*Device
	tuns [2]*tuntest.ChannelTUN
}

func newObfTestPair(t *testing.T, cfg string) *obfTestPair {
	t.Helper()

	binds := bindtest.NewChannelBinds()
	pair := new(obfTestPair)

	for i := 0; i < 2; i++ {
		tuns := tuntest.NewChannelTUN()
		pair.tuns[i] = tuns
		logger := NewLogger(LogLevelVerbose, fmt.Sprintf("dev%d: ", i))
		dev := NewDevice(tuns.TUN(), binds[i], logger)
		pair.devs[i] = dev
	}

	// key material
	privA, err1 := newPrivateKey()
	if err1 != nil {
		t.Fatal(err1)
	}
	privB, err2 := newPrivateKey()
	if err2 != nil {
		t.Fatal(err2)
	}
	pubA := privA.publicKey()
	pubB := privB.publicKey()

	endpoint := map[int]string{0: "127.0.0.1:1", 1: "127.0.0.1:2"}
	allowed := map[int]string{0: "10.0.0.2/32", 1: "10.0.0.1/32"}

	for i, dev := range pair.devs {
		var priv, pub [32]byte
		if i == 0 {
			copy(priv[:], privA[:])
			copy(pub[:], pubB[:])
		} else {
			copy(priv[:], privB[:])
			copy(pub[:], pubA[:])
		}
		cfgTrimmed := strings.TrimRight(cfg, "\n")
		parts := []string{
			"private_key=" + hex.EncodeToString(priv[:]),
		}
		if cfgTrimmed != "" {
			parts = append(parts, cfgTrimmed)
		}
		parts = append(parts,
			"public_key="+hex.EncodeToString(pub[:]),
			"endpoint="+endpoint[i],
			"allowed_ip="+allowed[i],
			"",
		)
		full := strings.Join(parts, "\n")
		if err := dev.IpcSet(full); err != nil {
			t.Fatalf("IpcSet (dev %d) failed: %v", i, err)
		}
		if err := dev.Up(); err != nil {
			t.Fatalf("Up (dev %d) failed: %v", i, err)
		}
	}
	return pair
}

// obfTestPacket builds a minimal IPv4/UDP packet with the given endpoints.
func obfTestPacket(src, dst [4]byte, payload []byte) []byte {
	pkt := make([]byte, 20+len(payload))
	pkt[0] = 0x45
	binary.BigEndian.PutUint16(pkt[2:4], uint16(len(pkt)))
	pkt[8] = 64
	pkt[9] = 17 // UDP
	copy(pkt[12:16], src[:])
	copy(pkt[16:20], dst[:])
	copy(pkt[20:], payload)
	return pkt
}

func obfPingPong(t *testing.T, pair *obfTestPair) {
	t.Helper()
	for i, dev := range pair.devs {
		dbg, _ := dev.IpcGet()
		t.Logf("dev%d config:\n%s", i, dbg)
		dev.peers.RLock()
		for _, p := range dev.peers.keyMap {
			t.Logf("dev%d peer running=%v stopped=%d", i, p.isRunning.Get(), 0)
		}
		dev.peers.RUnlock()
	}

	t.Helper()

	var s1, d1, s2, d2 [4]byte
	copy(s1[:], []byte{10, 0, 0, 1})
	copy(d1[:], []byte{10, 0, 0, 2})
	copy(s2[:], []byte{10, 0, 0, 2})
	copy(d2[:], []byte{10, 0, 0, 1})

	// A -> B
	ping := obfTestPacket(s1, d1, []byte("ping-from-A"))
	select {
	case pair.tuns[0].Outbound <- ping:
	case <-time.After(5 * time.Second):
		t.Fatal("timeout injecting ping into device A")
	}
	select {
	case got := <-pair.tuns[1].Inbound:
		if !bytes.Equal(got, ping) {
			t.Fatalf("B received wrong packet: %x", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timeout waiting for ping from device B (handshake with obfuscation failed)")
	}

	// B -> A (uses the established keypair)
	pong := obfTestPacket(s2, d2, []byte("pong-from-B"))
	select {
	case pair.tuns[1].Outbound <- pong:
	case <-time.After(5 * time.Second):
		t.Fatal("timeout injecting pong into device B")
	}
	select {
	case got := <-pair.tuns[0].Inbound:
		if !bytes.Equal(got, pong) {
			t.Fatalf("A received wrong packet: %x", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timeout waiting for pong from device A")
	}
}

// The classic AmneziaWG parameter set, as used by Amnezia-based servers.
const obfClassicCfg = "" +
	"jc=4\n" +
	"jmin=40\n" +
	"jmax=70\n" +
	"s1=15\n" +
	"s2=73\n" +
	"h1=1234567\n" +
	"h2=2345678\n" +
	"h3=3456789\n" +
	"h4=4567890\n"

func TestObfuscatedHandshakeClassic(t *testing.T) {
	pair := newObfTestPair(t, obfClassicCfg)
	defer pair.devs[0].Close()
	defer pair.devs[1].Close()
	obfPingPong(t, pair)

	// Verify the device really is in obfuscated mode and reports the params.
	got, err := pair.devs[0].IpcGet()
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"jc=4", "jmin=40", "jmax=70", "s1=15", "s2=73", "h1=1234567", "h4=4567890"} {
		if !bytes.Contains([]byte(got), []byte(key)) {
			t.Errorf("IpcGet missing %q in:\n%s", key, got)
		}
	}
}

func TestObfuscatedHandshakeMinimal(t *testing.T) {
	// Only header overrides, no junk at all — must still interoperate.
	cfg := "h1=991\nh2=992\nh3=993\nh4=994\n"
	pair := newObfTestPair(t, cfg)
	defer pair.devs[0].Close()
	defer pair.devs[1].Close()
	obfPingPong(t, pair)
}

func TestPlainHandshakeStillWorks(t *testing.T) {
	// No obfuscation keys at all — vanilla WireGuard behavior must be intact.
	pair := newObfTestPair(t, "")
	defer pair.devs[0].Close()
	defer pair.devs[1].Close()
	obfPingPong(t, pair)
}

func TestObfConfigValidation(t *testing.T) {
	dev := NewDevice(
		tuntest.NewChannelTUN().TUN(),
		bindtest.NewChannelBinds()[0],
		NewLogger(LogLevelError, ""),
	)
	defer dev.Close()

	// duplicate magic headers must be rejected
	bad := obfClassicCfg + "h2=1234567\n"
	err := dev.IpcSet("private_key=" + hex.EncodeToString(newPrivateKeyRaw()) + "\n" + bad + "\n")
	if err == nil {
		t.Fatal("expected duplicate-header config to be rejected")
	}

	// jmax < jmin must be rejected
	err = dev.IpcSet("jc=3\njmin=90\njmax=40\n\n")
	if err == nil {
		t.Fatal("expected jmax<jmin config to be rejected")
	}
}

func newPrivateKeyRaw() []byte {
	sk, _ := newPrivateKey()
	return sk[:]
}

// keep the curve25519 import meaningful if tests above change
var _ = curve25519.ScalarBaseMult
var _ tun.Device
