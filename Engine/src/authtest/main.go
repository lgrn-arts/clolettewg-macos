package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"net"
	"os"
	"strings"
	"time"
)

type request struct {
	Cmd   string `json:"cmd"`
	Name  string `json:"name,omitempty"`
	Token string `json:"token,omitempty"`
	Conf  string `json:"conf,omitempty"`
	N     int    `json:"n,omitempty"`
}

type reply struct {
	OK    bool        `json:"ok"`
	Error string      `json:"error,omitempty"`
	Data  interface{} `json:"data,omitempty"`
}

func secureEqual(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	var v byte
	for i := 0; i < len(a); i++ {
		v |= a[i] ^ b[i]
	}
	return v == 0
}

func sendReply(c net.Conn, r reply) {
	buf, _ := json.Marshal(r)
	c.Write(append(buf, '\n'))
}

func main() {
	// Generate a fresh token, write to disk like service.go does
	buf := make([]byte, 32)
	rand.Read(buf)
	tok := hex.EncodeToString(buf)
	ioutil.WriteFile("/tmp/authtest-token", []byte(tok+"\n"), 0640)

	// Read it back as the ObjC client does
	data, _ := ioutil.ReadFile("/tmp/authtest-token")
	onDisk := strings.TrimSpace(string(data))
	fmt.Printf("server's token (in-memory): %q\n", tok)
	fmt.Printf("client's token (from disk): %q\n", onDisk)
	if onDisk != tok {
		fmt.Println("FAIL: disk token mismatch")
		os.Exit(1)
	}
	fmt.Println("✓ disk token matches")

	// Spin up a server
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil { panic(err) }
	defer ln.Close()
	addr := ln.Addr().String()
	fmt.Println("listening on", addr)

	go func() {
		c, err := ln.Accept()
		if err != nil { return }
		defer c.Close()
		c.SetDeadline(time.Now().Add(5 * time.Second))
		dec := json.NewDecoder(bufio.NewReader(c))
		for {
			var req request
			if err := dec.Decode(&req); err != nil { return }
			fmt.Printf("  server: cmd=%q token-len=%d\n", req.Cmd, len(req.Token))
			if !secureEqual(req.Token, tok) {
				sendReply(c, reply{OK: false, Error: "authentication failed"})
				continue
			}
			switch req.Cmd {
			case "ping":   sendReply(c, reply{OK: true, Data: map[string]string{"pong":"awgd"}})
			case "status": sendReply(c, reply{OK: true, Data: map[string]interface{}{"state":"disconnected"}})
			case "up":     sendReply(c, reply{OK: true, Data: map[string]interface{}{"state":"connecting"}})
			case "auth":   sendReply(c, reply{OK: true, Data: map[string]string{"service":"test 1.1"}})
			default:       sendReply(c, reply{OK: false, Error: "unknown command: " + req.Cmd})
			}
		}
	}()

	// Client
	c, err := net.Dial("tcp", addr)
	if err != nil { panic(err) }
	defer c.Close()
	send := func(req request) reply {
		buf, _ := json.Marshal(req)
		c.Write(append(buf, '\n'))
		dec := json.NewDecoder(bufio.NewReader(c))
		var r reply
		dec.Decode(&r)
		return r
	}

	// 1. No token → must reject
	r := send(request{Cmd: "ping"})
	if r.OK { fmt.Println("FAIL: no token accepted"); os.Exit(1) }
	fmt.Println("✓ no-token: rejected (", r.Error, ")")

	// 2. Wrong token → reject
	r = send(request{Cmd: "ping", Token: "wrong"})
	if r.OK { fmt.Println("FAIL: wrong token accepted"); os.Exit(1) }
	fmt.Println("✓ wrong-token: rejected (", r.Error, ")")

	// 3. Right token → accepts anything
	for _, cmd := range []string{"auth", "ping", "status", "up"} {
		r := send(request{Cmd: cmd, Token: onDisk})
		if !r.OK { fmt.Printf("FAIL: %q rejected: %v\n", cmd, r); os.Exit(1) }
		fmt.Printf("✓ %q: ok\n", cmd)
	}

	// 4. Old protocol (no token field, but token-like value in name) → also rejected
	r = send(request{Cmd: "up", Name: tok})
	if r.OK { fmt.Println("FAIL: old-protocol accepted"); os.Exit(1) }
	fmt.Println("✓ old-protocol (token-in-name): rejected")

	fmt.Println("\nALL PASS")
}
