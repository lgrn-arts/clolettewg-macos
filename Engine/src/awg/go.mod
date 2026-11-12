module awg

go 1.22

require (
	golang.org/x/crypto v0.0.0
	golang.org/x/sys v0.15.0
)

replace golang.org/x/crypto => ../golang.org/x/crypto

replace golang.org/x/sys => ../modern-xsys
