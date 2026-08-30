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

.PHONY: all check build app icons test lint clean \
        install install-app uninstall install-daemon uninstall-daemon diagnose explain

all: check build app

check:
	@[ "$$(uname)" = Darwin ] || { \
		echo "v-claw supports macOS only today. See docs/spec/08-cross-platform.md"; exit 1; }
	@command -v $(GO) >/dev/null || { \
		echo "Go is not installed. Get it from https://go.dev/dl/"; exit 1; }
	@command -v $(SWIFTC) >/dev/null || { \
		echo "Swift is missing. Run: xcode-select --install"; exit 1; }
	@xcode-select -p >/dev/null 2>&1 || { \
		echo "Command Line Tools are missing. Run: xcode-select --install"; exit 1; }

build:
	@mkdir -p $(BUILD)
	$(GO) build -o $(BUILD)/v-claw-app  ./cmd/v-claw-app
	$(GO) build -o $(BUILD)/v-clawd     ./cmd/v-clawd
	$(GO) build -o $(BUILD)/v-claw      ./cmd/v-claw
	$(SWIFTC) -O helper/darwin/*.swift -o $(BUILD)/v-claw-ui

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
	@if $(HELPER_RUNNING); then \
		echo "helper already installed and running — nothing more to do"; \
		exit 0; \
	fi; \
	echo "==> the helper needs admin once, for guaranteed lid-close blocking"; \
	echo "    it is 3 lines; read them with: make explain"; \
	echo; \
	sudo sh scripts/install-daemon.sh || true; \
	if $(HELPER_RUNNING); then exit 0; fi; \
	echo; \
	echo "helper not installed. v-claw still works:"; \
	echo "  idle sleep and display sleep are blocked"; \
	echo "  lid-close blocking is best effort"; \
	echo "add it later with: sudo make install-daemon"

# ---------------------------------------------------------------- no sudo

UID := $(shell id -u)

# Asking for a password v-claw does not need is its own kind of broken, and claiming
# the helper is absent when it is running is worse. Both are decided by this, checked
# before asking and again afterwards.
HELPER_RUNNING = launchctl print system/com.vclaw.daemon 2>/dev/null | grep -q "state = running"

install-app: app
	@mkdir -p $(BINDIR) $(dir $(AGENT))
	@# Stop the running copy before replacing its binary, or the copy lands under a
	@# live process and the reload fails.
	@launchctl bootout gui/$(UID)/$(LABEL) 2>/dev/null || true
	@pkill -f "v-claw.app/Contents/MacOS/v-claw-app" 2>/dev/null || true
	@pkill -f "v-claw.app/Contents/MacOS/v-claw-ui" 2>/dev/null || true
	@sleep 1
	@# Prefer /Applications, but never require admin for it. If it is not writable
	@# (a managed Mac, or a stale root-owned copy left by an old sudo install), fall
	@# back to the per-user ~/Applications so install still needs no sudo. The agent
	@# plist hardcodes the app path, so it is generated to match wherever it landed.
	@appdir=/Applications; \
	if ! ( rm -rf "$$appdir/v-claw.app" && cp -R $(APP) "$$appdir/" ) 2>/dev/null; then \
		appdir=$(HOME)/Applications; \
		mkdir -p "$$appdir"; \
		rm -rf "$$appdir/v-claw.app"; \
		cp -R $(APP) "$$appdir/"; \
		echo "note: /Applications needs admin; installed to $$appdir instead"; \
	fi; \
	mkdir -p $(HOME)/Library/Logs; \
	sed -e "s|@APP@|$$appdir/v-claw.app|g" \
		-e "s|@LOG@|$(HOME)/Library/Logs/v-claw.log|g" \
		resources/com.vclaw.agent.plist > $(AGENT)
	cp $(BUILD)/v-claw $(BINDIR)/v-claw
	@# bootstrap fails if the label is somehow still registered, so fall back to
	@# kickstart. Reinstalling over a running copy must not need a reboot.
	@launchctl bootstrap gui/$(UID) $(AGENT) 2>/dev/null \
		|| launchctl kickstart -k gui/$(UID)/$(LABEL)
	@echo
	@echo "v-claw is in your menu bar."
	@echo "  cli: $(BINDIR)/v-claw"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) \
		echo; echo "  $(BINDIR) is not on your PATH. Add to your shell profile:"; \
		echo "    export PATH=\"$(BINDIR):\$$PATH\"" ;; esac

uninstall:
	-@launchctl bootout gui/$(UID)/$(LABEL) 2>/dev/null
	rm -f $(AGENT) $(BINDIR)/v-claw
	rm -rf /Applications/v-claw.app $(HOME)/Applications/v-claw.app
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
