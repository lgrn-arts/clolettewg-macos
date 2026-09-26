<div align="right">
  <img src="art/Nanami-1024.png" alt="Nanami app icon" width="88">
</div>

# Nanami

A native GUI AmneziaWG client for OS X 10.9 Mavericks.

Mavericks shipped in 2013 and every modern WireGuard client gave up on it
years ago. This is my attempt to close that gap: a real AppKit app that
speaks both generations of the AmneziaWG protocol. It connects, handshakes
and passes traffic against a live AWG 3.0 server.

```
┌────────────────────────────────────────────────────────────┐
│  Nanami.app (AppKit GUI, Objective-C, no dependencies)     │
│          │  local unix socket + shared token               │
│          ▼                                                 │
│  awgd (root daemon, launchd KeepAlive)                     │
│      AmneziaWG engine in pure Go 1.10:                     │
│      wireguard-go 0.0.20211016                             │
│      + AmneziaWG obfuscation, BOTH generations:            │
│        • classic v1.0 (Jc/Jmin/Jmax/S1/S2/H1..H4)          │
│        • v1.5/3.0 (S3/S4, I1..I5 pattern datagrams, ranged │
│          H1..H4, header protection key, ContentPadding-    │
│          Addition, timer overrides)                        │
│          — protocol-compatible with AWG servers            │
│          │                                                 │
│          ▼                                                 │
│  utun kernel interface (com.apple.net.utun_control)        │
│  + ifconfig / route / networksetup (DNS)                   │
└────────────────────────────────────────────────────────────┘
```

## What's in here

| Path | What it is |
|---|---|
| `bin/awgd.darwin-amd64` | Prebuilt Go daemon for macOS x86_64 (Go 1.10.8, no cgo) |
| `mac-app/` | The GUI — Objective-C/AppKit sources plus a `Makefile` that produces `Nanami.app` |
| `go-core/` | Source of the ported engine (`src/awg/...` and vendored deps), builds with Go 1.10 |
| `build-core.sh` | Rebuilds the daemon, on the old Mac or cross-compiled from Linux |
| `examples/sample-awg-tunnel.conf` | Sample classic (AWG 1.0) tunnel config, example keys |
| `examples/sample-awg3-tunnel.conf` | Sample AWG 1.5/3.0-shaped tunnel config, example keys |

## Why this needed porting

Mavericks is too old for anything current, and the constraints stack up:

Xcode 6.2 (10.9.4+) is the last toolchain that targets 10.9, so the GUI is
plain Objective-C with no external libraries, built by a `Makefile` using
`clang -mmacosx-version-min=10.9`.

Go 1.10.8 is the last Go release that runs on 10.9 at all. Go 1.11 needs
10.10+, and Go 1.13 crashes outright. Current amneziawg-go wants Go 1.20+
and `net/netip` from the 1.18 stdlib, so the whole engine had to be
backported:

* base: `wireguard-go 0.0.20211016`, the last release with the simple
  `net.IP`-based, cgo-free networking stack,
* the obfuscation layer in both generations, with classic **v1.0** grafted
  from amneziawg-go v0.1.8 (junk packets `Jc/Jmin/Jmax`, handshake padding
  `S1/S2`, magic headers `H1..H4`) and the newer **AWG 1.5/3.0** wire format
  ported from amneziawg-go v3.0.3: prefix paddings `S3/S4`, junk pattern
  datagrams `I1..I5` (the `<b …><r …>` mini-DSL), ranged magic headers
  `H1..H4`, a header-protection key that ChaCha20-XORs the whole message,
  `ContentPaddingAddition`, and five timer overrides, all re-expressed in
  the older single-packet idiom,
* dependencies pinned to eras that still compile under Go 1.10 (x/sys from
  June 2019, x/crypto's 2019 curve25519), with shims where newer APIs were
  needed. `PORTING-NOTES.md` has the details.

It ends up speaking both AmneziaWG generations: classic protocol 1 profiles
(`Jc/Jmin/Jmax/S1/S2/H1–H4`) and the modern AWG 1.5/3.0 profiles AmneziaVPN
exports today, with `S3/S4`, `I1..I3`, `HeaderProtectionKey`,
`ContentPaddingAddition` and timer overrides. Detection is automatic, so the
engine enables header protection only when the profile actually carries a
key, and falls back to vanilla WireGuard framing when there's no obfuscation
at all.

## Installing on the Mac

You need OS X 10.9.4+, an admin account, and either the Command Line Tools
(`xcode-select --install` on 10.9 gets you clang 6.x) or Xcode 6.2.

1. Get the source onto the Mac, by cloning or by copying the folder over:

   ```sh
   git clone https://github.com/<your-username>/amneziawg-mavericks.git
   cd amneziawg-mavericks
   ```

2. Build the app. The Go daemon is prebuilt in `bin/`, so no Go toolchain
   is involved:

   ```sh
   cd mac-app
   make
   ```

3. Right-click `Nanami.app` and choose **Open** on the first launch, which
   is the usual Gatekeeper dance.
4. Click **＋ Import** and load your `tunnel.conf`. This is the same file
   the AmneziaVPN app exports, and both classic and modern AWG 1.5/3.0
   profiles are understood.
5. Click **Connect**. You'll be asked once for your admin password to
   install the system service, then the tunnel comes up.
6. The ○/●/◐ menu bar item shows the state and toggles it.

### What the service install does

The GUI runs one root shell through `osascript -e 'do shell script ... with
administrator privileges'`. On 10.9 that's reliable from any app, even an
ad-hoc-signed one, unlike the deprecated `AuthorizationExecuteWithPrivileges`
which can silently do nothing. That script:

* copies the daemon to `/Library/PrivilegedHelperTools/awgd` (root:wheel 755),
* writes `/Library/LaunchDaemons/ru.awg.mavericks.awgd.plist` with
  `RunAtLoad` and `KeepAlive`,
* validates the plist with `plutil -lint` before handing it to launchd,
* loads it and confirms the job is registered via
  `launchctl list | grep ru.awg.mavericks.awgd`,
* creates the shared token at
  `/Library/Application Support/AwgMavericks/token` (root:admin, 0640),

and the daemon then listens on `/var/run/awg-client.sock` (root:admin 0660).

When something fails you get the real error rather than a shrug, for example
`OSA_ERROR:1:awg-install: FAIL: launchctl load exited 1`. The older `set -e`
installer died on the first failed line without saying anything useful; this
one logs every step with an `awg-install: + <cmd>` prefix, so you can also
tail `~/Library/Logs/AwgMavericks/` or `/var/log/` to see what actually ran.

Only admin users can talk to the daemon, enforced by socket group and token.
**Uninstall** takes it all away again.

## Using the command line only

```sh
sudo ./bin/awgd.darwin-amd64 -config tunnel.conf   # bring tunnel up, Ctrl-C to stop
./bin/awgd.darwin-amd64 -validate tunnel.conf      # validate a config (no root)
./bin/awgd.darwin-amd64 -genkey                    # new private key
./bin/awgd.darwin-amd64 -pubkey <private-key>      # derive public key
sudo ./bin/awgd.darwin-amd64 -check                # environment check
```

## Building the Go core yourself

`build-core.sh` does this for you, and works on any OS with the right
toolchain since it downloads Go 1.10.8 and builds in GOPATH mode. Running it
on the Mac gives an identical result, because the engine is pure Go with no
cgo.

## Hacking on it

The GUI has to be built on or for the old SDK, since modern Xcode cannot
target 10.9. Build it on the Mavericks Mac, or on any Mac that has Xcode 6.2
installed alongside a newer version.

The Go core compiles with Go 1.10.x only, which is the whole point.
`go test ./...` passes on any platform: the obfuscation tests run two full
devices against each other in memory. See
`go-core/src/awg/device/obf_selftest_test.go` for classic AWG and
`obf3_selftest_test.go` for the 1.5/3.0 generation, covering full handshake
with junk patterns and header protection, bidirectional padded transport,
and a parser test that pushes an AWG 3.0 profile through the daemon's
config → UAPI → live-device path.

## Notes and limitations

* IPv6 inside the tunnel is partial. Address and route setup covers IPv4
  primarily, and IPv6 `::/0` defaults are not hijacked, since 10.9-era
  `networksetup` and route handling are quirky. Split-tunnel IPv6 routes
  work.
* DNS is switched per network service with `networksetup`, the way wg-quick
  does on Darwin, and restored on disconnect including on daemon SIGTERM.
* If the app quits while connected the tunnel stays up, because the daemon
  is `KeepAlive`. Use Disconnect or `sudo launchctl unload` to take it down.
* Only the first `[Peer]` section of a config is used, which is normal for a
  client profile.
* OS X 10.9 gets no security updates from Apple. A VPN helps with traffic
  privacy but the rest of the system is what it is, so use judgment.
* The engine is GPLv2 as a derivative of wireguard-go. amneziawg-go itself is
  MIT, and both notices are preserved in the file headers.

## Tested matrix

| Component | Where it was verified |
|---|---|
| Engine compiles for darwin/amd64 with Go 1.10.8 | cross-compile from Linux |
| `go test ./awg/...` — AWG 1.0 and 3.0 handshake e2e, config, IPC | Linux |
| AWG classic wire format | byte-for-byte port of amneziawg-go v0.1.8 logic |
| AWG 1.5/3.0 wire format | port of amneziawg-go v3.0.3 (obf*.go, send/receive/uapi/timers) |
| Real-world AWG 3.0 profile | parses, validates and applies — ranged H1–H4, I1–I3, HP key, padding 50-200, timer overrides, PSK |
| Real handshake and traffic | confirmed against a live AWG 3.0 server |
| GUI build and runtime | needs a real Mavericks Mac (Xcode 6.2 CLT) |

## Packaging

`make pkg` in `mac-app/` wraps the built app in a flat installer package
(`Nanami-<version>.pkg`) that installs to `/Applications`.

The payload is just the app. Everything privileged, meaning the launchd job,
the token and `/Library/Application Support/AwgMavericks`, is created
lazily on first run by the app's own helper, so the package ships no
`LaunchDaemons` payload and needs no pre or post-install scripts.

## Contributing

Pull requests are welcome, but the toolchain constraints here are stricter
than usual, so please read them first.

The GUI cannot be built with modern Xcode, since Xcode 6.2 is the last
toolchain that targets 10.9, and `mac-app/` sticks to APIs present in the
10.9 SDK. If you add UI code, that means no `NSButton.buttonWith…` (10.12+),
no `NSStatusItem.button` (10.10+) and no `NSColor.labelColor` (10.10+). The
comment block at the top of `AppDelegate.m` lists what is safe.

The Go core is pinned to Go 1.10.8 by necessity rather than preference,
because it is the last release that runs on 10.9. That rules out
`net/netip` and modules.

`PORTING-NOTES.md` documents how the AWG 1.5/3.0 wire format was backported
and where the shims live, so read it before touching `device/`.

There is no CI. Neither the 10.9 SDK nor Go 1.10 runs in GitHub Actions, so
verification happens on real hardware by hand.

## Security note

The sample configs in `examples/` use throwaway keys that belong to nobody.
Never commit a real tunnel config: a WireGuard `PrivateKey` leaked into a
public repo cannot be recalled. The app keeps live profiles in
`~/Library/Application Support/Nanami/Tunnels.plist`, outside this tree.
