/* SPDX-License-Identifier: MIT
 *
 * obfchain.go — AmneziaWG 1.5/3.0 obfuscation chains (the I1..I5 pattern
 * DSL: <b hex>, <t>, <r n>, <rc n>, <rd n>, <d>, <ds>, <dz>).
 * Ported from amneziawg-go v3.0.3 (device/obf*.go), adapted to Go 1.10
 * (no errors.Join; base64.RawStdEncoding and unicode are available).
 */

package device

import (
	"bytes"
	crand "crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode"
)

type obfBuilder func(val string) (obf, error)

var obfBuilders = map[string]obfBuilder{
	"b":  newBytesObf,
	"t":  newTimestampObf,
	"r":  newRandObf,
	"rc": newRandCharObf,
	"rd": newRandDigitsObf,
	"d":  newDataObf,
	"ds": newDataStringObf,
	"dz": newDataSizeObf,
}

type obf interface {
	Obfuscate(dst, src []byte)
	Deobfuscate(dst, src []byte) bool
	ObfuscatedLen(srcLen int) int
	DeobfuscatedLen(srcLen int) int
}

type obfChain struct {
	Spec string
	obfs []obf
}

func newObfChain(spec string) (*obfChain, error) {
	var (
		obfs []obf
		errs []string
	)

	remaining := spec[:]
	for {
		start := strings.IndexByte(remaining, '<')
		if start == -1 {
			break
		}

		end := strings.IndexByte(remaining[start:], '>')
		if end == -1 {
			return nil, errors.New("missing enclosing >")
		}
		end += start

		tag := remaining[start+1 : end]
		parts := strings.Fields(tag)
		if len(parts) == 0 {
			errs = append(errs, "empty tag")
			remaining = remaining[end+1:]
			continue
		}

		key := parts[0]
		builder, ok := obfBuilders[key]
		if !ok {
			errs = append(errs, fmt.Sprintf("unknown tag <%s>", key))
			remaining = remaining[end+1:]
			continue
		}

		val := ""
		if len(parts) > 1 {
			val = parts[1]
		}

		o, err := builder(val)
		if err != nil {
			errs = append(errs, fmt.Sprintf("failed to build <%s>: %v", key, err))
			remaining = remaining[end+1:]
			continue
		}

		obfs = append(obfs, o)
		remaining = remaining[end+1:]
	}

	if len(errs) > 0 {
		return nil, errors.New(strings.Join(errs, "; "))
	}
	if len(obfs) == 0 {
		return nil, nil
	}

	return &obfChain{
		Spec: spec,
		obfs: obfs,
	}, nil
}

// Obfuscate concatenates each chain element's contribution for src.
// For I-packets src is nil (chains built only from fixed/random elements).
func (c *obfChain) Obfuscate(dst, src []byte) {
	written := 0
	for _, o := range c.obfs {
		obfLen := o.ObfuscatedLen(len(src))
		o.Obfuscate(dst[written:written+obfLen], src)
		written += obfLen
	}
}

func (c *obfChain) Deobfuscate(dst, src []byte) bool {
	dynamicLen := len(src) - c.ObfuscatedLen(0)

	written, read := 0, 0

	for _, o := range c.obfs {
		deobfLen := o.DeobfuscatedLen(dynamicLen)
		obfLen := o.ObfuscatedLen(deobfLen)

		if !o.Deobfuscate(dst[written:written+deobfLen], src[read:read+obfLen]) {
			return false
		}

		written += deobfLen
		read += obfLen
	}

	return true
}

func (c *obfChain) ObfuscatedLen(n int) int {
	total := 0
	for _, o := range c.obfs {
		total += o.ObfuscatedLen(n)
	}
	return total
}

func (c *obfChain) DeobfuscatedLen(n int) int {
	dynamicLen := n - c.ObfuscatedLen(0)

	total := 0
	for _, o := range c.obfs {
		total += o.DeobfuscatedLen(dynamicLen)
	}
	return total
}

// ---- <b hex> ------------------------------------------------------------

type bytesObf struct {
	data []byte
}

func newBytesObf(val string) (obf, error) {
	val = strings.TrimPrefix(val, "0x")

	if len(val) == 0 {
		return nil, errors.New("empty argument")
	}
	if len(val)%2 != 0 {
		return nil, errors.New("odd amount of symbols")
	}

	data, err := hex.DecodeString(val)
	if err != nil {
		return nil, err
	}

	return &bytesObf{data: data}, nil
}

func (o *bytesObf) Obfuscate(dst, src []byte) { copy(dst, o.data) }

func (o *bytesObf) Deobfuscate(dst, src []byte) bool {
	return bytes.Equal(o.data, src[:o.ObfuscatedLen(0)])
}

func (o *bytesObf) ObfuscatedLen(srcLen int) int   { return len(o.data) }
func (o *bytesObf) DeobfuscatedLen(srcLen int) int { return 0 }

// ---- <t> (unix timestamp, big endian) -----------------------------------

type timestampObf struct{}

func newTimestampObf(_ string) (obf, error) {
	return &timestampObf{}, nil
}

func (o *timestampObf) Obfuscate(dst, src []byte) {
	t := uint32(time.Now().Unix())
	binary.BigEndian.PutUint32(dst, t)
}

func (o *timestampObf) Deobfuscate(dst, src []byte) bool {
	return true
}

func (o *timestampObf) ObfuscatedLen(n int) int   { return 4 }
func (o *timestampObf) DeobfuscatedLen(n int) int { return 0 }

// ---- <r n> (n random bytes) ----------------------------------------------

type randObf struct {
	length int
}

func newRandObf(val string) (obf, error) {
	length, err := strconv.Atoi(val)
	if err != nil {
		return nil, err
	}
	return &randObf{length: length}, nil
}

func (o *randObf) Obfuscate(dst, src []byte) { crand.Read(dst[:o.length]) }

func (o *randObf) Deobfuscate(dst, src []byte) bool {
	// there is no way to validate randomness :)
	return true
}

func (o *randObf) ObfuscatedLen(n int) int   { return o.length }
func (o *randObf) DeobfuscatedLen(n int) int { return 0 }

// ---- <rc n> (n random letters) -------------------------------------------

const chars52 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

type randCharObf struct {
	length int
}

func newRandCharObf(val string) (obf, error) {
	length, err := strconv.Atoi(val)
	if err != nil {
		return nil, err
	}
	return &randCharObf{length: length}, nil
}

func (o *randCharObf) Obfuscate(dst, src []byte) {
	crand.Read(dst[:o.length])
	for i := 0; i < o.length; i++ {
		dst[i] = chars52[dst[i]%52]
	}
}

func (o *randCharObf) Deobfuscate(dst, src []byte) bool {
	for _, b := range src[:o.length] {
		if !unicode.IsLetter(rune(b)) {
			return false
		}
	}
	return true
}

func (o *randCharObf) ObfuscatedLen(n int) int   { return o.length }
func (o *randCharObf) DeobfuscatedLen(n int) int { return 0 }

// ---- <rd n> (n random digits) ---------------------------------------------

const digits10 = "0123456789"

type randDigitObf struct {
	length int
}

func newRandDigitsObf(val string) (obf, error) {
	length, err := strconv.Atoi(val)
	if err != nil {
		return nil, err
	}
	return &randDigitObf{length: length}, nil
}

func (o *randDigitObf) Obfuscate(dst, src []byte) {
	crand.Read(dst[:o.length])
	for i := 0; i < o.length; i++ {
		dst[i] = digits10[dst[i]%10]
	}
}

func (o *randDigitObf) Deobfuscate(dst, src []byte) bool {
	for _, b := range src[:o.length] {
		if !unicode.IsDigit(rune(b)) {
			return false
		}
	}
	return true
}

func (o *randDigitObf) ObfuscatedLen(n int) int   { return o.length }
func (o *randDigitObf) DeobfuscatedLen(n int) int { return 0 }

// ---- <d>, <ds>, <dz> (data passthrough / base64 / size) --------------------

type dataObf struct{}

func newDataObf(val string) (obf, error) { return &dataObf{}, nil }

func (o *dataObf) Obfuscate(dst, src []byte) { copy(dst, src) }

func (o *dataObf) Deobfuscate(dst, src []byte) bool {
	copy(dst, src)
	return true
}

func (o *dataObf) ObfuscatedLen(n int) int   { return n }
func (o *dataObf) DeobfuscatedLen(n int) int { return n }

type dataStringObf struct{}

func newDataStringObf(val string) (obf, error) { return &dataStringObf{}, nil }

func (o *dataStringObf) Obfuscate(dst, src []byte) {
	base64.RawStdEncoding.Encode(dst, src)
}

func (o *dataStringObf) Deobfuscate(dst, src []byte) bool {
	_, err := base64.RawStdEncoding.Decode(dst, src)
	return err == nil
}

func (o *dataStringObf) ObfuscatedLen(n int) int {
	return base64.RawStdEncoding.EncodedLen(n)
}

func (o *dataStringObf) DeobfuscatedLen(n int) int {
	return base64.RawStdEncoding.DecodedLen(n)
}

type dataSizeObf struct{}

func newDataSizeObf(val string) (obf, error) { return &dataSizeObf{}, nil }

func (o *dataSizeObf) Obfuscate(dst, src []byte) {
	binary.LittleEndian.PutUint32(dst, uint32(len(src)))
}

func (o *dataSizeObf) Deobfuscate(dst, src []byte) bool {
	return true
}

func (o *dataSizeObf) ObfuscatedLen(n int) int   { return 4 }
func (o *dataSizeObf) DeobfuscatedLen(n int) int { return 0 }
