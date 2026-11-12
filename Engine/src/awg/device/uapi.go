/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2017-2021 WireGuard LLC. All Rights Reserved.
 */

package device

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"awg/ipc"
)

type IPCError struct {
	code int64 // error code
	err  error // underlying/wrapped error
}

func (s IPCError) Error() string {
	return fmt.Sprintf("IPC error %d: %v", s.code, s.err)
}

func (s IPCError) Unwrap() error {
	return s.err
}

func (s IPCError) ErrorCode() int64 {
	return s.code
}

func ipcErrorf(code int64, msg string, args ...interface{}) *IPCError {
	return &IPCError{code: code, err: fmt.Errorf(msg, args...)}
}

var byteBufferPool = &sync.Pool{
	New: func() interface{} { return new(bytes.Buffer) },
}

// IpcGetOperation implements the WireGuard configuration protocol "get" operation.
// See https://www.wireguard.com/xplatform/#configuration-protocol for details.
func (device *Device) IpcGetOperation(w io.Writer) error {
	device.ipcMutex.RLock()
	defer device.ipcMutex.RUnlock()

	buf := byteBufferPool.Get().(*bytes.Buffer)
	buf.Reset()
	defer byteBufferPool.Put(buf)
	sendf := func(format string, args ...interface{}) {
		fmt.Fprintf(buf, format, args...)
		buf.WriteByte('\n')
	}
	keyf := func(prefix string, key *[32]byte) {
		buf.Grow(len(key)*2 + 2 + len(prefix))
		buf.WriteString(prefix)
		buf.WriteByte('=')
		const hex = "0123456789abcdef"
		for i := 0; i < len(key); i++ {
			buf.WriteByte(hex[key[i]>>4])
			buf.WriteByte(hex[key[i]&0xf])
		}
		buf.WriteByte('\n')
	}

	func() {

		// lock required resources

		device.net.RLock()
		defer device.net.RUnlock()

		device.staticIdentity.RLock()
		defer device.staticIdentity.RUnlock()

		device.peers.RLock()
		defer device.peers.RUnlock()

		// serialize device related values

		if !device.staticIdentity.privateKey.IsZero() {
			keyf("private_key", (*[32]byte)(&device.staticIdentity.privateKey))
		}

		if device.net.port != 0 {
			sendf("listen_port=%d", device.net.port)
		}

		// AmneziaWG (Mavericks port, v3 layout): report obfuscation params.
		device.aSecMux.RLock()
		if device.obf.junk.count != 0 {
			sendf("jc=%d", device.obf.junk.count)
		}
		if device.obf.junk.min != 0 {
			sendf("jmin=%d", device.obf.junk.min)
		}
		if device.obf.junk.max != 0 {
			sendf("jmax=%d", device.obf.junk.max)
		}
		if device.obf.paddings.init != 0 {
			sendf("s1=%d", device.obf.paddings.init)
		}
		if device.obf.paddings.response != 0 {
			sendf("s2=%d", device.obf.paddings.response)
		}
		if device.obf.paddings.cookie != 0 {
			sendf("s3=%d", device.obf.paddings.cookie)
		}
		if device.obf.paddings.transport != 0 {
			sendf("s4=%d", device.obf.paddings.transport)
		}
		if !device.obf.headers.init.IsZero() {
			sendf("h1=%s", device.obf.headers.init.ToString())
		}
		if !device.obf.headers.response.IsZero() {
			sendf("h2=%s", device.obf.headers.response.ToString())
		}
		if !device.obf.headers.cookie.IsZero() {
			sendf("h3=%s", device.obf.headers.cookie.ToString())
		}
		if !device.obf.headers.transport.IsZero() {
			sendf("h4=%s", device.obf.headers.transport.ToString())
		}
		for i := 0; i < 5; i++ {
			if device.obf.ipackets[i] != nil {
				sendf("i%d=%s", i+1, device.obf.ipackets[i].Spec)
			}
		}
		if !device.obf.headerProtectionKey.IsZero() {
			sendf("header_protection_key=%s", device.obf.headerProtectionKey.ToHex())
		}
		if !device.obf.contentPaddingAddition.IsZero() {
			sendf("content_padding_addition=%s", device.obf.contentPaddingAddition.ToString())
		}
		if !device.obf.timings.rekeyAfterTimeSec.IsZero() {
			sendf("rekey_after_time=%s", device.obf.timings.rekeyAfterTimeSec.ToString())
		}
		if !device.obf.timings.rekeyTimeoutSec.IsZero() {
			sendf("rekey_timeout=%s", device.obf.timings.rekeyTimeoutSec.ToString())
		}
		if !device.obf.timings.rejectAfterTimeSec.IsZero() {
			sendf("reject_after_time=%s", device.obf.timings.rejectAfterTimeSec.ToString())
		}
		if !device.obf.timings.keepaliveTimeoutSec.IsZero() {
			sendf("keepalive_timeout=%s", device.obf.timings.keepaliveTimeoutSec.ToString())
		}
		if !device.obf.timings.maxHandshakeAttemps.IsZero() {
			sendf("max_handshake_attempts=%s", device.obf.timings.maxHandshakeAttemps.ToString())
		}
		sendf("random_trailers=%t", device.obf.randomTrailers)
		sendf("disable_cookies=%t", device.obf.disableCookies)
		device.aSecMux.RUnlock()

		if device.net.fwmark != 0 {
			sendf("fwmark=%d", device.net.fwmark)
		}

		// serialize each peer state

		for _, peer := range device.peers.keyMap {
			peer.RLock()
			defer peer.RUnlock()

			keyf("public_key", (*[32]byte)(&peer.handshake.remoteStatic))
			keyf("preshared_key", (*[32]byte)(&peer.handshake.presharedKey))
			sendf("protocol_version=1")
			if peer.endpoint != nil {
				sendf("endpoint=%s", peer.endpoint.DstToString())
			}

			nano := atomic.LoadInt64(&peer.stats.lastHandshakeNano)
			secs := nano / time.Second.Nanoseconds()
			nano %= time.Second.Nanoseconds()

			sendf("last_handshake_time_sec=%d", secs)
			sendf("last_handshake_time_nsec=%d", nano)
			sendf("tx_bytes=%d", atomic.LoadUint64(&peer.stats.txBytes))
			sendf("rx_bytes=%d", atomic.LoadUint64(&peer.stats.rxBytes))
			sendf("persistent_keepalive_interval=%s", peer.persistentKeepaliveInterval.Load().ToString())

			device.allowedips.EntriesForPeer(peer, func(ip net.IP, cidr uint8) bool {
				sendf("allowed_ip=%s/%d", ip.String(), cidr)
				return true
			})
		}
	}()

	// send lines (does not require resource locks)
	if _, err := w.Write(buf.Bytes()); err != nil {
		return ipcErrorf(ipc.IpcErrorIO, "failed to write output: %v", err)
	}

	return nil
}

// IpcSetOperation implements the WireGuard configuration protocol "set" operation.
// See https://www.wireguard.com/xplatform/#configuration-protocol for details.
func (device *Device) IpcSetOperation(r io.Reader) (err error) {
	device.ipcMutex.Lock()
	defer device.ipcMutex.Unlock()

	defer func() {
		if err != nil {
			device.log.Errorf("%v", err)
		}
	}()

	peer := new(ipcSetPeer)
	deviceConfig := true

	// AmneziaWG (Mavericks port, v3 layout): obfuscation parameters are
	// collected from the device section and applied when it ends.
	tempObf := obfTemp{}

	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			// Blank line means terminate operation.
			if deviceConfig {
				if err := device.applyObfConfig(&tempObf); err != nil {
					return err
				}
			}
			return nil
		}
		parts := strings.Split(line, "=")
		if len(parts) != 2 {
			return ipcErrorf(ipc.IpcErrorProtocol, "failed to parse line %q, found %d =-separated parts, want 2", line, len(parts))
		}
		key := parts[0]
		value := parts[1]

		if key == "public_key" {
			if deviceConfig {
				deviceConfig = false
				if err := device.applyObfConfig(&tempObf); err != nil {
					return err
				}
			}
			peer.handlePostConfig()
			// Load/create the peer we are now configuring.
			err := device.handlePublicKeyLine(peer, value)
			if err != nil {
				return err
			}
			continue
		}

		var err error
		if deviceConfig {
			err = device.handleDeviceLine(key, value, &tempObf)
		} else {
			err = device.handlePeerLine(peer, key, value)
		}
		if err != nil {
			return err
		}
	}
	if err := device.applyObfConfig(&tempObf); err != nil {
		return err
	}
	peer.handlePostConfig()

	if err := scanner.Err(); err != nil {
		return ipcErrorf(ipc.IpcErrorIO, "failed to read input: %v", err)
	}
	return nil
}

func (device *Device) handleDeviceLine(key, value string, tempObf *obfTemp) error {
	switch key {
	case "private_key":
		var sk NoisePrivateKey
		err := sk.FromMaybeZeroHex(value)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to set private_key: %v", err)
		}
		device.log.Verbosef("UAPI: Updating private key")
		device.SetPrivateKey(sk)

	case "listen_port":
		port, err := strconv.ParseUint(value, 10, 16)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse listen_port: %v", err)
		}

		// update port and rebind
		device.log.Verbosef("UAPI: Updating listen port")

		device.net.Lock()
		device.net.port = uint16(port)
		device.net.Unlock()

		if err := device.BindUpdate(); err != nil {
			return ipcErrorf(ipc.IpcErrorPortInUse, "failed to set listen_port: %v", err)
		}

	case "fwmark":
		mark, err := strconv.ParseUint(value, 10, 32)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "invalid fwmark: %v", err)
		}

		device.log.Verbosef("UAPI: Updating fwmark")
		if err := device.BindSetMark(uint32(mark)); err != nil {
			return ipcErrorf(ipc.IpcErrorPortInUse, "failed to update fwmark: %v", err)
		}

	case "replace_peers":
		if value != "true" {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to set replace_peers, invalid value: %v", value)
		}
		device.log.Verbosef("UAPI: Removing all peers")
		device.RemoveAllPeers()

	// ---- AmneziaWG obfuscation (Mavericks port, v3 keys) ----

	case "jc":
		v, err := strconv.Atoi(value)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse junk_packet_count: %v", err)
		}
		device.log.Verbosef("UAPI: Updating junk_packet_count")
		tempObf.junk.count = v
		tempObf.junk.junkSet = true
		tempObf.isSet = true

	case "jmin":
		v, err := strconv.Atoi(value)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse junk_packet_min_size: %v", err)
		}
		device.log.Verbosef("UAPI: Updating junk_packet_min_size")
		tempObf.junk.min = v
		tempObf.junk.junkSet = true
		tempObf.isSet = true

	case "jmax":
		v, err := strconv.Atoi(value)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse junk_packet_max_size: %v", err)
		}
		device.log.Verbosef("UAPI: Updating junk_packet_max_size")
		tempObf.junk.max = v
		tempObf.junk.junkSet = true
		tempObf.isSet = true

	case "s1":
		v, err := strconv.ParseUint(value, 10, 32)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse s1: %v", err)
		}
		device.log.Verbosef("UAPI: Updating s1 padding")
		tempObf.paddings.init = uint32(v)
		tempObf.paddings.paddingSet = true
		tempObf.isSet = true

	case "s2":
		v, err := strconv.ParseUint(value, 10, 32)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse s2: %v", err)
		}
		device.log.Verbosef("UAPI: Updating s2 padding")
		tempObf.paddings.response = uint32(v)
		tempObf.paddings.paddingSet = true
		tempObf.isSet = true

	case "s3":
		v, err := strconv.ParseUint(value, 10, 32)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse s3: %v", err)
		}
		device.log.Verbosef("UAPI: Updating s3 padding")
		tempObf.paddings.cookie = uint32(v)
		tempObf.paddings.paddingSet = true
		tempObf.isSet = true

	case "s4":
		v, err := strconv.ParseUint(value, 10, 32)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse s4: %v", err)
		}
		device.log.Verbosef("UAPI: Updating s4 padding")
		tempObf.paddings.transport = uint32(v)
		tempObf.paddings.paddingSet = true
		tempObf.isSet = true

	case "h1":
		var rang UintRange
		if err := rang.FromString(value); err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse H1: %v", err)
		}
		device.log.Verbosef("UAPI: Updating h1 header")
		tempObf.headers.init = rang
		tempObf.headers.headerSet = true
		tempObf.isSet = true

	case "h2":
		var rang UintRange
		if err := rang.FromString(value); err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse H2: %v", err)
		}
		device.log.Verbosef("UAPI: Updating h2 header")
		tempObf.headers.response = rang
		tempObf.headers.headerSet = true
		tempObf.isSet = true

	case "h3":
		var rang UintRange
		if err := rang.FromString(value); err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse H3: %v", err)
		}
		device.log.Verbosef("UAPI: Updating h3 header")
		tempObf.headers.cookie = rang
		tempObf.headers.headerSet = true
		tempObf.isSet = true

	case "h4":
		var rang UintRange
		if err := rang.FromString(value); err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse H4: %v", err)
		}
		device.log.Verbosef("UAPI: Updating h4 header")
		tempObf.headers.transport = rang
		tempObf.headers.headerSet = true
		tempObf.isSet = true

	case "i1", "i2", "i3", "i4", "i5":
		chain, err := newObfChain(value)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse %s: %v", key, err)
		}
		device.log.Verbosef("UAPI: Updating %s", key)
		idx := int(key[1] - '1')
		tempObf.ipackets[idx] = chain
		tempObf.ipacketsSet = true
		tempObf.isSet = true

	case "header_protection_key":
		var hpk HeaderCipherKey
		if err := hpk.FromHex(value); err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to set header_protection_key: %v", err)
		}
		device.log.Verbosef("UAPI: Updating header protection key")
		tempObf.headerProtectionKey = hpk
		tempObf.headerProtectionSet = true
		tempObf.isSet = true

	case "content_padding_addition":
		var rang UintRange
		if err := rang.FromString(value); err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse content_padding_addition: %v", err)
		}
		device.log.Verbosef("UAPI: Updating content_padding_addition")
		tempObf.contentPaddingAddition = rang
		tempObf.contentPaddingSet = true
		tempObf.isSet = true

	case "rekey_after_time":
		var rang UintRange
		if err := rang.FromString(value); err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse rekey_after_time: %v", err)
		}
		tempObf.timings.rekeyAfterTimeSec = rang
		tempObf.timings.set = true
		tempObf.isSet = true

	case "rekey_timeout":
		var rang UintRange
		if err := rang.FromString(value); err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse rekey_timeout: %v", err)
		}
		tempObf.timings.rekeyTimeoutSec = rang
		tempObf.timings.set = true
		tempObf.isSet = true

	case "reject_after_time":
		var rang UintRange
		if err := rang.FromString(value); err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse reject_after_time: %v", err)
		}
		tempObf.timings.rejectAfterTimeSec = rang
		tempObf.timings.set = true
		tempObf.isSet = true

	case "keepalive_timeout":
		var rang UintRange
		if err := rang.FromString(value); err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse keepalive_timeout: %v", err)
		}
		tempObf.timings.keepaliveTimeoutSec = rang
		tempObf.timings.set = true
		tempObf.isSet = true

	case "random_trailers":
		val, err := strconv.ParseBool(value)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse random trailers: %v", err)
		}
		tempObf.randomTrailers = val
		tempObf.randomTrailersSet = true
		tempObf.isSet = true

	case "disable_cookies":
		val, err := strconv.ParseBool(value)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse disable cookies: %v", err)
		}
		tempObf.disableCookies = val
		tempObf.disableCookiesSet = true
		tempObf.isSet = true

	case "max_handshake_attempts":
		var rang UintRange
		if err := rang.FromString(value); err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to parse max_handshake_attempts: %v", err)
		}
		tempObf.timings.maxHandshakeAttemps = rang
		tempObf.timings.set = true
		tempObf.isSet = true

	default:
		return ipcErrorf(ipc.IpcErrorInvalid, "invalid UAPI device key: %v", key)
	}

	return nil
}

// An ipcSetPeer is the current state of an IPC set operation on a peer.
type ipcSetPeer struct {
	*Peer        // Peer is the current peer being operated on
	dummy   bool // dummy reports whether this peer is a temporary, placeholder peer
	created bool // new reports whether this is a newly created peer
}

func (peer *ipcSetPeer) handlePostConfig() {
	if peer.Peer != nil && !peer.dummy && peer.Peer.device.isUp() {
		peer.SendStagedPackets()
	}
}

func (device *Device) handlePublicKeyLine(peer *ipcSetPeer, value string) error {
	// Load/create the peer we are configuring.
	var publicKey NoisePublicKey
	err := publicKey.FromHex(value)
	if err != nil {
		return ipcErrorf(ipc.IpcErrorInvalid, "failed to get peer by public key: %v", err)
	}

	// Ignore peer with the same public key as this device.
	device.staticIdentity.RLock()
	peer.dummy = device.staticIdentity.publicKey.Equals(publicKey)
	device.staticIdentity.RUnlock()

	if peer.dummy {
		peer.Peer = &Peer{}
	} else {
		peer.Peer = device.LookupPeer(publicKey)
	}

	peer.created = peer.Peer == nil
	if peer.created {
		peer.Peer, err = device.NewPeer(publicKey)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to create new peer: %v", err)
		}
		device.log.Verbosef("%v - UAPI: Created", peer.Peer)
	}
	return nil
}

func (device *Device) handlePeerLine(peer *ipcSetPeer, key, value string) error {
	switch key {
	case "update_only":
		// allow disabling of creation
		if value != "true" {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to set update only, invalid value: %v", value)
		}
		if peer.created && !peer.dummy {
			device.RemovePeer(peer.handshake.remoteStatic)
			peer.Peer = &Peer{}
			peer.dummy = true
		}

	case "remove":
		// remove currently selected peer from device
		if value != "true" {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to set remove, invalid value: %v", value)
		}
		if !peer.dummy {
			device.log.Verbosef("%v - UAPI: Removing", peer.Peer)
			device.RemovePeer(peer.handshake.remoteStatic)
		}
		peer.Peer = &Peer{}
		peer.dummy = true

	case "preshared_key":
		device.log.Verbosef("%v - UAPI: Updating preshared key", peer.Peer)

		peer.handshake.mutex.Lock()
		err := peer.handshake.presharedKey.FromHex(value)
		peer.handshake.mutex.Unlock()

		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to set preshared key: %v", err)
		}

	case "endpoint":
		device.log.Verbosef("%v - UAPI: Updating endpoint", peer.Peer)
		endpoint, err := device.net.bind.ParseEndpoint(value)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to set endpoint %v: %v", value, err)
		}
		peer.Lock()
		defer peer.Unlock()
		peer.endpoint = endpoint

	case "persistent_keepalive_interval":
		device.log.Verbosef("%v - UAPI: Updating persistent keepalive interval", peer.Peer)

		var rang UintRange
		if err := rang.FromString(value); err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to set persistent keepalive interval: %v", err)
		}

		old := peer.persistentKeepaliveInterval.Load()
		peer.persistentKeepaliveInterval.Store(rang)

		// Send immediate keepalive if we're turning it on and before it wasn't on.
		if old.IsZero() && !rang.IsZero() {
			if device.isUp() && !peer.dummy {
				peer.SendKeepalive()
			}
		}

	case "replace_allowed_ips":
		device.log.Verbosef("%v - UAPI: Removing all allowedips", peer.Peer)
		if value != "true" {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to replace allowedips, invalid value: %v", value)
		}
		if peer.dummy {
			return nil
		}
		device.allowedips.RemoveByPeer(peer.Peer)

	case "allowed_ip":
		device.log.Verbosef("%v - UAPI: Adding allowedip", peer.Peer)

		_, network, err := net.ParseCIDR(value)
		if err != nil {
			return ipcErrorf(ipc.IpcErrorInvalid, "failed to set allowed ip: %v", err)
		}
		if peer.dummy {
			return nil
		}
		ones, _ := network.Mask.Size()
		device.allowedips.Insert(network.IP, uint8(ones), peer.Peer)

	case "protocol_version":
		if value != "1" {
			return ipcErrorf(ipc.IpcErrorInvalid, "invalid protocol version: %v", value)
		}

	default:
		return ipcErrorf(ipc.IpcErrorInvalid, "invalid UAPI peer key: %v", key)
	}

	return nil
}

func (device *Device) IpcGet() (string, error) {
	buf := new(strings.Builder)
	if err := device.IpcGetOperation(buf); err != nil {
		return "", err
	}
	return buf.String(), nil
}

func (device *Device) IpcSet(uapiConf string) error {
	return device.IpcSetOperation(strings.NewReader(uapiConf))
}

func (device *Device) IpcHandle(socket net.Conn) {
	defer socket.Close()

	buffered := func(s io.ReadWriter) *bufio.ReadWriter {
		reader := bufio.NewReader(s)
		writer := bufio.NewWriter(s)
		return bufio.NewReadWriter(reader, writer)
	}(socket)

	for {
		op, err := buffered.ReadString('\n')
		if err != nil {
			return
		}

		// handle operation
		switch op {
		case "set=1\n":
			err = device.IpcSetOperation(buffered.Reader)
		case "get=1\n":
			var nextByte byte
			nextByte, err = buffered.ReadByte()
			if err != nil {
				return
			}
			if nextByte != '\n' {
				err = ipcErrorf(ipc.IpcErrorInvalid, "trailing character in UAPI get: %q", nextByte)
				break
			}
			err = device.IpcGetOperation(buffered.Writer)
		default:
			device.log.Errorf("invalid UAPI operation: %v", op)
			return
		}

		// write status
		// Mavericks port: errors.As requires Go 1.13. ipcErrorf always returns
		// *IPCError unwrapped, so a direct type assertion is equivalent here.
		var status *IPCError
		if err != nil {
			if pe, ok := err.(*IPCError); ok {
				status = pe
			} else {
				// shouldn't happen
				status = ipcErrorf(ipc.IpcErrorUnknown, "other UAPI error: %v", err)
			}
		}
		if status != nil {
			device.log.Errorf("%v", status)
			fmt.Fprintf(buffered, "errno=%d\n\n", status.ErrorCode())
		} else {
			fmt.Fprintf(buffered, "errno=0\n\n")
		}
		buffered.Flush()
	}
}
