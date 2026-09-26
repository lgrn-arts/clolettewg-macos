/* SPDX-License-Identifier: MIT
 *
 * obftypes.go — AmneziaWG 1.5/3.0 protocol types.
 * Ported from amneziawg-go v3.0.3 (device/noise-types.go), adapted to
 * Go 1.10: no errors.Join / %w, math/rand instead of runtime.fastrandn.
 */

package device

import (
	"crypto/subtle"
	"errors"
	"fmt"
	"math/rand"
	"strconv"
	"strings"
	"sync/atomic"
)

const (
	HeaderCipherKeySize   = 32
	HeaderCipherNonceSize = 12 // chacha20.NonceSize (IETF); upstream v3 uses 12
)

// MessageUnknownType classifies datagrams that match no configured header.
const MessageUnknownType uint32 = 0

// HeaderCipherKey is the AmneziaWG header protection key (HPk).
type HeaderCipherKey [HeaderCipherKeySize]byte

func (key HeaderCipherKey) IsZero() bool {
	var zero HeaderCipherKey
	return key.Equals(zero)
}

func (key HeaderCipherKey) Equals(tar HeaderCipherKey) bool {
	return subtle.ConstantTimeCompare(key[:], tar[:]) == 1
}

func (key *HeaderCipherKey) FromHex(src string) error {
	return loadExactHex(key[:], src)
}

func (key HeaderCipherKey) ToHex() string {
	const hexDigits = "0123456789abcdef"
	out := make([]byte, 0, 2*len(key))
	for _, b := range key {
		out = append(out, hexDigits[b>>4], hexDigits[b&0xf])
	}
	return string(out)
}

// UintRange encodes an inclusive [lo, hi] range of uint32 values in a single
// uint64 (lo | hi<<32), exactly like amneziawg-go v3.
type UintRange uint64

func (r *UintRange) FromUint32(lo, hi uint32) {
	*r = UintRange(uint64(hi)<<32 | uint64(lo))
}

func (r *UintRange) FromString(str string) error {
	parts := strings.Split(str, "-")
	if len(parts) < 1 || len(parts) > 2 {
		return errors.New("wrong format")
	}

	lo, err := strconv.ParseUint(parts[0], 10, 32)
	if err != nil {
		return err
	}

	hi := lo
	if len(parts) > 1 {
		hi, err = strconv.ParseUint(parts[1], 10, 32)
		if err != nil {
			return err
		}
	}

	if hi < lo {
		return errors.New("wrong range specified")
	}

	r.FromUint32(uint32(lo), uint32(hi))
	return nil
}

func (r UintRange) Lo() uint32 { return uint32(r) }
func (r UintRange) Hi() uint32 { return uint32(r >> 32) }

func (r UintRange) Contains(num uint32) bool {
	return r.Lo() <= num && num <= r.Hi()
}

func (r UintRange) IsZero() bool {
	return r == 0
}

func (r UintRange) PickOne() uint32 {
	span := r.Hi() - r.Lo() + 1
	if span == 0 {
		return r.Lo()
	}
	return r.Lo() + fastrandn(span)
}

func (r UintRange) ToString() string {
	if r.Lo() == r.Hi() {
		return fmt.Sprintf("%d", r.Lo())
	}
	return fmt.Sprintf("%d-%d", r.Lo(), r.Hi())
}

func (r UintRange) Overlap(right UintRange) bool {
	return r.Lo() <= right.Hi() && right.Lo() <= r.Hi()
}

// AtomicUintRange is a Go 1.10-safe atomic wrapper (64-bit ops need alignment
// care on 32-bit platforms; darwin/amd64 and linux/amd64 are fine).
type AtomicUintRange struct{ v uint64 }

func (a *AtomicUintRange) Load() UintRange {
	return UintRange(atomic.LoadUint64(&a.v))
}

func (a *AtomicUintRange) Store(r UintRange) {
	atomic.StoreUint64(&a.v, uint64(r))
}

// fastrandn returns a uniform uint32 in [0, n). The upstream uses a go:linkname
// into runtime.fastrandn, which does not exist in Go 1.10's runtime; the
// global math/rand source (mutex-protected) is equivalent for obfuscation
// purposes — these values are not required to be cryptographically random.
func fastrandn(n uint32) uint32 {
	if n == 0 {
		return 0
	}
	return uint32(rand.Int63n(int64(n)))
}
