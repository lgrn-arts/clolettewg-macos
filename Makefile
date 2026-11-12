.PHONY: all app core dmg test test-app test-core clean

all:
	./build.sh

app:
	SKIP_DMG=1 ./build.sh

core:
	./Scripts/build-core.sh

dmg: app
	./Scripts/package-dmg.sh

test: test-app test-core

test-app:
	./Scripts/test-app.sh

test-core:
	./Scripts/test-core.sh

clean:
	rm -rf build .build/go .build/go1.10.8.* CloletteWG-*.dmg
