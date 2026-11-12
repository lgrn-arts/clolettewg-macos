/* SPDX-License-Identifier: MIT
 *
 * ipconst.go — Mavericks port: replaces the four golang.org/x/net/ipv4 and
 * ipv6 constants that upstream used, so the x/net dependency can be dropped
 * entirely (its newer versions need Go ≥ 1.11 runtime features on darwin).
 */

package device

const (
	ipv4Version   = 4
	ipv4HeaderLen = 20
	ipv6Version   = 6
	ipv6HeaderLen = 40
)
