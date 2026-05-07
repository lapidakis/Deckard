# iCloud-Bridge — convenience targets
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
#   ICB_SIGN_IDENTITY="..."  ICB_BUNDLE_ID="..."  make build

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
	.build/debug/icloud-bridge install --force

uninstall:
	.build/debug/icloud-bridge uninstall

restart: build
	-launchctl bootout gui/$(shell id -u)/com.lapidakis.icloud-bridge
	launchctl bootstrap gui/$(shell id -u) $(HOME)/Library/LaunchAgents/com.lapidakis.icloud-bridge.plist

logs:
	tail -f $(HOME)/Library/Logs/iCloud-Bridge/stderr.log

audit:
	.build/debug/icloud-bridge audit tail

clean:
	rm -rf .build
