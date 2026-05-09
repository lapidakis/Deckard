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
	@# Prefer `kickstart -k` when the service is currently loaded: it
	@# terminates the running instance and restarts in place under the
	@# same launchd entry. The plist resolves to a fixed binary path
	@# that doesn't change between `make build` rebuilds, so the new
	@# binary picks up automatically. This avoids the bootout/bootstrap
	@# dance entirely — that pair has a known launchd race where the
	@# service slot lingers after bootout and bootstrap then fails with
	@# EIO ("Bootstrap failed: 5: Input/output error"), with no reliable
	@# upper bound on the wait time.
	@#
	@# Bootstrap is reserved for the cold path: install / first-run /
	@# the user manually unloaded the service. We retry there with
	@# generous backoff because the service-was-just-unloaded race is
	@# the same one kickstart sidesteps.
	@uid=$(shell id -u); plist=$(HOME)/Library/LaunchAgents/com.lapidakis.deckard.plist; \
	if launchctl print gui/$$uid/com.lapidakis.deckard >/dev/null 2>&1; then \
		echo "launchctl kickstart -k gui/$$uid/com.lapidakis.deckard"; \
		launchctl kickstart -k gui/$$uid/com.lapidakis.deckard; \
	else \
		echo "launchctl bootstrap gui/$$uid $$plist"; \
		launchctl bootstrap gui/$$uid $$plist || \
			(echo "bootstrap retry after 2s..."; sleep 2; launchctl bootstrap gui/$$uid $$plist) || \
			(echo "bootstrap retry after 5s..."; sleep 5; launchctl bootstrap gui/$$uid $$plist); \
	fi

logs:
	tail -f $(HOME)/Library/Logs/Deckard/stderr.log

audit:
	.build/debug/deckard audit tail

clean:
	rm -rf .build
