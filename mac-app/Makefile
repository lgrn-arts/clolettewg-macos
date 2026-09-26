# Makefile — builds Nanami.app with the command line tools that ship with
# OS X 10.9 Mavericks (Xcode 6.2 / Command Line Tools 6.x).
#
#   make            build Nanami.app
#   make run        build and launch
#   make pkg        build and wrap in Nanami-<version>.pkg
#   make clean
#
# The Go daemon binary must be present at ../bin/awgd.darwin-amd64
# (prebuilt and shipped with this project; rebuild with ../build-core.sh).
#
# The app icon is ../art/Nanami.icns (see ../art/README.md).

APP_NAME  := Nanami
BUNDLE    := $(APP_NAME).app
CC        := clang
MIN_OS    := 10.9
AWGD      := ../bin/awgd.darwin-amd64

CFLAGS  := -mmacosx-version-min=$(MIN_OS) -fobjc-arc -O2 -Wall -Wextra -Wno-deprecated-declarations
FRAMEWORKS := -framework Cocoa -framework Security

SOURCES := src/main.m src/AppDelegate.m src/IPCClient.m src/TunnelStore.m src/HelperInstaller.m

.PHONY: all run pkg clean

all: $(BUNDLE)

$(BUNDLE): $(SOURCES) Info.plist $(AWGD)
	@echo "== compiling =="
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	$(CC) $(CFLAGS) -o $(BUNDLE)/Contents/MacOS/$(APP_NAME) $(SOURCES) $(FRAMEWORKS)
	@echo "== bundle =="
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(AWGD) $(BUNDLE)/Contents/Resources/awgd
	chmod 755 $(BUNDLE)/Contents/Resources/awgd
	@echo "== icon =="
	cp ../art/Nanami.icns $(BUNDLE)/Contents/Resources/Nanami.icns
	@# ad-hoc signature eases Gatekeeper friction on 10.9
	-codesign -s - $(BUNDLE) 2>/dev/null || true
	@echo "== done: $(BUNDLE) =="

run: $(BUNDLE)
	./$(BUNDLE)/Contents/MacOS/$(APP_NAME)

# Flat component package. Nanami.app into /Applications is the entire payload:
# the launchd job and its state are created on first run by the app's own
# privileged helper, so this needs no scripts and no LaunchDaemons payload.
pkg: $(BUNDLE)
	@chmod +x make-pkg.sh
	./make-pkg.sh

clean:
	rm -rf $(BUNDLE) *.pkg
