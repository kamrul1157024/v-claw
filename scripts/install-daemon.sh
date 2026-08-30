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

# Skip the prompt when there is no terminal to answer it, so this can be driven from a
# script. sudo has already authenticated the caller by this point.
if [ -t 0 ]; then
	printf "continue? [y/N] "
	read -r reply
	case "$reply" in
	y | Y) ;;
	*)
		echo "cancelled"
		exit 1
		;;
	esac
fi

# If any step below fails, remove everything this script put on the system. A partial
# install that reports failure while leaving a root binary and a live daemon behind is
# far worse than no install: the operator believes the machine is clean when it is not.
rollback() {
	echo "rolling back" >&2
	launchctl bootout "system/$LABEL" 2>/dev/null || true
	rm -f "$EXE" "$PLIST"
	echo "removed $EXE and $PLIST; nothing of v-claw runs as root" >&2
}

# Stop any previous instance and wait for launchd to actually let go. bootout is
# asynchronous, and bootstrapping while the old job lingers fails with error 5.
launchctl bootout "system/$LABEL" 2>/dev/null || true
i=0
while launchctl print "system/$LABEL" >/dev/null 2>&1 && [ $i -lt 20 ]; do
	sleep 0.25
	i=$((i + 1))
done

# State lives at one fixed path so the root daemon never has to guess which user's
# home directory to watch. The installing user owns it; the daemon only reads it.
mkdir -p "$DATA"
chown "$OWNER" "$DATA"
chmod 755 "$DATA"

mkdir -p "$(dirname "$EXE")"

install -m 755 build/v-clawd "$EXE" || { rollback; exit 1; }
install -m 644 resources/com.vclaw.daemon.plist "$PLIST" || { rollback; exit 1; }

if ! launchctl bootstrap system "$PLIST"; then
	echo "launchctl bootstrap failed" >&2
	rollback
	exit 1
fi

# Never report success on the strength of an exit code alone. Confirm the service is
# actually running before telling anyone it is installed.
if ! launchctl print "system/$LABEL" 2>/dev/null | grep -q "state = running"; then
	echo "the service was loaded but is not running" >&2
	rollback
	exit 1
fi

echo
echo "installed and running. verify with:"
echo "  sudo launchctl print system/$LABEL"
echo "  v-claw diagnose"
