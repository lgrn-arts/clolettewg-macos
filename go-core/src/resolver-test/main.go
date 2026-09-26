package main

import (
	"fmt"
	"net"
	"os"
)

func resolveEndpoint(host string, attempts int) (string, error) {
	if net.ParseIP(host) != nil { return host, nil }
	var lastErr error
	for i := 0; i < attempts; i++ {
		ips, err := net.LookupIP(host)
		if err != nil { lastErr = err; continue }
		for _, ip := range ips {
			if v4 := ip.To4(); v4 != nil { return v4.String(), nil }
		}
		if len(ips) > 0 { return ips[0].String(), nil }
		lastErr = fmt.Errorf("no addresses returned for %s", host)
	}
	if lastErr == nil { lastErr = fmt.Errorf("DNS lookup for %s returned no addresses", host) }
	return "", lastErr
}

func main() {
	if len(os.Args) < 2 { fmt.Println("usage: resolver-test <host>"); os.Exit(2) }
	r, err := resolveEndpoint(os.Args[1], 1)
	if err != nil { fmt.Println("err:", err); os.Exit(1) }
	fmt.Println("resolved:", r)
}
