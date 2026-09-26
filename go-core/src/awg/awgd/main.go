/* SPDX-License-Identifier: MIT
 *
 * main.go — awgd, the AmneziaWG userspace daemon for OS X Mavericks.
 *
 * Modes:
 *   awgd -service              run the root service (launchd KeepAlive)
 *   awgd -config tunnel.conf   bring one tunnel up from the CLI (as root)
 *   awgd -validate tunnel.conf validate a configuration file
 *   awgd -genkey               generate a private key
 *   awgd -pubkey [privkey]     derive the public key (arg or stdin)
 *   awgd -check                environment sanity check
 *   awgd -version
 *
 * The AmneziaWG engine inside is a Go 1.10 backport of wireguard-go
 * 0.0.20211016 with the AmneziaWG v0.1.8 obfuscation layer grafted on.
 */

package main

import (
	"flag"
	"fmt"
	"io/ioutil"
	"net"
	"os"
	"os/signal"
	"runtime"
	"syscall"
)

var versionString = "awgd 1.4 (AmneziaWG classic 1.0 + 1.5/3.0 wire format; hostname endpoints resolved; device logs + handshake watchdog; blocking utun (EAGAIN fix); wireguard-go 0.0.20211016 base; Go " + runtime.Version() + ")"

var logWriter = os.Stderr

func main() {
	service := flag.Bool("service", false, "run the root launchd service")
	configFile := flag.String("config", "", "bring up a tunnel from a .conf file (root)")
	validate := flag.String("validate", "", "validate a .conf file and exit")
	genkey := flag.Bool("genkey", false, "generate a WireGuard private key")
	pubkey := flag.Bool("pubkey", false, "derive public key from private key (arg or stdin)")
	check := flag.Bool("check", false, "check environment (root, utun support)")
	showVersion := flag.Bool("version", false, "print version")
	flag.Parse()

	switch {
	case *showVersion:
		fmt.Println(versionString)
	case *genkey:
		cmdGenkey()
	case *pubkey:
		cmdPubkey(flag.Arg(0))
	case *validate != "":
		cmdValidate(*validate)
	case *check:
		cmdCheck()
	case *configFile != "":
		cmdConfigUp(*configFile)
	case *service:
		cmdService()
	default:
		flag.Usage()
		os.Exit(2)
	}
}

// ---------------------------------------------------------------- modes

func cmdGenkey() {
	key, err := generatePrivateKey()
	fatalIf(err)
	fmt.Println(encodeKey(key))
}

func cmdPubkey(arg string) {
	var priv string
	if arg != "" {
		priv = arg
	} else {
		data, err := ioutil.ReadAll(os.Stdin)
		fatalIf(err)
		priv = string(data)
	}
	pub, err := derivePublicKey(priv)
	fatalIf(err)
	fmt.Println(pub)
}

func cmdValidate(path string) {
	data, err := ioutil.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "awgd: %v\n", err)
		os.Exit(1)
	}
	conf, err := ParseConf(string(data))
	if err != nil {
		fmt.Fprintf(os.Stderr, "awgd: INVALID: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("OK: obfuscation=%v mtu=%d dns=%d addresses=%d allowed_ips=%d endpoint=%s\n",
		conf.HasObfuscation, conf.MTU, len(conf.DNS), len(conf.Addresses),
		len(conf.AllowedIPs), conf.Endpoint)
}

func cmdCheck() {
	fmt.Println("runtime:", runtime.GOOS, runtime.GOARCH)
	if os.Geteuid() != 0 {
		fmt.Println("euid: NOT ROOT (tunnel operations require root)")
	} else {
		fmt.Println("euid: root")
	}
	if runtime.GOOS == "darwin" {
		tdev, err := createTunProbe()
		if err != nil {
			fmt.Println("utun: UNAVAILABLE:", err)
			os.Exit(1)
		}
		name, _ := tdev.Name()
		tdev.Close()
		fmt.Println("utun: OK, created and destroyed", name)
		if _, err := net.InterfaceByName("lo0"); err != nil {
			fmt.Println("interfaces: unavailable")
		} else {
			fmt.Println("interfaces: OK")
		}
	}
}

func cmdConfigUp(path string) {
	if runtime.GOOS != "darwin" {
		fmt.Fprintln(os.Stderr, "awgd: -config is only supported on darwin")
		os.Exit(1)
	}
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "awgd: -config must run as root")
		os.Exit(1)
	}
	data, err := ioutil.ReadFile(path)
	fatalIf(err)
	conf, err := ParseConf(string(data))
	fatalIf(err)

	ring := newRingLogger(2000)
	_ = ring
	tdev, err := createTunForConf(conf)
	fatalIf(err)
	fmt.Println("tunnel up; SIGINT/SIGTERM to take it down")
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	<-sigs
	tdev.Close()
	fmt.Println("tunnel down")
}

func cmdService() {
	if runtime.GOOS != "darwin" {
		fmt.Fprintln(os.Stderr, "awgd: -service is only supported on darwin")
		os.Exit(1)
	}
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "awgd: -service must run as root")
		os.Exit(1)
	}
	runService()
}

func fatalIf(err error) {
	if err != nil {
		fmt.Fprintf(os.Stderr, "awgd: %v\n", err)
		os.Exit(1)
	}
}
