# v-claw
#
# The split between `install` and `install-daemon` is the whole privilege story.
# `install` must never need sudo. Someone with no admin rights runs it and gets a
# working app; `install-daemon` is an upgrade, not a requirement.

BUILD    := build
APP      := $(BUILD)/v-claw.app
BINDIR   := $(HOME)/.local/bin
AGENT    := $(HOME)/Library/LaunchAgents/com.vclaw.agent.plist
LABEL    := com.vclaw.agent

GO       ?= go
SWIFTC   ?= swiftc

.PHONY: all build app icons test lint clean \
        install uninstall install-daemon uninstall-daemon diagnose explain

all: build app

build:
	@mkdir -p $(BUILD)
	$(GO) build -o $(BUILD)/v-claw-app  ./cmd/v-claw-app
	$(GO) build -o $(BUILD)/v-clawd     ./cmd/v-clawd
	$(GO) build -o $(BUILD)/v-claw      ./cmd/v-claw
	$(SWIFTC) -O helper/darwin/main.swift -o $(BUILD)/v-claw-lock

app: build
	@sh scripts/build-app.sh

icons:
	@sh scripts/gen-icons.sh

test:
	$(GO) test ./...

# Nothing above internal/power may import "C". These builds are what enforce it, and
# they keep the Linux and Windows ports from being painted into a corner.
lint:
	$(GO) vet ./...
	@gofmt -l cmd internal | grep . && { echo "gofmt needed"; exit 1; } || true
	GOOS=linux   $(GO) build ./internal/paths ./internal/power ./internal/state
	GOOS=windows $(GO) build ./internal/paths ./internal/power ./internal/state

# ---------------------------------------------------------------- no sudo

install: app
	@mkdir -p $(BINDIR) $(dir $(AGENT))
	@rm -rf /Applications/v-claw.app
	cp -R $(APP) /Applications/
	cp $(BUILD)/v-claw $(BINDIR)/v-claw
	cp resources/com.vclaw.agent.plist $(AGENT)
	-@launchctl bootout gui/$(shell id -u)/$(LABEL) 2>/dev/null
	launchctl bootstrap gui/$(shell id -u) $(AGENT)
	@echo
	@echo "installed. v-claw is in your menu bar."
	@echo "for guaranteed lid-close blocking:  sudo make install-daemon"

uninstall:
	-@launchctl bootout gui/$(shell id -u)/$(LABEL) 2>/dev/null
	rm -f $(AGENT) $(BINDIR)/v-claw
	rm -rf /Applications/v-claw.app
	@echo "removed. the root daemon, if installed, is still there:"
	@echo "  sudo make uninstall-daemon"

# ------------------------------------------------------------------- sudo

install-daemon: build
	@sh scripts/install-daemon.sh

# What an IT reviewer reads before approving.
explain:
	@sh scripts/install-daemon.sh --explain

uninstall-daemon:
	@[ "$$(id -u)" -eq 0 ] || { echo "run: sudo make uninstall-daemon"; exit 1; }
	-@launchctl bootout system/com.vclaw.daemon 2>/dev/null
	rm -f /Library/LaunchDaemons/com.vclaw.daemon.plist /usr/local/libexec/v-clawd
	@echo "daemon removed; it restored the original settings on the way out"
	@echo "state kept at /usr/local/var/v-claw (delete by hand if you want it gone)"

diagnose:
	@$(BUILD)/v-claw diagnose 2>/dev/null || $(GO) run ./cmd/v-claw diagnose

clean:
	rm -rf $(BUILD)
