/* SPDX-License-Identifier: MIT
 *
 * config.go — wg-quick style configuration parser for awgd.
 *
 * Reads the AmneziaWG / WireGuard INI-style format produced by the Amnezia
 * client ("Export tunnel to file") and converts it to the device UAPI set
 * string understood by awg/device.
 *
 * Supports both parameter generations:
 *   - classic AWG 1.x: Jc, Jmin, Jmax, S1, S2, H1..H4 (plain numbers);
 *   - AWG 1.5/3.0:     S3, S4, I1..I5 pattern specs, ranged H1..H4
 *                      ("lo-hi"), HeaderProtectionKey (base64),
 *                      ContentPaddingAddition and the timer overrides
 *                      RekeyAfterTime/RekeyTimeout/RejectAfterTime/
 *                      KeepaliveTimeout/MaxHandshakeAttempts.
 * Written for Go 1.10 (Mavericks port).
 */

package main

import (
	"encoding/hex"
	"fmt"
	"net"
	"strconv"
	"strings"
)

// Conf is a parsed tunnel configuration. Only the first [Peer] section is
// used (typical client setup); further peers produce a warning-level error
// field but do not abort.
type Conf struct {
	// [Interface]
	PrivateKey     string
	Addresses      []string
	DNS            []string
	MTU            int
	ListenPort     int
	Jc, Jmin, Jmax int
	S1, S2         int
	H1, H2, H3, H4 string // plain number or "lo-hi" range

	// AWG 1.5/3.0 additions
	S3, S4                 int
	I1, I2, I3, I4, I5     string // pattern spec, passed through to the device
	HeaderProtectionKey    string // 64-char hex (converted from base64)
	ContentPaddingAddition string
	RekeyAfterTime         string
	RekeyTimeout           string
	RejectAfterTime        string
	KeepaliveTimeout       string
	MaxHandshakeAttempts   string

	// [Peer]
	PublicKey           string
	PresharedKey        string
	AllowedIPs          []string
	Endpoint            string
	PersistentKeepalive int

	// info
	HasObfuscation bool // any classic obfuscation key present
	HasObf3        bool // any AWG 1.5/3.0-only key present
}

// parseUint32Range validates "N" or "lo-hi" with both bounds fitting in
// uint32, returning the normalized representation.
func parseUint32Range(value string) (string, error) {
	parts := strings.Split(value, "-")
	if len(parts) > 2 {
		return "", fmt.Errorf("bad range %q", value)
	}
	for _, p := range parts {
		v, err := strconv.ParseUint(strings.TrimSpace(p), 10, 32)
		if err != nil {
			return "", fmt.Errorf("bad range %q", value)
		}
		_ = v
	}
	if len(parts) == 2 {
		lo, _ := strconv.ParseUint(strings.TrimSpace(parts[0]), 10, 32)
		hi, _ := strconv.ParseUint(strings.TrimSpace(parts[1]), 10, 32)
		if lo > hi {
			return "", fmt.Errorf("bad range %q (lo > hi)", value)
		}
		return strconv.FormatUint(lo, 10) + "-" + strconv.FormatUint(hi, 10), nil
	}
	return strings.TrimSpace(parts[0]), nil
}

// ParseConf parses wg-quick style configuration text.
func ParseConf(data string) (*Conf, error) {
	conf := &Conf{MTU: 1420}
	section := ""
	sawPeer := false

	lines := strings.Split(data, "\n")
	for n, raw := range lines {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			section = strings.ToLower(strings.TrimSpace(strings.Trim(line, "[]")))
			if section == "peer" {
				if sawPeer {
					return nil, fmt.Errorf("line %d: multiple [Peer] sections are not supported in the client", n+1)
				}
				sawPeer = true
			}
			continue
		}
		eq := strings.Index(line, "=")
		if eq < 0 {
			return nil, fmt.Errorf("line %d: expected KEY = VALUE", n+1)
		}
		key := strings.ToLower(strings.TrimSpace(line[:eq]))
		value := strings.TrimSpace(line[eq+1:])
		if value == "" {
			continue
		}

		switch section {
		case "interface":
			switch key {
			case "privatekey":
				if err := checkKey32(value); err != nil {
					return nil, fmt.Errorf("line %d: PrivateKey: %v", n+1, err)
				}
				conf.PrivateKey = value
			case "address":
				for _, a := range strings.Split(value, ",") {
					a = strings.TrimSpace(a)
					if a == "" {
						continue
					}
					if _, _, err := net.ParseCIDR(a); err != nil {
						if net.ParseIP(a) == nil {
							return nil, fmt.Errorf("line %d: bad Address %q", n+1, a)
						}
						a = a + "/32"
					}
					conf.Addresses = append(conf.Addresses, a)
				}
			case "dns":
				for _, d := range strings.Split(value, ",") {
					d = strings.TrimSpace(d)
					if d != "" {
						conf.DNS = append(conf.DNS, d)
					}
				}
			case "mtu":
				v, err := strconv.Atoi(value)
				if err != nil || v < 576 || v > 65535 {
					return nil, fmt.Errorf("line %d: bad MTU %q", n+1, value)
				}
				conf.MTU = v
			case "listenport":
				v, err := strconv.Atoi(value)
				if err != nil || v < 0 || v > 65535 {
					return nil, fmt.Errorf("line %d: bad ListenPort %q", n+1, value)
				}
				conf.ListenPort = v
			case "fwmark", "table", "preup", "postup", "predown", "postdown":
				// accepted and ignored on macOS
			case "jc":
				v, err := strconv.Atoi(value)
				if err != nil || v < 0 {
					return nil, fmt.Errorf("line %d: bad Jc %q", n+1, value)
				}
				conf.Jc = v
				conf.HasObfuscation = true
			case "jmin":
				v, err := strconv.Atoi(value)
				if err != nil || v < 0 {
					return nil, fmt.Errorf("line %d: bad Jmin %q", n+1, value)
				}
				conf.Jmin = v
				conf.HasObfuscation = true
			case "jmax":
				v, err := strconv.Atoi(value)
				if err != nil || v < 0 {
					return nil, fmt.Errorf("line %d: bad Jmax %q", n+1, value)
				}
				conf.Jmax = v
				conf.HasObfuscation = true
			case "s1", "s2", "s3", "s4":
				v, err := strconv.Atoi(value)
				if err != nil || v < 0 || v > 65535 {
					return nil, fmt.Errorf("line %d: bad S-padding %q", n+1, value)
				}
				switch key {
				case "s1":
					conf.S1 = v
				case "s2":
					conf.S2 = v
				case "s3":
					conf.S3 = v
				case "s4":
					conf.S4 = v
				}
				conf.HasObfuscation = true
				if key == "s3" || key == "s4" {
					conf.HasObf3 = true
				}
			case "h1", "h2", "h3", "h4":
				norm, err := parseUint32Range(value)
				if err != nil {
					return nil, fmt.Errorf("line %d: bad %s %q", n+1, strings.ToUpper(key), value)
				}
				switch key {
				case "h1":
					conf.H1 = norm
				case "h2":
					conf.H2 = norm
				case "h3":
					conf.H3 = norm
				case "h4":
					conf.H4 = norm
				}
				conf.HasObfuscation = true
			case "i1", "i2", "i3", "i4", "i5":
				if strings.Count(value, "<") != strings.Count(value, ">") {
					return nil, fmt.Errorf("line %d: unbalanced pattern in %s", n+1, strings.ToUpper(key))
				}
				switch key {
				case "i1":
					conf.I1 = value
				case "i2":
					conf.I2 = value
				case "i3":
					conf.I3 = value
				case "i4":
					conf.I4 = value
				case "i5":
					conf.I5 = value
				}
				conf.HasObfuscation = true
				conf.HasObf3 = true
			case "headerprotectionkey":
				raw, err := base64Decode(value)
				if err != nil {
					return nil, fmt.Errorf("line %d: HeaderProtectionKey: %v", n+1, err)
				}
				if len(raw) != 32 {
					return nil, fmt.Errorf("line %d: HeaderProtectionKey must be 32 bytes, got %d", n+1, len(raw))
				}
				conf.HeaderProtectionKey = hex.EncodeToString(raw)
				conf.HasObfuscation = true
				conf.HasObf3 = true
			case "contentpaddingaddition":
				norm, err := parseUint32Range(value)
				if err != nil {
					return nil, fmt.Errorf("line %d: bad ContentPaddingAddition %q", n+1, value)
				}
				conf.ContentPaddingAddition = norm
				conf.HasObfuscation = true
				conf.HasObf3 = true
			case "rekeyaftertime":
				norm, err := parseUint32Range(value)
				if err != nil {
					return nil, fmt.Errorf("line %d: bad RekeyAfterTime %q", n+1, value)
				}
				conf.RekeyAfterTime = norm
				conf.HasObf3 = true
			case "rekeytimeout":
				norm, err := parseUint32Range(value)
				if err != nil {
					return nil, fmt.Errorf("line %d: bad RekeyTimeout %q", n+1, value)
				}
				conf.RekeyTimeout = norm
				conf.HasObf3 = true
			case "rejectaftertime":
				norm, err := parseUint32Range(value)
				if err != nil {
					return nil, fmt.Errorf("line %d: bad RejectAfterTime %q", n+1, value)
				}
				conf.RejectAfterTime = norm
				conf.HasObf3 = true
			case "keepalivetimeout":
				norm, err := parseUint32Range(value)
				if err != nil {
					return nil, fmt.Errorf("line %d: bad KeepaliveTimeout %q", n+1, value)
				}
				conf.KeepaliveTimeout = norm
				conf.HasObf3 = true
			case "maxhandshakeattempts":
				norm, err := parseUint32Range(value)
				if err != nil {
					return nil, fmt.Errorf("line %d: bad MaxHandshakeAttempts %q", n+1, value)
				}
				conf.MaxHandshakeAttempts = norm
				conf.HasObf3 = true
			default:
				return nil, fmt.Errorf("line %d: unknown [Interface] key %q", n+1, key)
			}
		case "peer":
			switch key {
			case "publickey":
				if err := checkKey32(value); err != nil {
					return nil, fmt.Errorf("line %d: PublicKey: %v", n+1, err)
				}
				conf.PublicKey = value
			case "presharedkey":
				if err := checkKey32(value); err != nil {
					return nil, fmt.Errorf("line %d: PresharedKey: %v", n+1, err)
				}
				conf.PresharedKey = value
			case "allowedips":
				for _, a := range strings.Split(value, ",") {
					a = strings.TrimSpace(a)
					if a == "" {
						continue
					}
					if _, _, err := net.ParseCIDR(a); err != nil {
						if net.ParseIP(a) == nil {
							return nil, fmt.Errorf("line %d: bad AllowedIP %q", n+1, a)
						}
						if strings.Contains(a, ":") {
							a = a + "/128"
						} else {
							a = a + "/32"
						}
					}
					conf.AllowedIPs = append(conf.AllowedIPs, a)
				}
			case "endpoint":
				if _, _, err := net.SplitHostPort(value); err != nil {
					return nil, fmt.Errorf("line %d: bad Endpoint %q", n+1, value)
				}
				conf.Endpoint = value
			case "persistentkeepalive":
				v, err := strconv.Atoi(value)
				if err != nil || v < 0 || v > 65535 {
					return nil, fmt.Errorf("line %d: bad PersistentKeepalive %q", n+1, value)
				}
				conf.PersistentKeepalive = v
			default:
				return nil, fmt.Errorf("line %d: unknown [Peer] key %q", n+1, key)
			}
		default:
			return nil, fmt.Errorf("line %d: content outside of any section", n+1)
		}
	}

	if conf.PrivateKey == "" {
		return nil, fmt.Errorf("[Interface] PrivateKey is required")
	}
	if sawPeer && conf.PublicKey == "" {
		return nil, fmt.Errorf("[Peer] PublicKey is required")
	}
	if len(conf.Addresses) == 0 {
		return nil, fmt.Errorf("[Interface] Address is required")
	}
	// duplicate header sanity for plain (non-ranged) magic headers; ranged
	// values are checked for overlap by the device itself at apply time
	if conf.HasObfuscation && conf.H1 != "" && !strings.Contains(conf.H1, "-") &&
		!strings.Contains(conf.H2, "-") && !strings.Contains(conf.H3, "-") &&
		!strings.Contains(conf.H4, "-") {
		h := map[string]bool{conf.H1: true, conf.H2: true, conf.H3: true, conf.H4: true}
		if len(h) != 4 {
			return nil, fmt.Errorf("H1..H4 magic headers must be distinct")
		}
	}
	return conf, nil
}

// b64ToHex converts a base64 wg key to the hex form the device UAPI speaks.
func b64ToHex(s string) (string, error) {
	raw, err := base64Decode(s)
	if err != nil {
		return "", err
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("key must be 32 bytes, got %d", len(raw))
	}
	return hex.EncodeToString(raw), nil
}

func checkKey32(s string) error {
	b, err := base64Decode(s)
	if err != nil {
		return err
	}
	if len(b) != 32 {
		return fmt.Errorf("key must be 32 bytes, got %d", len(b))
	}
	return nil
}

func base64Decode(s string) ([]byte, error) {
	// encoding/base64 without padding tolerance like wg tools
	s = strings.TrimSpace(s)
	for len(s)%4 != 0 {
		s += "="
	}
	return base64Std.DecodeString(s)
}

// IpcSetString renders the configuration into the UAPI set format.
func (c *Conf) IpcSetString() string {
	var b strings.Builder
	// the device UAPI speaks hex keys, the .conf file uses base64
	privHex, err := b64ToHex(c.PrivateKey)
	if err != nil {
		// unreachable for parsed configs; keep raw value so IpcSet
		// produces the device's own parse error
		privHex = c.PrivateKey
	}
	b.WriteString("private_key=" + privHex + "\n")
	if c.ListenPort > 0 {
		fmt.Fprintf(&b, "listen_port=%d\n", c.ListenPort)
	}
	if c.HasObfuscation {
		if c.Jc != 0 || c.Jmin != 0 || c.Jmax != 0 {
			fmt.Fprintf(&b, "jc=%d\njmin=%d\njmax=%d\n", c.Jc, c.Jmin, c.Jmax)
		}
		if c.S1 != 0 || c.S2 != 0 || c.HasObf3 {
			fmt.Fprintf(&b, "s1=%d\ns2=%d\n", c.S1, c.S2)
		}
		if c.HasObf3 {
			fmt.Fprintf(&b, "s3=%d\ns4=%d\n", c.S3, c.S4)
		}
		if c.H1 != "" {
			fmt.Fprintf(&b, "h1=%s\nh2=%s\nh3=%s\nh4=%s\n", c.H1, c.H2, c.H3, c.H4)
		}
		if c.I1 != "" {
			b.WriteString("i1=" + c.I1 + "\n")
		}
		if c.I2 != "" {
			b.WriteString("i2=" + c.I2 + "\n")
		}
		if c.I3 != "" {
			b.WriteString("i3=" + c.I3 + "\n")
		}
		if c.I4 != "" {
			b.WriteString("i4=" + c.I4 + "\n")
		}
		if c.I5 != "" {
			b.WriteString("i5=" + c.I5 + "\n")
		}
		if c.HeaderProtectionKey != "" {
			b.WriteString("header_protection_key=" + c.HeaderProtectionKey + "\n")
		}
		if c.ContentPaddingAddition != "" {
			b.WriteString("content_padding_addition=" + c.ContentPaddingAddition + "\n")
		}
		if c.RekeyAfterTime != "" {
			b.WriteString("rekey_after_time=" + c.RekeyAfterTime + "\n")
		}
		if c.RekeyTimeout != "" {
			b.WriteString("rekey_timeout=" + c.RekeyTimeout + "\n")
		}
		if c.RejectAfterTime != "" {
			b.WriteString("reject_after_time=" + c.RejectAfterTime + "\n")
		}
		if c.KeepaliveTimeout != "" {
			b.WriteString("keepalive_timeout=" + c.KeepaliveTimeout + "\n")
		}
		if c.MaxHandshakeAttempts != "" {
			b.WriteString("max_handshake_attempts=" + c.MaxHandshakeAttempts + "\n")
		}
	}
	if c.PublicKey != "" {
		pubHex, err := b64ToHex(c.PublicKey)
		if err != nil {
			pubHex = c.PublicKey
		}
		b.WriteString("public_key=" + pubHex + "\n")
		if c.PresharedKey != "" {
			pskHex, err := b64ToHex(c.PresharedKey)
			if err != nil {
				pskHex = c.PresharedKey
			}
			b.WriteString("preshared_key=" + pskHex + "\n")
		}
		if c.Endpoint != "" {
			b.WriteString("endpoint=" + c.Endpoint + "\n")
		}
		if c.PersistentKeepalive > 0 {
			fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", c.PersistentKeepalive)
		}
		for _, ip := range c.AllowedIPs {
			b.WriteString("allowed_ip=" + ip + "\n")
		}
	}
	b.WriteString("\n")
	return b.String()
}
