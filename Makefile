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
	launchctl bootstrap gui/$(shell id -u) $(HOME)/Library/LaunchAgents/com.lapidakis.deckard.plist

logs:
	tail -f $(HOME)/Library/Logs/Deckard/stderr.log

audit:
	.build/debug/deckard audit tail

clean:
	rm -rf .build
