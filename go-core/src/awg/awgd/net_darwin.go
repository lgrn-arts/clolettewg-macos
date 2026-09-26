/* SPDX-License-Identifier: MIT
 *
 * net_darwin.go — macOS network configuration for awgd (Mavericks port).
 *
 * Performs the same steps as wg-quick(8) on Darwin, using the standard
 * command line tools available since OS X 10.9:
 *   - utun interface comes from awg/tun (kernel control socket),
 *   - address assignment via /sbin/ifconfig,
 *   - split/full tunnel routes via /sbin/route (0/1 + 128/1 trick for
 *     the default route, endpoint host route pinned to the original
 *     gateway so the UDP session survives),
 *   - DNS via /usr/sbin/networksetup with backup/restore.
 */

package main

import (
	"fmt"
	"net"
	"strings"
	"sync"
)

const (
	ifconfigBin     = "/sbin/ifconfig"
	routeBin        = "/sbin/route"
	networksetupBin = "/usr/sbin/networksetup"
)

type netConfigurator struct {
	iface string
	log   *ringLogger

	mu           sync.Mutex
	addedRoutes  []string // routes we added (in delete order)
	gateway      string   // original default gateway
	gatewayIface string
	endpointIP   string
	dnsBackup    map[string]string // service -> original dns string ("empty" means none)
	dnsModified  []string
}

// nlog writes a routing diagnostic into the ring (awgd.log + the GUI log
// view). Routing was previously completely silent, which made "tunnel is up
// but nothing reaches the peer" impossible to diagnose from the logs.
func (n *netConfigurator) nlog(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	if n.log != nil {
		n.log.Infof("route: %s", msg)
	} else {
		fmt.Fprintf(logWriter, "awgd: route: %s\n", msg)
	}
}

// currentDefaultGateway returns (gateway IP, interface) of the live default route.
func currentDefaultGateway() (string, string) {
	out, err := runCmd(routeBin, "-n", "get", "default")
	if err != nil {
		return "", ""
	}
	var gw, iface string
	for _, ln := range strings.Split(out, "\n") {
		ln = strings.TrimSpace(ln)
		if strings.HasPrefix(ln, "gateway:") {
			gw = strings.TrimSpace(strings.TrimPrefix(ln, "gateway:"))
		}
		if strings.HasPrefix(ln, "interface:") {
			iface = strings.TrimSpace(strings.TrimPrefix(ln, "interface:"))
		}
	}
	return gw, iface
}

// hostIPForEndpoint resolves the endpoint host to an IP string.
func hostIPForEndpoint(endpoint string) string {
	host, _, err := net.SplitHostPort(endpoint)
	if err != nil {
		return ""
	}
	ip := net.ParseIP(host)
	if ip != nil {
		return ip.String()
	}
	addrs, err := net.LookupIP(host)
	if err != nil || len(addrs) == 0 {
		return ""
	}
	// prefer IPv4
	for _, a := range addrs {
		if v4 := a.To4(); v4 != nil {
			return v4.String()
		}
	}
	return addrs[0].String()
}

// bringUp assigns addresses, MTU is already set by tun.CreateTUN.
func (n *netConfigurator) bringUp(conf *Conf) error {
	n.mu.Lock()
	defer n.mu.Unlock()

	n.endpointIP = hostIPForEndpoint(conf.Endpoint)
	n.gateway, n.gatewayIface = currentDefaultGateway()

	n.nlog("tunnel %s: endpoint %s (ip %q)", n.iface, conf.Endpoint, n.endpointIP)
	if n.gateway == "" {
		// Without a gateway we cannot pin the endpoint, and the 0/1 + 128/1
		// default-route hijack below would swallow the endpoint too: the
		// handshake would go straight back into utun and never reach the
		// peer. Say so loudly instead of failing silently.
		n.nlog("WARNING: could not determine the default gateway — the "+
			"endpoint will NOT be pinned to the physical interface, and the "+
			"handshake will very likely be black-holed into %s", n.iface)
	} else {
		n.nlog("default gateway %s via %s", n.gateway, n.gatewayIface)
	}

	for _, addr := range conf.Addresses {
		ip, ipnet, err := net.ParseCIDR(addr)
		if err != nil {
			return fmt.Errorf("bad address %q: %v", addr, err)
		}
		if ip.To4() != nil {
			// Darwin convention: ifconfig utunN inet <ip> <ip> alias
			if out, err := runCmd(ifconfigBin, n.iface, "inet", ip.String(), ip.String(), "alias"); err != nil {
				return fmt.Errorf("ifconfig inet %s: %v: %s", ip, err, strings.TrimSpace(out))
			}
			_ = ipnet
		} else {
			if out, err := runCmd(ifconfigBin, n.iface, "inet6", ip.String(), "alias"); err != nil {
				return fmt.Errorf("ifconfig inet6 %s: %v: %s", ip, err, strings.TrimSpace(out))
			}
		}
	}

	// pin endpoint to the original gateway so the UDP session stays alive
	if n.endpointIP != "" && n.gateway != "" {
		out, err := runCmd(routeBin, "-n", "add", "-host", n.endpointIP, n.gateway)
		if err == nil {
			n.addedRoutes = append(n.addedRoutes, "-host "+n.endpointIP)
			n.nlog("pinned endpoint %s -> gateway %s", n.endpointIP, n.gateway)
		} else if strings.Contains(out, "File exists") {
			// A leftover route from an earlier session is NOT safe to keep:
			// it may pin the endpoint to a gateway we are no longer on (the
			// user moved networks, or the daemon was killed mid-tunnel), and
			// because DNS round-robins the endpoint the stale entry may point
			// somewhere else entirely. Replace it with a route to the
			// gateway we just detected.
			if dout, derr := runCmd(routeBin, "-n", "delete", "-host", n.endpointIP); derr != nil {
				n.nlog("WARNING: endpoint %s had a stale route we could not "+
					"remove (%s); it may be pinned to the wrong gateway",
					n.endpointIP, strings.TrimSpace(dout))
			}
			if aout, aerr := runCmd(routeBin, "-n", "add", "-host", n.endpointIP, n.gateway); aerr == nil {
				n.addedRoutes = append(n.addedRoutes, "-host "+n.endpointIP)
				n.nlog("replaced stale endpoint route %s -> %s", n.endpointIP, n.gateway)
			} else {
				n.nlog("WARNING: could not re-pin endpoint %s -> %s: %s",
					n.endpointIP, n.gateway, strings.TrimSpace(aout))
			}
		} else {
			// Not fatal for the route table, but it *is* fatal for the
			// handshake if the default-route hijack below covers the
			// endpoint, so make it visible.
			n.nlog("WARNING: failed to pin endpoint %s -> %s: %s",
				n.endpointIP, n.gateway, strings.TrimSpace(out))
		}
	}

	// routes for allowed IPs
	defaultExpanded := false
	for _, a := range conf.AllowedIPs {
		_, ipnet, err := net.ParseCIDR(a)
		if err != nil {
			continue
		}
		specs := []string{}
		if ipnet.String() == "0.0.0.0/0" {
			if !defaultExpanded {
				specs = append(specs, "0.0.0.0/1", "128.0.0.0/1")
				defaultExpanded = true
			}
		} else if ipnet.String() == "::/0" {
			continue // IPv6 default not hijacked on 10.9
		} else {
			specs = append(specs, ipnet.String())
		}
		for _, spec := range specs {
			out, err := runCmd(routeBin, "-n", "add", "-inet", spec, "-interface", n.iface)
			if err != nil {
				if strings.Contains(out, "File exists") {
					out2, err2 := runCmd(routeBin, "-n", "change", "-inet", spec, "-interface", n.iface)
					if err2 != nil {
						return fmt.Errorf("route change %s: %v: %s", spec, err2, strings.TrimSpace(out2))
					}
				} else {
					return fmt.Errorf("route add %s: %v: %s", spec, err, strings.TrimSpace(out))
				}
			}
			n.addedRoutes = append(n.addedRoutes, "-inet "+spec)
			n.nlog("added %s -> %s", spec, n.iface)
		}
	}

	// Verify where the endpoint actually goes now that the tunnel routes are
	// in place. If it resolves to the tunnel interface the handshake can never
	// leave the machine — the single most common cause of "up, no handshake".
	if n.endpointIP != "" {
		out, err := runCmd(routeBin, "-n", "get", n.endpointIP)
		if err != nil {
			n.nlog("WARNING: could not verify route to endpoint %s: %s",
				n.endpointIP, strings.TrimSpace(out))
		} else {
			iface, gw := "", ""
			for _, ln := range strings.Split(out, "\n") {
				ln = strings.TrimSpace(ln)
				if strings.HasPrefix(ln, "interface:") {
					iface = strings.TrimSpace(strings.TrimPrefix(ln, "interface:"))
				}
				if strings.HasPrefix(ln, "gateway:") {
					gw = strings.TrimSpace(strings.TrimPrefix(ln, "gateway:"))
				}
			}
			if iface == n.iface {
				n.nlog("WARNING: endpoint %s now routes via %s — the handshake "+
					"will loop back into the tunnel and never reach the peer",
					n.endpointIP, n.iface)
			} else {
				n.nlog("endpoint %s routes via %s (gw %s) — good",
					n.endpointIP, iface, gw)
			}
		}
	}

	// DNS
	if len(conf.DNS) > 0 {
		if err := n.applyDNS(conf.DNS); err != nil {
			// DNS failure should not block the tunnel
			fmt.Fprintf(logWriter, "awgd: DNS setup failed: %v\n", err)
		}
	}
	return nil
}

func (n *netConfigurator) applyDNS(dns []string) error {
	n.dnsBackup = map[string]string{}
	n.dnsModified = nil
	out, err := runCmd(networksetupBin, "-listallnetworkservices")
	if err != nil {
		return fmt.Errorf("list services: %v: %s", err, strings.TrimSpace(out))
	}
	for _, svc := range strings.Split(out, "\n")[1:] {
		svc = strings.TrimSpace(svc)
		if svc == "" || strings.HasPrefix(svc, "*") {
			continue
		}
		cur, _ := runCmd(networksetupBin, "-getdnsservers", svc)
		cur = strings.TrimSpace(cur)
		if strings.Contains(cur, "There aren't any DNS Servers set") {
			cur = "empty"
		}
		n.dnsBackup[svc] = cur

		args := append([]string{"-setdnsservers", svc}, dns...)
		if _, err := runCmd(networksetupBin, args...); err != nil {
			continue // services without IP config reject this; fine
		}
		n.dnsModified = append(n.dnsModified, svc)
	}
	return nil
}

// bringDown undoes everything bringUp did.
func (n *netConfigurator) bringDown() {
	n.mu.Lock()
	defer n.mu.Unlock()

	// routes (reverse order)
	for i := len(n.addedRoutes) - 1; i >= 0; i-- {
		fields := strings.Fields(n.addedRoutes[i])
		if len(fields) == 0 {
			continue
		}
		args := append([]string{"-n", "delete"}, fields...)
		runCmd(routeBin, args...)
	}
	n.addedRoutes = nil

	// DNS restore
	for _, svc := range n.dnsModified {
		orig := n.dnsBackup[svc]
		var args []string
		if orig == "empty" || orig == "" {
			args = []string{"-setdnsservers", svc, "Empty"}
		} else {
			args = append([]string{"-setdnsservers", svc}, strings.Fields(orig)...)
		}
		runCmd(networksetupBin, args...)
	}
	n.dnsModified = nil
	n.dnsBackup = nil
}
