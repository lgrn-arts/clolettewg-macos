/* SPDX-License-Identifier: MIT
 *
 * util.go — key handling, logging ring and small helpers for awgd.
 * Go 1.10 compatible (Mavericks port).
 */

package main

import (
	crand "crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"sync"
	"time"

	"awg/conn"
	"awg/device"
	"awg/tun"

	"golang.org/x/crypto/curve25519"
)

var base64Std = base64.StdEncoding

// runCmd executes a helper tool and returns its combined output.
func runCmd(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// ------------------------------------------------------------- keys

func generatePrivateKey() ([]byte, error) {
	key := make([]byte, 32)
	if _, err := crand.Read(key); err != nil {
		return nil, err
	}
	key[0] &= 248
	key[31] = (key[31] & 127) | 64
	return key, nil
}

func encodeKey(key []byte) string {
	return base64Std.EncodeToString(key)
}

func derivePublicKey(privText string) (string, error) {
	raw, err := base64Decode(privText)
	if err != nil || len(raw) != 32 {
		return "", fmt.Errorf("invalid private key")
	}
	var privateKey, publicKey [32]byte
	copy(privateKey[:], raw)
	curve25519.ScalarBaseMult(&publicKey, &privateKey)
	return encodeKey(publicKey[:]), nil
}

func randomToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := crand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

func readFileLimited(path string, max int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if st.Size() > max {
		return nil, fmt.Errorf("%s too large", path)
	}
	buf := make([]byte, st.Size())
	_, err = f.Read(buf)
	if err != nil {
		return nil, err
	}
	return buf, nil
}

// ------------------------------------------------------------- bind

func connNewBind() conn.Bind { return conn.NewDefaultBind() }

// createTunForConf / createTunProbe wrap tun.CreateTUN (darwin only paths).
func createTunForConf(conf *Conf) (tun.Device, error) {
	return tun.CreateTUN("utun", conf.MTU)
}

func createTunProbe() (tun.Device, error) {
	return tun.CreateTUN("utun", 1420)
}

// ------------------------------------------------------------- logging

type logLine struct {
	T time.Time
	S string
}

// ringLogger keeps the last N lines in memory (served to the GUI) and
// mirrors them to stderr / the service log file.
type ringLogger struct {
	mu   sync.Mutex
	buf  []logLine
	max  int
	file *os.File
	dev  *device.Logger
}

func newRingLogger(max int) *ringLogger {
	r := &ringLogger{max: max}
	f, err := os.OpenFile(serviceLog, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0640)
	if err == nil {
		r.file = f
	}
	return r
}

func (r *ringLogger) add(s string) {
	r.mu.Lock()
	if len(r.buf) >= r.max {
		copy(r.buf, r.buf[1:])
		r.buf = r.buf[:r.max-1]
	}
	r.buf = append(r.buf, logLine{T: time.Now(), S: s})
	r.mu.Unlock()
	if r.file != nil {
		fmt.Fprintf(r.file, "%s %s\n", time.Now().Format("2006-01-02 15:04:05"), s)
	}
}

func (r *ringLogger) Infof(format string, args ...interface{}) {
	r.add("[info] " + fmt.Sprintf(format, args...))
}

func (r *ringLogger) Errorf(format string, args ...interface{}) {
	r.add("[error] " + fmt.Sprintf(format, args...))
}

func (r *ringLogger) Warnf(format string, args ...interface{}) {
	r.add("[warn] " + fmt.Sprintf(format, args...))
}

func (r *ringLogger) tail(n int) []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if n > len(r.buf) {
		n = len(r.buf)
	}
	out := make([]string, 0, n)
	for _, ln := range r.buf[len(r.buf)-n:] {
		out = append(out, fmt.Sprintf("%s %s", ln.T.Format("15:04:05"), ln.S))
	}
	return out
}

// deviceLogger returns a *device.Logger whose Verbosef/Errorf feed the ring
// (and therefore the on-disk service log and the GUI's "cmd=log" view).
//
// It exists because device.NewLogger writes straight to os.Stdout; under
// launchd that lands in StandardOutPath (launchd.log), while every other
// daemon message lands in the ring / awgd.log. Splitting them in two made
// handshake diagnostics invisible in the log people actually read.
func (r *ringLogger) deviceLogger() *device.Logger {
	return &device.Logger{
		Verbosef: func(format string, args ...interface{}) {
			r.add("[device] " + fmt.Sprintf(format, args...))
		},
		Errorf: func(format string, args ...interface{}) {
			r.add("[device-err] " + fmt.Sprintf(format, args...))
		},
	}
}
