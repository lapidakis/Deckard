# Deckard — convenience targets
#
# Goals:
#   build         debug build + codesign
#   release       release build + codesign + timestamp
#   test          run swift test
#   install       (re)install LaunchAgent against the latest signed binary
#   uninstall     remove LaunchAgent
#   clean         remove .build
#
# Codesigning identity / bundle id can be overridden via env:
#   DECKARD_SIGN_IDENTITY="..."  DECKARD_BUNDLE_ID="..."  make build

.PHONY: build release test install uninstall clean restart logs

build:
	swift build
	./scripts/codesign.sh debug

release:
	swift build -c release
	./scripts/codesign.sh release

ui: build
	chmod +x scripts/build-ui-app.sh
	./scripts/build-ui-app.sh debug

ui-release: release
	chmod +x scripts/build-ui-app.sh
	./scripts/build-ui-app.sh release

test:
	swift test

install: build
	.build/debug/deckard install --force

uninstall:
	.build/debug/deckard uninstall

restart: build
	-launchctl bootout gui/$(shell id -u)/com.lapidakis.deckard
	@# launchd's bootout is async — the service entry can linger after the
	@# command returns, and a too-quick bootstrap then fails with EIO
	@# ("Bootstrap failed: 5: Input/output error"). Poll print until the
	@# service is gone, then bootstrap. Bounded so a stuck teardown doesn't
	@# wedge the make target forever.
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		if ! launchctl print gui/$(shell id -u)/com.lapidakis.deckard >/dev/null 2>&1; then \
			break; \
		fi; \
		sleep 0.3; \
	done
	@# Retry bootstrap once on EIO — a few macOS releases still emit it
	@# even when print reports the slot empty. The retry path almost
	@# always succeeds; if it doesn't, surface the real error.
	launchctl bootstrap gui/$(shell id -u) $(HOME)/Library/LaunchAgents/com.lapidakis.deckard.plist || \
		(sleep 1 && launchctl bootstrap gui/$(shell id -u) $(HOME)/Library/LaunchAgents/com.lapidakis.deckard.plist)

logs:
	tail -f $(HOME)/Library/Logs/Deckard/stderr.log

audit:
	.build/debug/deckard audit tail

clean:
	rm -rf .build
