/* SPDX-License-Identifier: MIT
 *
 * tun_eagain_test.go — regression test for "tunnel comes up, then dies".
 *
 * On macOS the utun descriptor used to be opened non-blocking while
 * os.NewFile() left it outside the runtime poller, so an idle read returned
 * EAGAIN. RoutineReadFromTUN treated every error other than "file closed" as
 * fatal and called device.Close(), tearing the device down milliseconds after
 * it came up. The tunnel reported "up", emitted a single handshake initiation,
 * and then died before any response could arrive — the reported symptom was
 * simply "no handshake".
 *
 * These tests pin both halves of the fix:
 *   - errIsTemporary classifies EAGAIN/EWOULDBLOCK/EINTR as retryable;
 *   - the TUN reader survives a burst of EAGAIN instead of killing the device.
 */

package device

import (
	"errors"
	"os"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"awg/conn/bindtest"
	"awg/tun"
)

// eagainTUN returns EAGAIN for the first `eagains` reads, then parks until
// the test releases it, and finally reports the descriptor as closed.
type eagainTUN struct {
	eagains int32
	reads   int32
	release chan struct{}
	events  chan tun.Event
	mtu     int
}

func newEagainTUN(eagains int) *eagainTUN {
	return &eagainTUN{
		eagains: int32(eagains),
		release: make(chan struct{}),
		events:  make(chan tun.Event, 1),
		mtu:     1420,
	}
}

func (t *eagainTUN) File() *os.File                     { return os.Stdin }
func (t *eagainTUN) Flush() error                       { return nil }
func (t *eagainTUN) MTU() (int, error)                  { return t.mtu, nil }
func (t *eagainTUN) Name() (string, error)              { return "eagain0", nil }
func (t *eagainTUN) Events() chan tun.Event             { return t.events }
func (t *eagainTUN) Write(b []byte, o int) (int, error) { return len(b) - o, nil }

func (t *eagainTUN) Read(buf []byte, offset int) (int, error) {
	n := atomic.AddInt32(&t.reads, 1)
	if n <= atomic.LoadInt32(&t.eagains) {
		return 0, syscall.EAGAIN
	}
	// Nothing more to deliver; park until the test is done so the reader
	// goroutine stays blocked rather than spinning through the loop.
	<-t.release
	return 0, os.ErrClosed
}

func (t *eagainTUN) Close() error {
	select {
	case <-t.release:
	default:
		close(t.release)
	}
	return nil
}

func (t *eagainTUN) readCount() int32 { return atomic.LoadInt32(&t.reads) }

// TestErrIsTemporary pins the classification used by the TUN reader.
func TestErrIsTemporary(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"EAGAIN", syscall.EAGAIN, true},
		{"EWOULDBLOCK", syscall.EWOULDBLOCK, true},
		{"EINTR", syscall.EINTR, true},
		{"wrapped EAGAIN", &os.PathError{Op: "read", Err: syscall.EAGAIN}, true},
		{"wrapped EAGAIN via SyscallError",
			&os.SyscallError{Syscall: "read", Err: syscall.EAGAIN}, true},
		{"EBADF is not temporary", syscall.EBADF, false},
		{"closed is not temporary", os.ErrClosed, false},
		{"generic error is not temporary", errors.New("boom"), false},
		{"nil", nil, false},
	}
	for _, tc := range cases {
		if got := errIsTemporary(tc.err); got != tc.want {
			t.Errorf("%s: errIsTemporary = %v, want %v", tc.name, got, tc.want)
		}
	}
}

// TestTUNReaderSurvivesEAGAIN is the regression test for the bug above: a TUN
// that returns EAGAIN must not take the device down.
func TestTUNReaderSurvivesEAGAIN(t *testing.T) {
	tdev := newEagainTUN(50) // hand the reader a long burst of EAGAIN
	defer tdev.Close()

	dev := NewDevice(tdev, bindtest.NewChannelBinds()[0], NewLogger(LogLevelError, "eagain: "))
	dev.Up()
	defer dev.Close()

	// Give the reader time to chew through the burst and, in the buggy
	// version, fatal out.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if tdev.readCount() > 5 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	if tdev.readCount() == 0 {
		t.Fatal("TUN reader never called Read")
	}

	// The device must still be alive.
	//
	// Note: device.Close() runs asynchronously ("go device.Close()"), and
	// IpcGet does not reject a closing device promptly, so an IpcGet probe
	// passes even in the broken build. isClosed()/isUp() read the state
	// directly and are what actually distinguish the two.
	if dev.isClosed() {
		t.Fatalf("device was closed after %d EAGAIN reads — EAGAIN must be "+
			"retried, not treated as fatal", tdev.readCount())
	}
	if !dev.isUp() {
		t.Fatalf("device is no longer up after %d EAGAIN reads", tdev.readCount())
	}
	if _, err := dev.IpcGet(); err != nil {
		t.Fatalf("IpcGet failed after %d EAGAIN reads: %v", tdev.readCount(), err)
	}

	t.Logf("device survived %d EAGAIN reads (still up)", tdev.readCount())
}
