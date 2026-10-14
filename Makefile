.PHONY: build run restore app clean

build:
	swift build -c release

# Run from a terminal that has Accessibility permission (it inherits the terminal's grant).
run: build
	.build/release/jwm

# Bring back windows left offscreen if jwm crashed.
restore: build
	.build/release/jwm --restore

# Standalone app bundle (ad-hoc signed: re-grant Accessibility after each rebuild).
app: build
	rm -rf jwm.app
	mkdir -p jwm.app/Contents/MacOS
	cp .build/release/jwm jwm.app/Contents/MacOS/jwm
	cp Info.plist jwm.app/Contents/Info.plist
	codesign --force --sign - jwm.app

clean:
	rm -rf .build jwm.app
