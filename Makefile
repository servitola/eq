.PHONY: test build smoke lint

test:
	swift test

build:
	scripts/build-app.sh

smoke: build
	scripts/smoke.sh

lint:
	zsh -n scripts/build-app.sh scripts/smoke.sh
	plutil -lint Resources/Info.plist Resources/eq.entitlements Resources/com.servitola.eq.plist
