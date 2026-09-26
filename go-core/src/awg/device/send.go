/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2017-2021 WireGuard LLC. All Rights Reserved.
 */

package device

import (
	"bytes"
	crand "crypto/rand"
	"encoding/binary"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
)

/* Outbound flow
 *
 * 1. TUN queue
 * 2. Routing (sequential)
 * 3. Nonce assignment (sequential)
 * 4. Encryption (parallel)
 * 5. Transmission (sequential)
 *
 * The functions in this file occur (roughly) in the order in
 * which the packets are processed.
 *
 * Locking, Producers and Consumers
 *
 * The order of packets (per peer) must be maintained,
 * but encryption of packets happen out-of-order:
 *
 * The sequential consumers will attempt to take the lock,
 * workers release lock when they have completed work (encryption) on the packet.
 *
 * If the element is inserted into the "encryption queue",
 * the content is preceded by enough "junk" to contain the transport header
 * (to allow the construction of transport messages in-place)
 */

type QueueOutboundElement struct {
	sync.Mutex
	buffer  *[MaxMessageSize]byte // slice holding the packet data
	packet  []byte                // slice of "buffer" (always!)
	padding int                   // AmneziaWG S4 prefix length
	nonce   uint64                // nonce for encryption
	keypair *Keypair              // keypair for encryption
	peer    *Peer                 // related peer
}

func (device *Device) NewOutboundElement() *QueueOutboundElement {
	elem := device.GetOutboundElement()
	elem.buffer = device.GetMessageBuffer()
	elem.Mutex = sync.Mutex{}
	elem.nonce = 0
	device.aSecMux.RLock()
	elem.padding = int(device.obf.paddings.transport)
	device.aSecMux.RUnlock()
	// keypair and peer were cleared (if necessary) by clearPointers.
	return elem
}

// clearPointers clears elem fields that contain pointers.
// This makes the garbage collector's life easier and
// avoids accidentally keeping other objects around unnecessarily.
// It also reduces the possible collateral damage from use-after-free bugs.
func (elem *QueueOutboundElement) clearPointers() {
	elem.buffer = nil
	elem.packet = nil
	elem.keypair = nil
	elem.peer = nil
}

/* Queues a keepalive if no packets are queued for peer
 */
func (peer *Peer) SendKeepalive() {
	if len(peer.queue.staged) == 0 && peer.isRunning.Get() {
		elem := peer.device.NewOutboundElement()
		select {
		case peer.queue.staged <- elem:
			peer.device.log.Verbosef("%v - Sending keepalive packet", peer)
		default:
			peer.device.PutMessageBuffer(elem.buffer)
			peer.device.PutOutboundElement(elem)
		}
	}
	peer.SendStagedPackets()
}

func (peer *Peer) SendHandshakeInitiation(isRetry bool) error {
	if !isRetry {
		atomic.StoreUint32(&peer.timers.handshakeAttempts, 0)
	}

	peer.handshake.mutex.RLock()
	if time.Since(peer.handshake.lastSentHandshake) < peer.device.rekeyMinTimeout() {
		peer.handshake.mutex.RUnlock()
		return nil
	}
	peer.handshake.mutex.RUnlock()

	peer.handshake.mutex.Lock()
	if time.Since(peer.handshake.lastSentHandshake) < peer.device.rekeyMinTimeout() {
		peer.handshake.mutex.Unlock()
		return nil
	}
	peer.handshake.lastSentHandshake = time.Now()
	peer.handshake.mutex.Unlock()

	peer.device.log.Verbosef("%v - Sending handshake initiation", peer)

	msg, err := peer.device.CreateMessageInitiation(peer)
	if err != nil {
		peer.device.log.Errorf("%v - Failed to create initiation message: %v", peer, err)
		return err
	}

	// AmneziaWG 3.0 (Mavericks port): send I1..I5 pattern datagrams, the Jc
	// junk datagrams, then one datagram = S1 random bytes (whose first 16
	// double as the ChaCha20 nonce) + the initiation message with its header
	// XOR-encrypted by the header-protection stream. Ported from
	// amneziawg-go v3.0.3 device/send.go.

	peer.device.aSecMux.RLock()
	var ipackets [5]*obfChain
	copy(ipackets[:], peer.device.obf.ipackets[:])
	peer.device.aSecMux.RUnlock()
	for i := range ipackets {
		if ipackets[i] != nil {
			buf := make([]byte, ipackets[i].ObfuscatedLen(0))
			ipackets[i].Obfuscate(buf, nil)
			if err = peer.SendBuffer(buf); err != nil {
				peer.device.log.Errorf("%v - Failed to send I-packet: %v", peer, err)
				return err
			}
		}
	}

	for _, junk := range peer.device.junkPackets() {
		if err = peer.SendBuffer(junk); err != nil {
			peer.device.log.Errorf("%v - Failed to send junk packets: %v", peer, err)
			return err
		}
	}

	peer.device.aSecMux.RLock()
	padding := int(peer.device.obf.paddings.init)
	peer.device.aSecMux.RUnlock()

	buf := make([]byte, padding+MessageInitiationSize)
	crypt := buf[:padding]
	crand.Read(crypt)

	writer := bytes.NewBuffer(buf[padding:padding])
	binary.Write(writer, binary.LittleEndian, msg)
	packet := writer.Bytes()
	peer.cookieGenerator.AddMacs(packet)

	peer.timersAnyAuthenticatedPacketTraversal()
	peer.timersAnyAuthenticatedPacketSent()

	cip, hperr := peer.device.HeaderProtectionCipher(crypt[:HeaderCipherNonceSize])
	if hperr != nil {
		return hperr
	}
	if cip != nil {
		cip.XORKeyStream(packet, packet)
	}

	err = peer.SendBuffer(buf)
	if err != nil {
		peer.device.log.Errorf("%v - Failed to send handshake initiation: %v", peer, err)
	}
	peer.timersHandshakeInitiated()

	return err
}

func (peer *Peer) SendHandshakeResponse() error {
	peer.handshake.mutex.Lock()
	peer.handshake.lastSentHandshake = time.Now()
	peer.handshake.mutex.Unlock()

	peer.device.log.Verbosef("%v - Sending handshake response", peer)

	response, err := peer.device.CreateMessageResponse(peer)
	if err != nil {
		peer.device.log.Errorf("%v - Failed to create response message: %v", peer, err)
		return err
	}

	// AmneziaWG 3.0: S2 random prefix + header-protected response message.
	peer.device.aSecMux.RLock()
	padding := int(peer.device.obf.paddings.response)
	peer.device.aSecMux.RUnlock()

	buf := make([]byte, padding+MessageResponseSize)
	crypt := buf[:padding]
	crand.Read(crypt)

	writer := bytes.NewBuffer(buf[padding:padding])
	binary.Write(writer, binary.LittleEndian, response)
	packet := writer.Bytes()
	peer.cookieGenerator.AddMacs(packet)

	err = peer.BeginSymmetricSession()
	if err != nil {
		peer.device.log.Errorf("%v - Failed to derive keypair: %v", peer, err)
		return err
	}

	peer.timersSessionDerived()
	peer.timersAnyAuthenticatedPacketTraversal()
	peer.timersAnyAuthenticatedPacketSent()

	cip, hperr := peer.device.HeaderProtectionCipher(crypt[:HeaderCipherNonceSize])
	if hperr != nil {
		return hperr
	}
	if cip != nil {
		cip.XORKeyStream(packet, packet)
	}

	err = peer.SendBuffer(buf)
	if err != nil {
		peer.device.log.Errorf("%v - Failed to send handshake response: %v", peer, err)
	}
	return err
}

func (device *Device) SendHandshakeCookie(initiatingElem *QueueHandshakeElement) error {
	device.log.Verbosef("Sending cookie response for denied handshake message for %v", initiatingElem.endpoint.DstToString())

	sender := binary.LittleEndian.Uint32(initiatingElem.packet[4:8])

	device.aSecMux.RLock()
	msgType := device.obf.headers.cookie.PickOne()
	padding := int(device.obf.paddings.cookie)
	device.aSecMux.RUnlock()

	reply, err := device.cookieChecker.CreateReply(initiatingElem.packet, sender, initiatingElem.endpoint.DstToBytes(), msgType)
	if err != nil {
		device.log.Errorf("Failed to create cookie reply: %v", err)
		return err
	}

	buf := make([]byte, padding+MessageCookieReplySize)
	crypt := buf[:padding]
	crand.Read(crypt)

	writer := bytes.NewBuffer(buf[padding:padding])
	binary.Write(writer, binary.LittleEndian, reply)
	packet := writer.Bytes()

	cip, hperr := device.HeaderProtectionCipher(crypt[:HeaderCipherNonceSize])
	if hperr != nil {
		return hperr
	}
	if cip != nil {
		cip.XORKeyStream(packet, packet)
	}

	device.net.bind.Send(buf, initiatingElem.endpoint)
	return nil
}

func (peer *Peer) keepKeyFreshSending() {
	keypair := peer.keypairs.Current()
	if keypair == nil {
		return
	}
	nonce := atomic.LoadUint64(&keypair.sendNonce)
	if nonce > RekeyAfterMessages || (keypair.isInitiator && time.Since(keypair.created) > peer.device.keyRefreshTimeoutSending()) {
		peer.SendHandshakeInitiation(false)
	}
}

/* Reads packets from the TUN and inserts
 * into staged queue for peer
 *
 * Obs. Single instance per TUN device
 */
func (device *Device) RoutineReadFromTUN() {
	defer func() {
		device.log.Verbosef("Routine: TUN reader - stopped")
		device.state.stopping.Done()
		device.queue.encryption.wg.Done()
	}()

	device.log.Verbosef("Routine: TUN reader - started")

	var elem *QueueOutboundElement

	for {
		if elem != nil {
			device.PutMessageBuffer(elem.buffer)
			device.PutOutboundElement(elem)
		}
		elem = device.NewOutboundElement()

		// read packet at the fixed classic offset; the AmneziaWG S4
		// transport padding is prepended later by the encryption workers
		// (reading at a config-dependent offset would race with a config
		// change while this goroutine blocks inside Read).

		offset := MessageTransportHeaderSize
		size, err := device.tun.device.Read(elem.buffer[:], offset)

		if err != nil {
			// A TUN read that reports "try again" is not a failure: it just
			// means no packet is queued right now. Yield briefly and keep
			// reading. Treating EAGAIN as fatal used to tear the whole device
			// down moments after a tunnel came up, before any handshake
			// response could arrive.
			if errIsTemporary(err) {
				device.PutMessageBuffer(elem.buffer)
				device.PutOutboundElement(elem)
				elem = nil // already released; do not free it twice below
				time.Sleep(time.Millisecond)
				continue
			}
			if !device.isClosed() {
				if !errIsFileClosed(err) {
					device.log.Errorf("Failed to read packet from TUN device: %v", err)
				}
				go device.Close()
			}
			device.PutMessageBuffer(elem.buffer)
			device.PutOutboundElement(elem)
			return
		}

		if size == 0 || size > MaxContentSize {
			continue
		}

		elem.packet = elem.buffer[offset : offset+size]
		device.aSecMux.RLock()
		elem.padding = int(device.obf.paddings.transport)
		device.aSecMux.RUnlock()

		// lookup peer

		var peer *Peer
		switch elem.packet[0] >> 4 {
		case ipv4Version:
			if len(elem.packet) < ipv4HeaderLen {
				continue
			}
			dst := elem.packet[IPv4offsetDst : IPv4offsetDst+net.IPv4len]
			peer = device.allowedips.Lookup(dst)

		case ipv6Version:
			if len(elem.packet) < ipv6HeaderLen {
				continue
			}
			dst := elem.packet[IPv6offsetDst : IPv6offsetDst+net.IPv6len]
			peer = device.allowedips.Lookup(dst)

		default:
			device.log.Verbosef("Received packet with unknown IP version")
		}

		if peer == nil {
			continue
		}
		if peer.isRunning.Get() {
			peer.StagePacket(elem)
			elem = nil
			peer.SendStagedPackets()
		}
	}
}

func (peer *Peer) StagePacket(elem *QueueOutboundElement) {
	for {
		select {
		case peer.queue.staged <- elem:
			return
		default:
		}
		select {
		case tooOld := <-peer.queue.staged:
			peer.device.PutMessageBuffer(tooOld.buffer)
			peer.device.PutOutboundElement(tooOld)
		default:
		}
	}
}

func (peer *Peer) SendStagedPackets() {
top:
	if len(peer.queue.staged) == 0 || !peer.device.isUp() {
		return
	}

	keypair := peer.keypairs.Current()
	if keypair == nil || atomic.LoadUint64(&keypair.sendNonce) >= RejectAfterMessages || time.Since(keypair.created) >= RejectAfterTime {
		peer.SendHandshakeInitiation(false)
		return
	}

	for {
		select {
		case elem := <-peer.queue.staged:
			elem.peer = peer
			elem.nonce = atomic.AddUint64(&keypair.sendNonce, 1) - 1
			if elem.nonce >= RejectAfterMessages {
				atomic.StoreUint64(&keypair.sendNonce, RejectAfterMessages)
				peer.StagePacket(elem) // XXX: Out of order, but we can't front-load go chans
				goto top
			}

			elem.keypair = keypair
			elem.Lock()

			// add to parallel and sequential queue
			if peer.isRunning.Get() {
				peer.queue.outbound.c <- elem
				peer.device.queue.encryption.c <- elem
			} else {
				peer.device.PutMessageBuffer(elem.buffer)
				peer.device.PutOutboundElement(elem)
			}
		default:
			return
		}
	}
}

func (peer *Peer) FlushStagedPackets() {
	for {
		select {
		case elem := <-peer.queue.staged:
			peer.device.PutMessageBuffer(elem.buffer)
			peer.device.PutOutboundElement(elem)
		default:
			return
		}
	}
}

/* Encrypts the elements in the queue
 * and marks them for sequential consumption (by releasing the mutex)
 *
 * Obs. One instance per core
 */
func (device *Device) RoutineEncryption(id int) {
	var paddingZeros [2048]byte
	var nonce [chacha20poly1305.NonceSize]byte

	defer device.log.Verbosef("Routine: encryption worker %d - stopped", id)
	device.log.Verbosef("Routine: encryption worker %d - started", id)

	for elem := range device.queue.encryption.c {
		// Shift the packet content past the S4 prefix + header so the
		// whole frame stays inside elem.buffer (elem.packet must always
		// alias elem.buffer: the receiver reuses the same layout and the
		// Seal below must not partially overlap its destination).
		// This must happen before the crypt/header writes below.
		if len(elem.packet) > 0 && elem.padding > 0 {
			copy(
				elem.buffer[elem.padding+MessageTransportHeaderSize:],
				elem.packet,
			)
			elem.packet = elem.buffer[elem.padding+MessageTransportHeaderSize : elem.padding+MessageTransportHeaderSize+len(elem.packet)]
		} else if elem.packet == nil {
			// keepalive: empty slice that still aliases the buffer
			elem.packet = elem.buffer[elem.padding+MessageTransportHeaderSize : elem.padding+MessageTransportHeaderSize]
		}

		// AmneziaWG 3.0: fill the crypto padding (S4) — its first 16 bytes
		// become the header-protection nonce.
		crypt := elem.buffer[:elem.padding]
		crand.Read(crypt)

		// populate header fields
		header := elem.buffer[elem.padding : elem.padding+MessageTransportHeaderSize]

		fieldType := header[0:4]
		fieldReceiver := header[4:8]
		fieldNonce := header[8:16]

		device.aSecMux.RLock()
		magicHeader := device.obf.headers.transport.PickOne()
		device.aSecMux.RUnlock()
		binary.LittleEndian.PutUint32(fieldType, magicHeader)
		binary.LittleEndian.PutUint32(fieldReceiver, elem.keypair.remoteIndex)
		binary.LittleEndian.PutUint64(fieldNonce, elem.nonce)

		// content padding: ContentPaddingAddition if configured, otherwise
		// pad to a multiple of 16 (vanilla WireGuard)
		mtu := int(atomic.LoadInt32(&device.tun.mtu))
		paddingSize := device.randomPaddingAddition(len(elem.packet), mtu)
		if paddingSize < 0 {
			paddingSize = calculatePaddingSize(len(elem.packet), mtu)
		}
		avail := len(elem.buffer) - elem.padding - MessageTransportHeaderSize - len(elem.packet)
		if paddingSize > avail {
			paddingSize = avail
		}
		if paddingSize > 0 {
			if paddingSize > len(paddingZeros) {
				paddingSize = len(paddingZeros)
			}
			oldLen := len(elem.packet)
			elem.packet = elem.packet[:oldLen+paddingSize]
			copy(elem.packet[oldLen:], paddingZeros[:paddingSize])
		}

		// encrypt content and release to consumer

		binary.LittleEndian.PutUint64(nonce[4:], elem.nonce)
		elem.packet = elem.keypair.send.Seal(
			elem.buffer[:elem.padding+MessageTransportHeaderSize],
			nonce[:],
			elem.packet,
			nil,
		)

		cip, hperr := device.HeaderProtectionCipher(crypt[:HeaderCipherNonceSize])
		if hperr != nil {
			device.log.Errorf("Routing: header obfuscation failed - packet dropped")
			elem.packet = nil
			elem.Unlock()
			continue
		}
		if cip != nil {
			cip.XORKeyStream(header, header)
		}
		elem.Unlock()
	}
}

/* Sequentially reads packets from queue and sends to endpoint
 *
 * Obs. Single instance per peer.
 * The routine terminates then the outbound queue is closed.
 */
func (peer *Peer) RoutineSequentialSender() {
	device := peer.device
	defer func() {
		defer device.log.Verbosef("%v - Routine: sequential sender - stopped", peer)
		peer.stopping.Done()
	}()
	device.log.Verbosef("%v - Routine: sequential sender - started", peer)

	for elem := range peer.queue.outbound.c {
		if elem == nil {
			return
		}
		elem.Lock()
		if !peer.isRunning.Get() {
			// peer has been stopped; return re-usable elems to the shared pool.
			// This is an optimization only. It is possible for the peer to be stopped
			// immediately after this check, in which case, elem will get processed.
			// The timers and SendBuffer code are resilient to a few stragglers.
			// TODO: rework peer shutdown order to ensure
			// that we never accidentally keep timers alive longer than necessary.
			device.PutMessageBuffer(elem.buffer)
			device.PutOutboundElement(elem)
			continue
		}

		peer.timersAnyAuthenticatedPacketTraversal()
		peer.timersAnyAuthenticatedPacketSent()

		// send message and return buffer to pool

		err := peer.SendBuffer(elem.packet)
		if len(elem.packet) != MessageKeepaliveSize {
			peer.timersDataSent()
		}
		device.PutMessageBuffer(elem.buffer)
		device.PutOutboundElement(elem)
		if err != nil {
			device.log.Errorf("%v - Failed to send data packet: %v", peer, err)
			continue
		}

		peer.keepKeyFreshSending()
	}
}
