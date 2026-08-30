#!/bin/sh
# Installs the ONE part of v-claw that runs as root.
#
# This script is deliberately short, because its readability is its security review.
# It makes no network connections, downloads nothing, and collects nothing.
#
# What it installs, and why root is needed:
#   /usr/local/libexec/v-clawd               a service that runs /usr/bin/pmset
#   /Library/LaunchDaemons/com.vclaw.daemon.plist
#   /usr/local/var/v-claw/                   state, owned by the installing user
#
# The pmset "disablesleep" flag stops the laptop sleeping when the lid closes. Setting
# it requires root. Nothing else in v-claw does.
#
# Remove it all with: sudo make uninstall-daemon
set -eu

cd "$(dirname "$0")/.."

EXE=/usr/local/libexec/v-clawd
PLIST=/Library/LaunchDaemons/com.vclaw.daemon.plist
DATA=/usr/local/var/v-claw
LABEL=com.vclaw.daemon

# --explain must work without root. Its whole purpose is to be read before anyone is
# asked to grant privileges.
if [ "${1:-}" = "--explain" ]; then
	# Print the header comment only: stop at the first line that is not a comment.
	awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
	echo "Commands that will run as root:"
	echo "  install -m 755 build/v-clawd $EXE"
	echo "  install -m 644 resources/com.vclaw.daemon.plist $PLIST"
	echo "  launchctl bootstrap system $PLIST"
	echo
	echo "The plist that will be installed:"
	sed 's/^/  /' resources/com.vclaw.daemon.plist
	exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo make install-daemon" >&2; exit 1; }
[ -f build/v-clawd ] || { echo "build/v-clawd missing; run 'make' first" >&2; exit 1; }

OWNER=${SUDO_USER:-root}

echo "v-claw will install a root service:"
echo "  $EXE"
echo "  $PLIST"
echo "  $DATA  (owned by $OWNER)"
echo
printf "continue? [y/N] "
read -r reply
case "$reply" in
y | Y) ;;
*)
	echo "cancelled"
	exit 1
	;;
esac

# State lives at one fixed path so the root daemon never has to guess which user's
# home directory to watch. The installing user owns it; the daemon only reads it.
mkdir -p "$DATA"
chown "$OWNER" "$DATA"
chmod 755 "$DATA"

mkdir -p "$(dirname "$EXE")"

launchctl bootout "system/$LABEL" 2>/dev/null || true

install -m 755 build/v-clawd "$EXE"
install -m 644 resources/com.vclaw.daemon.plist "$PLIST"
launchctl bootstrap system "$PLIST"

echo
echo "installed. verify with:"
echo "  sudo launchctl print system/$LABEL"
echo "  v-claw diagnose"
