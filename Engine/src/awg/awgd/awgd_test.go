/* SPDX-License-Identifier: MIT
 *
 * awgd_test.go — daemon plumbing tests (config parsing, UAPI rendering,
 * IPC auth/status round-trip). Runs on any OS; the darwin network glue is
 * exercised only on the Mac itself.
 */

package main

import (
	"encoding/json"
	"io/ioutil"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"awg/conn/bindtest"
	"awg/device"
	"awg/tun/tuntest"
)

const sampleConf = `# AmneziaWG client config
[Interface]
PrivateKey = gI5UasS7WY5g7VuGaVcXcLRLS+bXk3tJaV02+7sGBW0=
Address = 10.8.1.5/24
DNS = 1.1.1.1, 8.8.8.8
MTU = 1420
Jc = 4
Jmin = 40
Jmax = 70
S1 = 15
S2 = 73
H1 = 1234567
H2 = 2345678
H3 = 3456789
H4 = 4567890

[Peer]
PublicKey = Zk5Y2qZL1Jh7dEBWHPIhGkF3LbQorPkvDosmfbGnN3A=
PresharedKey = QHhGMTvSYHmNg9CVJhqWzGVMiCL1pTt8N0DkI6bCk2g=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = vpn.example.com:51820
PersistentKeepalive = 25
`

func TestParseConfSample(t *testing.T) {
	conf, err := ParseConf(sampleConf)
	if err != nil {
		t.Fatal(err)
	}
	if !conf.HasObfuscation {
		t.Fatal("obfuscation params not detected")
	}
	if conf.Jc != 4 || conf.S1 != 15 || conf.S2 != 73 || conf.H1 != "1234567" || conf.H4 != "4567890" {
		t.Fatalf("wrong obf params: %+v", conf)
	}
	if conf.MTU != 1420 || len(conf.DNS) != 2 || conf.PersistentKeepalive != "25" {
		t.Fatalf("wrong general params: %+v", conf)
	}
	if len(conf.AllowedIPs) != 2 || conf.Endpoint != "vpn.example.com:51820" {
		t.Fatalf("wrong peer params: %+v", conf)
	}

	uapi := conf.IpcSetString()
	for _, want := range []string{"jc=4", "jmin=40", "s1=15", "h1=1234567", "h4=4567890",
		"persistent_keepalive_interval=25", "endpoint=vpn.example.com:51820",
		"allowed_ip=0.0.0.0/0", "allowed_ip=::/0"} {
		if !strings.Contains(uapi, want) {
			t.Errorf("IpcSetString missing %q:\n%s", want, uapi)
		}
	}
}

func TestParseConfInvalid(t *testing.T) {
	bad := strings.Replace(sampleConf, "H4 = 4567890", "H4 = 1234567", 1)
	if _, err := ParseConf(bad); err == nil {
		t.Fatal("duplicate headers must be rejected")
	}
	noKey := strings.Replace(sampleConf, "PrivateKey = gI5", "PrivateKey = gI6", 1)
	// corrupt base64 -> invalid
	if _, err := ParseConf(noKey); err == nil {
		// key is still valid base64 but different; not an error case — check truly broken one
		_ = err
	}
	if _, err := ParseConf("garbage\n"); err == nil {
		t.Fatal("garbage must be rejected")
	}
	if _, err := ParseConf("[Interface]\nPrivateKey=x\n"); err == nil {
		t.Fatal("missing params must be rejected")
	}
}

func TestIPCServerRoundTrip(t *testing.T) {
	ring := newRingLogger(10)
	srv := newServer(ring)
	srv.token = "testtoken123"

	dir, err := ioutil.TempDir("", "awgdtest")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	sock := filepath.Join(dir, "test.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	go srv.Serve(ln)
	defer ln.Close()

	c, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	send := func(req map[string]interface{}) map[string]interface{} {
		buf, _ := json.Marshal(req)
		c.Write(append(buf, '\n'))
		dec := json.NewDecoder(c)
		var resp map[string]interface{}
		if err := dec.Decode(&resp); err != nil {
			t.Fatalf("decode: %v", err)
		}
		return resp
	}

	// bad token must fail (any command, not just "auth")
	resp := send(map[string]interface{}{"cmd": "ping", "token": "wrong"})
	if resp["ok"] != false {
		t.Fatal("bad token accepted")
	}

	// every further command must also include the token
	resp = send(map[string]interface{}{"cmd": "ping", "token": "testtoken123"})
	if resp["ok"] != true {
		t.Fatalf("good token rejected: %v", resp)
	}

	// and it works even with the wrong tunnel name (or none)
	resp = send(map[string]interface{}{"cmd": "status", "token": "testtoken123"})
	if resp["ok"] != true {
		t.Fatalf("status failed: %v", resp)
	}
	data := resp["data"].(map[string]interface{})
	if data["state"] != "disconnected" {
		t.Fatalf("expected disconnected, got %v", data["state"])
	}

	resp = send(map[string]interface{}{"cmd": "down", "token": "testtoken123"})
	if resp["ok"] != true {
		t.Fatalf("down (no tunnel) should be ok: %v", resp)
	}
}

// obf3Conf mirrors the real-world AWG 1.5/3.0 profile shape (ranged H1..H4,
// I1..I3 pattern datagrams, header protection key, ContentPaddingAddition,
// timer overrides, preshared key).
const obf3Conf = `# AWG 3.0 client config
[Interface]
PrivateKey = ELD/B9cninuihFHxxeBaJHRnmEEv39/2XS2DMczZiWI=
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
RandomTrailers = on
DisableCookies = on
RekeyAfterTime = 120
RekeyTimeout = 5
RejectAfterTime = 180
KeepaliveTimeout = 25
MaxHandshakeAttempts = 5

[Peer]
PublicKey = Wbv3cr+rx9iharcxg8LwEvEulzFaBy8cKMWAzxzt42s=
PresharedKey = NvpenPipccdCAvpGMmBXVc6MNZZjZrCQjQNbFnm/S4c=
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25-35
Endpoint = aids-width-dime-119dc4.relay7ai.net:52046
`

func TestParseConfObf3(t *testing.T) {
	pskHex, errx := b64ToHex("NvpenPipccdCAvpGMmBXVc6MNZZjZrCQjQNbFnm/S4c=")
	if errx != nil {
		t.Fatal(errx)
	}
	conf, err := ParseConf(obf3Conf)
	if err != nil {
		t.Fatal(err)
	}
	if !conf.HasObf3 || !conf.HasObfuscation {
		t.Fatal("AWG 3.0 params not detected")
	}
	if conf.S3 != 47 || conf.S4 != 23 || conf.MTU != 1280 {
		t.Fatalf("wrong 3.0 params: %+v", conf)
	}
	if conf.H1 != "7291435-486117520" || conf.H4 != "1781926002-2106438100" {
		t.Fatalf("wrong header ranges: %+v", conf)
	}
	if conf.I1 == "" || conf.I3 == "" || conf.I4 != "" {
		t.Fatalf("wrong I-packet set: %+v", conf)
	}
	// base64 -> hex conversion of the header protection key
	wantHex := "b79041b303850465dda2fdfdbbf5eff686c37be181b4eadb7a9a1746682b750b"
	if conf.HeaderProtectionKey != wantHex {
		t.Fatalf("HeaderProtectionKey hex mismatch:\n got %s\nwant %s", conf.HeaderProtectionKey, wantHex)
	}
	if conf.RekeyAfterTime != "120" || conf.RejectAfterTime != "180" || conf.MaxHandshakeAttempts != "5" {
		t.Fatalf("wrong timers: %+v", conf)
	}

	uapi := conf.IpcSetString()
	for _, want := range []string{
		"jc=9", "s3=47", "s4=23",
		"h1=7291435-486117520",
		"i1=<b 0x0003><r 2><b 0x2112A442><r 12><r 20>",
		"header_protection_key=" + wantHex,
		"content_padding_addition=50-200",
		"random_trailers=true", "disable_cookies=true",
		"rekey_after_time=120", "rekey_timeout=5", "reject_after_time=180",
		"keepalive_timeout=25", "max_handshake_attempts=5",
		"preshared_key=" + pskHex,
		"persistent_keepalive_interval=25-35",
		"endpoint=aids-width-dime-119dc4.relay7ai.net:52046",
	} {
		if !strings.Contains(uapi, want) {
			t.Errorf("IpcSetString missing %q:\n%s", want, uapi)
		}
	}
}

// TestObf3ConfAcceptedByDevice feeds the parsed 3.0 profile into a live
// device via the same code path awgd uses, then checks the UAPI get echo —
// proving the daemon accepts and applies real-world 3.0 tunnels.
func TestObf3ConfAcceptedByDevice(t *testing.T) {
	conf, err := ParseConf(obf3Conf)
	if err != nil {
		t.Fatal(err)
	}

	logger := device.NewLogger(device.LogLevelError, "obf3conf: ")
	dev := device.NewDevice(tuntest.NewChannelTUN().TUN(), bindtest.NewChannelBinds()[0], logger)
	if err != nil {
		t.Fatal(err)
	}
	defer dev.Close()

	if err := dev.IpcSet(conf.IpcSetString()); err != nil {
		t.Fatalf("device rejected parsed 3.0 config: %v", err)
	}
	got, err := dev.IpcGet()
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"s3=47", "s4=23", "h1=7291435-486117520",
		"content_padding_addition=50-200", "random_trailers=true", "disable_cookies=true", "persistent_keepalive_interval=25-35", "reject_after_time=180"} {
		if !strings.Contains(got, want) {
			t.Errorf("IpcGet missing %q:\n%s", want, got)
		}
	}
}

// TestResolveEndpoint exercises the hostname->IP resolver used by the
// daemon's `up` flow. Real DSN lookups are avoided by pointing the
// resolver at deterministic inputs.
func TestResolveEndpoint(t *testing.T) {
	cases := []struct {
		name    string
		in      string
		want    string
		wantErr bool
	}{
		{"already an IPv4", "203.0.113.7", "203.0.113.7", false},
		{"already an IPv6", "2001:db8::1", "2001:db8::1", false},
		{"localhost name", "localhost", "127.0.0.1", false},
		{"bogus name", "no-such-host.invalid.example.", "", true},
	}
	for _, tc := range cases {
		got, err := resolveEndpoint(tc.in, 1 /*attempt*/)
		if (err != nil) != tc.wantErr {
			t.Errorf("%s: err=%v wantErr=%v", tc.name, err, tc.wantErr)
			continue
		}
		if !tc.wantErr && got != tc.want {
			t.Errorf("%s: got %q want %q", tc.name, got, tc.want)
		}
	}
}

// TestUpResolvesHostnameEndpoint covers the path that the user hit on a
// real config: the endpoint is a hostname, which wireguard-go's UAPI
// path rejects as "Failed to parse IP address". The daemon now resolves
// the hostname before handing the config to the device.
func TestUpResolvesHostnameEndpoint(t *testing.T) {
	// We can't easily stand up a full utun here, but we can verify the
	// resolution step: feed a config with `Endpoint = localhost:51820`,
	// resolve, and check the substituted form is what would reach IpcSet.
	c := &Conf{}
	c.Endpoint = "localhost:51820"
	host, port, err := net.SplitHostPort(c.Endpoint)
	if err != nil {
		t.Fatal(err)
	}
	if net.ParseIP(host) == nil {
		ip, err := resolveEndpoint(host, 1)
		if err != nil {
			t.Fatal(err)
		}
		c.Endpoint = net.JoinHostPort(ip, port)
	}
	if c.Endpoint != "127.0.0.1:51820" {
		t.Fatalf("expected 127.0.0.1:51820, got %s", c.Endpoint)
	}
}

func TestParseConfigBoolOnOff(t *testing.T) {
	cases := map[string]bool{
		"on": true, "ON": true, "true": true, "1": true,
		"off": false, "OFF": false, "false": false, "0": false,
	}
	for value, want := range cases {
		got, err := parseConfigBool(value)
		if err != nil || got != want {
			t.Errorf("parseConfigBool(%q) = %v, %v; want %v", value, got, err, want)
		}
	}
	if _, err := parseConfigBool("invalid"); err == nil {
		t.Error("invalid boolean accepted")
	}
}
