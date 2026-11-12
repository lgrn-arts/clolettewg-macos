/* SPDX-License-Identifier: MIT
 *
 * obfdevice.go — AmneziaWG obfuscation configuration and helpers.
 *
 * This is the AWG 1.5/3.0 design ported from amneziawg-go v3.0.3 onto the
 * wireguard-go 0.0.20211016 single-packet engine (Go 1.10, Mavericks port).
 * It fully subsumes the classic AWG 1.0 parameters: Jc/Jmin/Jmax remain
 * junk datagram knobs; S1..S4 are the per-message junk prefixes; H1..H4
 * became inclusive UintRange magic headers (a single value "N" is the
 * range [N, N]); I1..I5 are pattern datagrams; HeaderProtectionKey enables
 * ChaCha20 encryption of message headers; ContentPaddingAddition appends
 * random padding inside transport packets; RandomTrailers adds random-length
 * datagram trailers, DisableCookies turns off cookie checks under load, and
 * the timing keys override the WireGuard protocol timers.
 *
 * All state is guarded by device.aSecMux. Go 1.10 has no typed atomics, so
 * UintRange values are read under the mutex (the hot paths only read).
 */

package device

import (
	crand "crypto/rand"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/chacha20"

	"awg/ipc"
)

// obfState carries all AmneziaWG configuration for a Device.
type obfState struct {
	junk struct {
		count int
		min   int
		max   int
	}

	headers struct {
		init      UintRange
		response  UintRange
		cookie    UintRange
		transport UintRange
	}

	paddings struct {
		init      uint32 // S1
		response  uint32 // S2
		cookie    uint32 // S3
		transport uint32 // S4
	}

	ipackets [5]*obfChain // I1..I5

	headerProtectionKey HeaderCipherKey

	contentPaddingAddition UintRange
	randomTrailers         bool
	disableCookies         bool

	timings struct {
		rekeyAfterTimeSec   UintRange
		rekeyTimeoutSec     UintRange
		rejectAfterTimeSec  UintRange
		keepaliveTimeoutSec UintRange
		maxHandshakeAttemps UintRange
	}
}

// setDefaults installs the vanilla WireGuard headers (1..4) — the upstream
// NewDevice does the same, so a device without any AWG keys behaves like
// plain WireGuard.
func (o *obfState) setDefaults() {
	o.headers.init.FromUint32(MessageInitiationType, MessageInitiationType)
	o.headers.response.FromUint32(MessageResponseType, MessageResponseType)
	o.headers.cookie.FromUint32(MessageCookieReplyType, MessageCookieReplyType)
	o.headers.transport.FromUint32(MessageTransportType, MessageTransportType)
}

// obfTemp collects the values of one UAPI set operation (device section).
type obfTemp struct {
	isSet bool
	junk  struct {
		count   int
		min     int
		max     int
		junkSet bool
	}
	headers struct {
		init      UintRange
		response  UintRange
		cookie    UintRange
		transport UintRange
		headerSet bool
	}
	paddings struct {
		init       uint32
		response   uint32
		cookie     uint32
		transport  uint32
		paddingSet bool
	}
	ipackets               [5]*obfChain
	ipacketsSet            bool
	headerProtectionKey    HeaderCipherKey
	headerProtectionSet    bool
	contentPaddingAddition UintRange
	contentPaddingSet      bool
	randomTrailers         bool
	randomTrailersSet      bool
	disableCookies         bool
	disableCookiesSet      bool
	timings                obfTimingsTemp
}

type obfTimingsTemp struct {
	rekeyAfterTimeSec   UintRange
	rekeyTimeoutSec     UintRange
	rejectAfterTimeSec  UintRange
	keepaliveTimeoutSec UintRange
	maxHandshakeAttemps UintRange
	set                 bool
}

// apply validates and installs the collected configuration — the equivalent
// of upstream ipcSetDevice.mergeWithDevice plus the classic junk validation.
func (device *Device) applyObfConfig(temp *obfTemp) error {
	if !temp.isSet {
		return nil
	}

	device.aSecMux.Lock()
	defer device.aSecMux.Unlock()

	// ---- junk datagrams (classic Jc/Jmin/Jmax) ----
	if temp.junk.junkSet {
		if temp.junk.count < 0 {
			return ipcErrorf(ipc.IpcErrorInvalid, "JunkPacketCount should be non negative")
		}
		if temp.junk.max < temp.junk.min {
			return ipcErrorf(ipc.IpcErrorInvalid,
				"maxSize: %d; should be greater than minSize: %d",
				temp.junk.max, temp.junk.min)
		}
		if temp.junk.max >= MaxSegmentSize {
			return ipcErrorf(ipc.IpcErrorInvalid,
				"JunkPacketMaxSize: %d; should be smaller than maxSegmentSize: %d",
				temp.junk.max, MaxSegmentSize)
		}
		device.obf.junk.count = temp.junk.count
		device.obf.junk.min = temp.junk.min
		device.obf.junk.max = temp.junk.max
		if temp.junk.max == temp.junk.min && temp.junk.count > 0 {
			// to make rand gen work (upstream does the same)
			device.obf.junk.max++
		}
	}

	// ---- header ranges (H1..H4) ----
	if temp.headers.headerSet {
		headers := []UintRange{
			temp.headers.init, temp.headers.response,
			temp.headers.cookie, temp.headers.transport,
		}
		for i := 0; i < len(headers); i++ {
			for j := i + 1; j < len(headers); j++ {
				if headers[i].Overlap(headers[j]) {
					return ipcErrorf(ipc.IpcErrorInvalid, "headers must not overlap")
				}
			}
		}
		device.obf.headers.init = temp.headers.init
		device.obf.headers.response = temp.headers.response
		device.obf.headers.cookie = temp.headers.cookie
		device.obf.headers.transport = temp.headers.transport
	}

	// ---- paddings (S1..S4) ----
	if temp.paddings.paddingSet {
		if !device.obf.headerProtectionKey.IsZero() || (temp.headerProtectionSet && !temp.headerProtectionKey.IsZero()) {
			paddings := []uint32{
				temp.paddings.init, temp.paddings.response,
				temp.paddings.cookie, temp.paddings.transport,
			}
			for i, padding := range paddings {
				if padding < HeaderCipherNonceSize {
					return ipcErrorf(ipc.IpcErrorInvalid,
						"S%d must be more then %d to use headerProtection",
						i+1, HeaderCipherNonceSize)
				}
			}
		}
		device.obf.paddings.init = temp.paddings.init
		device.obf.paddings.response = temp.paddings.response
		device.obf.paddings.cookie = temp.paddings.cookie
		device.obf.paddings.transport = temp.paddings.transport
	}

	// ---- I packets (I1..I5) ----
	if temp.ipacketsSet {
		for i := 0; i < 5; i++ {
			device.obf.ipackets[i] = temp.ipackets[i]
		}
	}

	// ---- header protection key ----
	if temp.headerProtectionSet {
		device.obf.headerProtectionKey = temp.headerProtectionKey
	}

	// ---- content padding addition ----
	if temp.contentPaddingSet {
		device.obf.contentPaddingAddition = temp.contentPaddingAddition
	}
	if temp.randomTrailersSet {
		device.obf.randomTrailers = temp.randomTrailers
	}
	if temp.disableCookiesSet {
		device.obf.disableCookies = temp.disableCookies
	}

	// ---- timings ----
	if temp.timings.set {
		device.obf.timings.rekeyAfterTimeSec = temp.timings.rekeyAfterTimeSec
		device.obf.timings.rekeyTimeoutSec = temp.timings.rekeyTimeoutSec
		device.obf.timings.rejectAfterTimeSec = temp.timings.rejectAfterTimeSec
		device.obf.timings.keepaliveTimeoutSec = temp.timings.keepaliveTimeoutSec
		device.obf.timings.maxHandshakeAttemps = temp.timings.maxHandshakeAttemps
	}

	return nil
}

// ---- accessors used by the hot paths (all take aSecMux.RLock) ------------

func (device *Device) HeaderProtectionCipher(salt []byte) (*chacha20.Cipher, error) {
	device.aSecMux.RLock()
	defer device.aSecMux.RUnlock()

	if device.obf.headerProtectionKey.IsZero() {
		return nil, nil
	}

	return chacha20.NewUnauthenticatedCipher(device.obf.headerProtectionKey[:], salt)
}

// junkPackets returns the Jc random junk datagrams sent before a handshake
// initiation.
func (device *Device) junkPackets() [][]byte {
	device.aSecMux.RLock()
	count := device.obf.junk.count
	min := device.obf.junk.min
	max := device.obf.junk.max
	device.aSecMux.RUnlock()

	if count <= 0 {
		return nil
	}

	bufs := make([][]byte, 0, count)
	for i := 0; i < count; i++ {
		buf := make([]byte, min+int(fastrandn(uint32(max-min))))
		crand.Read(buf)
		bufs = append(bufs, buf)
	}
	return bufs
}

// randomPaddingAddition picks a ContentPaddingAddition value, clamped so the
// padded packet stays within the peer MTU; -1 when the feature is unused
// (the caller then falls back to 16-byte alignment padding).
func (device *Device) randomPaddingAddition(packetSize, mtu int) int {
	device.aSecMux.RLock()
	addition := device.obf.contentPaddingAddition
	device.aSecMux.RUnlock()

	if addition.IsZero() {
		return -1
	}

	add := int(addition.PickOne())
	if mtu != 0 {
		if packetSize > mtu {
			packetSize %= mtu
		}

		space := mtu - packetSize
		if add > space {
			add = space
		}
	}
	return add
}

func (device *Device) randomTrailer(packetSize int) int {
	device.aSecMux.RLock()
	enabled := device.obf.randomTrailers
	device.aSecMux.RUnlock()
	if !enabled {
		return -1
	}
	if DefaultUdpWindow < packetSize {
		return 0
	}
	return int(fastrandn(uint32(DefaultUdpWindow - packetSize)))
}

func (peer *Peer) randomTrailer(packetSize int) int {
	peer.device.aSecMux.RLock()
	enabled := peer.device.obf.randomTrailers
	peer.device.aSecMux.RUnlock()
	if !enabled {
		return -1
	}
	udpWindow := int(atomic.LoadUint32(&peer.udpWindow))
	if udpWindow < packetSize {
		return 0
	}
	return int(fastrandn(uint32(udpWindow - packetSize)))
}

// calculatePaddingSize pads the packet to a multiple of PaddingMultiple,
// wrapped at the MTU (vanilla WireGuard behavior).
func calculatePaddingSize(packetSize, mtu int) int {
	lastUnit := packetSize
	if mtu == 0 {
		return ((lastUnit + PaddingMultiple - 1) & ^(PaddingMultiple - 1)) - lastUnit
	}
	if lastUnit > mtu {
		lastUnit %= mtu
	}
	paddedSize := ((lastUnit + PaddingMultiple - 1) & ^(PaddingMultiple - 1))
	if paddedSize > mtu {
		paddedSize = mtu
	}
	return paddedSize - lastUnit
}

// applyHash XORs the keystream prefix into the (still encrypted) type word.
func applyHash(dst, src, hash []byte) {
	for i := range dst {
		dst[i] = src[i] ^ hash[i]
	}
}

// determinePacketTypeAndPadding classifies a datagram by total size + magic
// header range (AWG 3.0 receive logic, ported verbatim from upstream).
// typeHash must be the first 4 keystream bytes of the header cipher (zeros
// when header protection is off).
func (device *Device) determinePacketTypeAndPadding(packet []byte, expectedType uint32, typeHash []byte) (uint32, uint32) {
	var headerBytes [4]byte
	size := len(packet)

	device.aSecMux.RLock()
	paddingsInit := device.obf.paddings.init
	paddingsResponse := device.obf.paddings.response
	paddingsCookie := device.obf.paddings.cookie
	paddingsTransport := device.obf.paddings.transport
	headersInit := device.obf.headers.init
	headersResponse := device.obf.headers.response
	headersCookie := device.obf.headers.cookie
	headersTransport := device.obf.headers.transport
	randomTrailers := device.obf.randomTrailers
	device.aSecMux.RUnlock()

	if expectedType == MessageUnknownType || expectedType == MessageInitiationType {
		padding := paddingsInit
		expectedSize := int(padding) + MessageInitiationSize
		if size == expectedSize || (randomTrailers && size > expectedSize) {
			applyHash(headerBytes[:], packet[padding:padding+4], typeHash)
			if headersInit.Contains(littleEndianUint32(headerBytes[:])) {
				return MessageInitiationType, padding
			}
		}
	}

	if expectedType == MessageUnknownType || expectedType == MessageResponseType {
		padding := paddingsResponse
		expectedSize := int(padding) + MessageResponseSize
		if size == expectedSize || (randomTrailers && size > expectedSize) {
			applyHash(headerBytes[:], packet[padding:padding+4], typeHash)
			if headersResponse.Contains(littleEndianUint32(headerBytes[:])) {
				return MessageResponseType, padding
			}
		}
	}

	if expectedType == MessageUnknownType || expectedType == MessageCookieReplyType {
		padding := paddingsCookie
		expectedSize := int(padding) + MessageCookieReplySize
		if size == expectedSize || (randomTrailers && size > expectedSize) {
			applyHash(headerBytes[:], packet[padding:padding+4], typeHash)
			if headersCookie.Contains(littleEndianUint32(headerBytes[:])) {
				return MessageCookieReplyType, padding
			}
		}
	}

	if expectedType == MessageUnknownType || expectedType == MessageTransportType {
		padding := paddingsTransport
		if size >= int(padding)+MessageTransportHeaderSize {
			applyHash(headerBytes[:], packet[padding:padding+4], typeHash)
			if headersTransport.Contains(littleEndianUint32(headerBytes[:])) {
				return MessageTransportType, padding
			}
		}
	}

	return MessageUnknownType, 0
}

func littleEndianUint32(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}

// ---- timing overrides ------------------------------------------------------

func (device *Device) retransmitHandshakeTimeout() (time.Duration, bool) {
	device.aSecMux.RLock()
	t := device.obf.timings.rekeyTimeoutSec
	device.aSecMux.RUnlock()
	if t.IsZero() {
		return RekeyTimeout, false
	}
	return time.Duration(t.PickOne()) * time.Second, true
}

func (device *Device) sendKeepaliveTimeout() time.Duration {
	device.aSecMux.RLock()
	t := device.obf.timings.keepaliveTimeoutSec
	device.aSecMux.RUnlock()
	if t.IsZero() {
		return KeepaliveTimeout
	}
	return time.Duration(t.PickOne()) * time.Second
}

func (device *Device) newHandshakeTimeout() (keepalive, rekey time.Duration) {
	device.aSecMux.RLock()
	kt := device.obf.timings.keepaliveTimeoutSec
	rt := device.obf.timings.rekeyTimeoutSec
	device.aSecMux.RUnlock()

	keepalive = KeepaliveTimeout
	rekey = RekeyTimeout
	if !kt.IsZero() {
		keepalive = time.Duration(kt.Hi()) * time.Second
	}
	if !rt.IsZero() {
		rekey = time.Duration(rt.PickOne()) * time.Second
	}
	return
}

func (device *Device) keyRefreshTimeoutSending() time.Duration {
	device.aSecMux.RLock()
	t := device.obf.timings.rekeyAfterTimeSec
	device.aSecMux.RUnlock()
	if t.IsZero() {
		return RekeyAfterTime
	}
	return time.Duration(t.PickOne()) * time.Second
}

func (device *Device) keychainExpireTime() time.Duration {
	device.aSecMux.RLock()
	t := device.obf.timings.rejectAfterTimeSec
	device.aSecMux.RUnlock()
	if t.IsZero() {
		return RejectAfterTime
	}
	return time.Duration(t.Hi()) * time.Second
}

func (device *Device) rekeyMinTimeout() time.Duration {
	device.aSecMux.RLock()
	t := device.obf.timings.rekeyTimeoutSec
	device.aSecMux.RUnlock()
	if t.IsZero() {
		return RekeyTimeout
	}
	return time.Duration(t.Lo()) * time.Second
}

func (device *Device) maxHandshakeAttemps() uint32 {
	device.aSecMux.RLock()
	t := device.obf.timings.maxHandshakeAttemps
	device.aSecMux.RUnlock()
	if t.IsZero() {
		return MaxTimerHandshakes
	}
	return t.PickOne()
}
