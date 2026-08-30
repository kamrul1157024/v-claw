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
        install install-app uninstall install-daemon uninstall-daemon diagnose explain

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

# ------------------------------------------------------------ full install

# Installs the app, then the privileged helper. The sudo prompt happens once, here, and
# never again: no toggle in the app ever asks for a password.
#
# The helper step is allowed to fail. Someone who cannot get admin rights still ends up
# with a working app, which is the whole point of the two-tier design.
install: install-app
	@echo
	@echo "==> the helper needs admin once, for guaranteed lid-close blocking"
	@echo "    it is 3 lines; read them with: make explain"
	@echo
	@sudo sh scripts/install-daemon.sh || { \
		echo; \
		echo "helper not installed. v-claw still works:"; \
		echo "  idle sleep and display sleep are blocked"; \
		echo "  lid-close blocking is best effort"; \
		echo "add it later with: sudo make install-daemon"; \
	}

# ---------------------------------------------------------------- no sudo

UID := $(shell id -u)

install-app: app
	@mkdir -p $(BINDIR) $(dir $(AGENT))
	@# Stop the running copy before replacing its binary, or the copy lands under a
	@# live process and the reload fails.
	-@launchctl bootout gui/$(UID)/$(LABEL) 2>/dev/null
	@rm -rf /Applications/v-claw.app
	cp -R $(APP) /Applications/
	cp $(BUILD)/v-claw $(BINDIR)/v-claw
	cp resources/com.vclaw.agent.plist $(AGENT)
	@# bootstrap fails if the label is somehow still registered, so fall back to
	@# kickstart. Reinstalling over a running copy must not need a reboot.
	@launchctl bootstrap gui/$(UID) $(AGENT) 2>/dev/null \
		|| launchctl kickstart -k gui/$(UID)/$(LABEL)
	@echo
	@echo "v-claw is in your menu bar."
	@echo "  cli: $(BINDIR)/v-claw   (add to PATH if it is not already)"

uninstall:
	-@launchctl bootout gui/$(UID)/$(LABEL) 2>/dev/null
	rm -f $(AGENT) $(BINDIR)/v-claw
	rm -rf /Applications/v-claw.app
	@echo
	@echo "==> removing the helper and restoring your original settings"
	@sudo $(MAKE) uninstall-daemon || \
		echo "helper left in place; remove it with: sudo make uninstall-daemon"

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
