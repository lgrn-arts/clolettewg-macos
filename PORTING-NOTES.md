# Porting notes — AmneziaWG onto Go 1.10 / OS X 10.9

This file documents *why* every non-obvious change was made while backporting
the AmneziaWG engine to something that actually runs on OS X 10.9.

## 1. Toolchain constraints

* Go binaries on darwin are only as old as their Go release allows:
  Go 1.11+ requires macOS 10.10+, and Go 1.13-built binaries crash on 10.9.
  **Go 1.10.8 is the last release that runs on Mavericks.**
* Go 1.10 has: modules ✗ (GOPATH mode only), `errors.Is/As` ✗, `%w` ✗,
  typed atomics ✗, `net/netip` ✗, `t.TempDir` ✗, `os.File.SyscallConn` ✗
  (1.11), `math/bits.Add64/Mul64` ✗ (1.12), `net.ErrClosed` ✗ (1.16),
  `os.ReadFile` ✗ (1.16).
* Old `// +build` lines only: Go 1.10 **ignores** `//go:build` lines —
  a file guarded only by `//go:build` is compiled *unconditionally*, so
  every such file needed a correct legacy `// +build` line added
  (space = OR, comma = AND).
  A `// +build` line may only be preceded by *line* comments — a `/* */`
  header above it silently disables the constraint (this bit `net_stub.go`).

## 2. Choosing the engine base

* `amneziawg-go v0.2.x/v3.x` are based on wireguard-go 2023+ with
  `net/netip`-based conn API, batch/GSO paths and gvisor netstack —
  all Go 1.18+ territory. Not portable without a rewrite.
* **`wireguard-go 0.0.20211016`** was chosen: the last release with the
  simple `net.IP`-based `conn` API, no netip anywhere, no cgo on darwin,
  and a single-packet tun API — ideal for Go 1.10 and easy to graft on.
* The **AmneziaWG obfuscation was grafted from `amnezia-vpn/amneziawg-go
  v0.1.8`** (device-level diff against wireguard-go `0.0.20230223`):

  | upstream file | change | where it lives here |
  |---|---|---|
  | `device/device.go` | `aSecCfgType`, `isASecOn`, `aSecMux`, `handlePostConfig`, `isAdvancedSecurityOn` | `device/obfdevice.go` (fields added to `Device` struct in `device.go`) |
  | `device/noise-protocol.go` | message-type `const` → mutable `var` + `packetSizeToMsgType`/`msgTypeToJunkSize` maps | patched in place |
  | `device/send.go` | junk datagrams before initiation; S1/S2 prefixes on init/response | patched in place (single-packet idiom) |
  | `device/receive.go` | resolve message type by total size, strip junk prefix | patched in `RoutineReceiveIncoming` |
  | `device/uapi.go` | `jc/jmin/jmax/s1/s2/h1..h4` get/set + validation call | patched in place |
  | `device/util.go` | `appendJunk`, `randomJunkWithSize` | `device/obf.go` |
  | abool dep | replaced with `sync/atomic` int32 flag | `device/obfdevice.go` |

  Differences kept faithful to upstream: junk packets are sent *before*
  the handshake initiation; `AddMacs` runs on the plain 148/92-byte message
  *before* the junk prefix is prepended around it; the receive path picks
  the type from the total datagram size (init = 148+S1, response = 92+S2)
  and falls back to the transport type check when sizes collide.

## 3. Dependency pinning

| dependency | pinned version | why |
|---|---|---|
| `golang.org/x/sys` | `v0.0.0-20190619183051-17bc6164aac4` (June 2019) | last era whose darwin port still used plain syscalls; the Oct-2021 pin needs Go 1.12+ libSystem trampolines (`zsyscall_darwin_amd64.go` is guarded `go1.12`) |
| `golang.org/x/crypto` | Oct 2021 tree, **except** `curve25519` replaced with `v0.0.0-20190308221718-c2843e01d9a2` | the 2021 curve25519 field arithmetic needs `math/bits.Add64/Mul64` (Go 1.12+); the 2019 package has the identical `*[32]byte` API the engine calls |
| `golang.org/x/net` | **dropped entirely** | only 4 constants were used (`ipv4/ipv6.HeaderLen/Version`) — now local constants in `device/ipconst.go` and `tun/ipconst_go110.go` |

## 4. Writing the missing x/sys pieces

The June-2019 x/sys predates several darwin helpers used by `tun/tun_darwin.go`;
implemented raw in `tun/utuncompat_darwin.go`:

* `CtlInfo`/`IoctlCtlInfo` → `ioctlCtlInfo()` — `CTLIOCGINFO` (`0xc0644e03`,
  `_IOWR('N', 3, struct ctl_info)`) via `SYS_IOCTL`.
* `SockaddrCtl` + `Connect` → `connectCtl()` — packed `struct sockaddr_ctl`
  passed to `SYS_CONNECT`.
* `IoctlGet/SetIfreqMTU` → `ioctlGet/SetIfreqMTU()` — `SIOCGIFMTU`/
  `SIOCSIFMTU` with a local `struct ifreq` (name[16] + int32 mtu).
* linux-only: `RTMGRP_*` group constants → `tun/netlinkconst_linux.go`,
  `device/netlinkconst_linux.go`.

`os.File.SyscallConn()` (Go 1.11+) replaced by `Fd()` in
`tun/operateonfd.go` and `tun/tun_linux.go` (safe: the utun socket is
already opened non-blocking; Fd() merely marks the file non-pollable).

## 5. Go 1.10 API shims

| shim | location | replaces |
|---|---|---|
| `errnoIs()` (unwraps `*os.PathError`, `*os.SyscallError`, `*net.OpError`, compares `syscall.Errno`) | `conn/compat_go110.go`, `tun/compat_go110.go`, `device/compat_go110.go` | `errors.Is(err, <errno>)` |
| `errIsNetClosed()` (errno/`"use of closed network connection"` string forms) | `device/compat_go110.go` | `errors.Is(err, net.ErrClosed)` |
| `errIsFileClosed()` | `device/compat_go110.go` | `errors.Is(err, os.ErrClosed)` |
| `errBindClosed` sentinel (message contains the net-package string) | `conn/compat_go110.go`, `conn/bindtest/bindtest.go` | `net.ErrClosed` returns from receive funcs |
| direct `*IPCError` type assertion | `device/uapi.go` | `errors.As` |
| `%w` → `%v` | everywhere | Go 1.13 fmt verb |
| `ioutil.WriteFile` | `tun/tun_darwin.go` | `os.WriteFile` (1.16) |

## 6. Things that were simply deleted

* Windows support (wintun, bind_windows, winpipe, winrio) — target is macOS.
* `tun/netstack` (gvisor), `tun/tuntest` kept (needed by tests).
* openbsd/freebsd tun drivers, wasm UAPI, iOS/Android queue constants.
* upstream `main.go` — replaced by the `awgd` daemon.

## 7. The AWG 1.5/3.0 generation port (from amneziawg-go v3.0.3)

After v1 shipped, a real-world AWG 3.0 profile (ranged `H1-H4`, `S3/S4`,
`I1..I3` pattern datagrams, `HeaderProtectionKey`,
`ContentPaddingAddition`, timer overrides) had to work too. The whole
obfuscation layer was replaced by a port of amneziawg-go **v3.0.3**'s
`device/obf*.go`, re-expressed for Go 1.10 (no generics, no atomics
generics, no `slices`/`maps` packages, `math/rand`-backed `fastrandn`):

* `obftypes.go` — `UintRange` (`uint64 lo|hi<<32`, config `N` or
  `lo-hi`, uniform `PickOne`), `HeaderCipherKey` (32-byte hex,
  ChaCha20 **nonce size 12**), `HeaderProtectionCipher`.
* `obfchain.go` — the `I1..I5` junk-datagram DSL: `b` literal bytes,
  `r` random run, `rc/rd/ds/dz` copy operators; `Obfuscate(nil)` emits
  the datagram.
* `obfdevice.go` — per-device obf state + config validation (header
  overlap detection, `S>=12` requirement with header protection,
  upstream's max==min bump quirk, vanilla defaults).
* `send.go`/`receive.go` — the v3 framing: datagram = `S<n>` random
  bytes (first 12 double as the HP nonce) + message; HP ON means the
  whole message (magic included) plus the transport header is
  ChaCha20-XORed; receive side classifies by total size and XORs the
  (encrypted) type word against the keystream of a zero vector.

Three Mavericks-port-specific deviations from upstream, all forced by
the older engine:

1. **TUN reads stay at the fixed classic offset 16.** Upstream reads at
   `16 + S4` and starts its TUN reader in `Up()`; this engine starts it
   in `NewDevice` (pre-config), so a config-dependent read offset would
   race the first blocking `Read` and misframe the first packet. The
   encryption workers instead shift the content up by `S4` bytes inside
   the shared 64 KiB buffer before sealing. Wire format identical.
2. **`elem.packet` must always alias `elem.buffer`** — `append` for
   content padding can silently reallocate away from the buffer and
   then `chacha20poly1305.Seal` panics on partial overlap ("invalid
   buffer overlap"). Padding is applied by re-slicing inside the buffer,
   never by `append`.
3. **Per-element (not per-batch) queues** — the 2021 engine has no
   `OutboundElementsContainer`; the port keeps its single-element
   pipeline and applies the v3 transforms per element.

The UAPI gained the v3 keys both ways (`s3/s4/i1..i5/h1..h4` ranged/
`header_protection_key` hex/`content_padding_addition` + the five
`rekey_*/reject_*/keepalive/max_handshake_attempts` overrides), and
`awgd/config.go` learned the AmneziaVPN 3.0 export format (base64
`HeaderProtectionKey` → hex, base64 wg keys → hex for UAPI — this last
one fixed a latent v1 bug where `IpcSet` was fed base64 keys).

## 8. The daemon (`awg/awgd`)

New code, written at Go 1.10 level on purpose:

* `config.go` — wg-quick-style INI parser (AWG keys included) → UAPI string.
* `net_darwin.go` — wg-quick-equivalent glue with `/sbin/ifconfig`,
  `/sbin/route` (0/1+128/1 default-route trick, endpoint host route pinned
  to the original gateway) and `networksetup` DNS swap with backup/restore.
* `service.go` — JSON-over-unix-socket IPC with token auth, single active
  tunnel, status from `dev.IpcGet()`.
* `util.go`, `main.go` — keygen (`-genkey`/`-pubkey` with RFC clamping),
  `-validate`, `-check`, ring logger.

### 8a. Service installer (`mac-app/src/HelperInstaller.m`)

The original installer used `AuthorizationExecuteWithPrivileges` to run the
install shell script. That API is deprecated since 10.7 and on 10.8/10.9 it
**sometimes returns success while never actually invoking the script** when
called from a non-Apple-signed binary — the symptom is exactly "password
prompt, then nothing happens."

The fix is to invoke `/usr/bin/osascript` (a system binary Apple trusts)
with an inline AppleScript:

    do shell script "<our shell script>" with administrator privileges

osascript then runs `/bin/sh -c <our script>` with the auth token it
acquired from the user. The script's failure (or its `awg-install: FAIL: …`
line) is captured by AppleScript's `on error` block and returned as a
string we surface verbatim in the UI. AEWP is kept as a fallback in case
osascript is unavailable.

The shell script itself was also rewritten:
* dropped `set -e` (it silently aborted on the first failed line);
* every step goes through a `run <cmd>` helper that logs `awg-install: + <cmd>`
  and exits with `awg-install: FAIL: <cmd> exited <code>` on failure;
* after writing the plist, `plutil -lint` validates it before `launchctl
  load` is called;
* after `launchctl load`, the script confirms the job is registered via
  `launchctl list | grep '^ru\.awg\.mavericks\.awgd'`.

These changes turn "install failed silently" into a concrete error in the
alert dialog.

### 8b. Hostname endpoint resolution (awgd 1.2)

Some real-world AWG servers (including the Kazakh3AW3762 profile that
drove this work) hand out hostnames, not IPs, in the `[Peer] Endpoint`
line:

    Endpoint = aids-width-dime-119dc4.relay7ai.net:52046

But `wireguard-go`'s UAPI path (`bind.ParseEndpoint`) deliberately
rejects non-literal hosts, returning `Failed to parse IP address: <host>`
and turning into `IPC error -22: failed to set endpoint …`. So `awgd`
must resolve before handing the config to `dev.IpcSet`.

`service.go:Server.up` now does exactly that:

```go
host, port, _ := net.SplitHostPort(conf.Endpoint)
if net.ParseIP(host) == nil {
    ip, err := resolveEndpoint(host, 3 /*attempts*/)
    if err != nil {
        return fmt.Errorf("endpoint %q: DNS lookup failed: %v",
                          conf.Endpoint, err)
    }
    conf.Endpoint = net.JoinHostPort(ip, port)
}
```

`resolveEndpoint` retries briefly (500 ms between attempts, three total)
because users often click **Connect** while DNS is still coming up after
waking their Mac. IPv4 is preferred (most AWG servers are v4-only); the
fallback is the first A or AAAA record returned.

Tests added:
* `TestResolveEndpoint` — covers already-an-IP, localhost, and a bogus
  name (expects DNS error).
* `TestUpResolvesHostnameEndpoint` — drives the substitution logic used
  by `up` on a config whose endpoint is `localhost:51820`.

Result: when DNS is healthy, a host-named endpoint transparently turns
into the resolved IP and the device accepts the config; when DNS is
unhealthy, the user gets a plain "endpoint <name>: DNS lookup failed:
<error>" instead of the cryptic `IPC error -22`.

### 8c. The utun descriptor must block (awgd 1.4)

This was the bug behind "the tunnel comes up but never handshakes", and it
was only visible once §8b put device logging into the ring. The log said:

    [info]  tunnel "Netherl2AW5933" up on utun0
    [error] Failed to read packet from TUN device: read : resource temporarily unavailable
    [info]  Routine: TUN reader - stopped
    [info]  Device closing
    [info]  Device closed

The device died within the same second it came up, so the single handshake
initiation it managed to emit could never get an answer.

The chain:

1. `tun/tun_darwin.go` opened the utun control socket and called
   `unix.SetNonblock(fd, true)` (copied from the Linux path).
2. `os.NewFile(fd, "")` builds the file with `kindNewFile`, which Go does
   **not** register with the runtime netpoller. So `tunFile.Read()` is a bare
   `read(2)` syscall with no EAGAIN handling of its own.
3. An idle utun therefore returns `EAGAIN` instead of blocking — and a fresh
   tunnel is idle immediately.
4. `RoutineReadFromTUN` treated every error other than "file closed" as fatal
   and ran `go device.Close()`.

The comment in `tun/operateonfd.go` asserted that `Fd()` "marks the fd
blocking for the runtime poller". It does not: `Fd()` only reverts to
blocking when Go itself set the descriptor non-blocking, which never happens
for a `kindNewFile`. That wrong assumption is what kept the bug hidden.

Fix:

* `CreateTUN` no longer sets the utun fd non-blocking. A blocking read is
  what the dedicated TUN reader goroutine wants. (Linux keeps its
  non-blocking fd, because there the descriptor *is* handed to the
  netpoller — the two platforms are not symmetric.)
* `NativeTun.Close()` now calls `shutdown(2)` on the utun fd before
  `close(2)`, so a reader parked in `read(2)` wakes promptly instead of
  lingering.
* Belt and braces: `RoutineReadFromTUN` classifies EAGAIN / EWOULDBLOCK /
  EINTR via `errIsTemporary()` and retries, so no transient read error can
  ever take a tunnel down again.

Regression test `TestTUNReaderSurvivesEAGAIN` (`device/tun_eagain_test.go`)
drives the reader with a TUN that returns EAGAIN and asserts the device stays
up. It was verified to fail on the old code (with the same
"resource temporarily unavailable" message) and pass on the new.

## 9. Verification performed here

* `go build ./...` for `linux/amd64` **and** `darwin/amd64` with Go 1.10.8.
* `go test ./...`:
  * upstream device/tai64n/replay/ratelimiter suites — pass;
  * **AWG end-to-end**: two full devices over in-memory binds, classic
    params (`jc=4 jmin=40 jmax=70 s1=15 s2=73 h1..h4`), ping both ways,
    params echoed by `IpcGet` — pass;
  * **AWG 3.0 end-to-end** (`obf3_selftest_test.go`): full handshake with
    ranged H1..H4 + I1..I3 junk + header protection between two devices,
    bidirectional transport with ContentPaddingAddition, HP framing
    round-trip and UAPI echo — pass (also under `-race`);
  * header-only obfuscation variant — pass;
  * vanilla (no AWG keys) interop — pass (protocol unchanged when off);
  * config validation rejections (duplicate headers, `jmax<jmin`) — pass;
  * daemon config parsing + IPC auth/status round-trip — pass;
  * `TestResolveEndpoint` and `TestUpResolvesHostnameEndpoint`
    (host-named endpoints resolve before being handed to the device)
    — pass;
  * IPC protocol: every command carries `token`; `auth`/`up`/`down`/
    `status`/`log`/`ping`/`stop` all reject without a token and accept
    with the right one (covered by `TestIPCServerRoundTrip`).
* Daemon binary smoke tests on Linux: `-version`, `-genkey`, `-pubkey`,
  `-validate` with a full classic AWG config **and** with a real-world
  AWG 3.0 profile (ranged H1-H4, S3/S4, I1-I3, HP key, padding 50-200,
  timer overrides, PSK); the same 3.0 profile is applied to a live device
  through the daemon's own parse → UAPI path in `awgd_test.go`.

What could **not** be verified in a Linux sandbox: launching the Mach-O on
a real 10.9 system, the utun kernel-control handshake with the XNU kernel,
the GUI build/run (needs Xcode 6.2 CLT on an actual Mac), and live traffic
against a real AWG server. Those are the first things to check on hardware.
