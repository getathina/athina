#!/usr/bin/env bash
# Inside a Tart VM, and only there: pre-approves screen capture for Tart's
# guest agent and for nothing else, then prints what it wrote, for the evidence.
#
# From macOS 15 a Screen Recording grant does not stop the "requesting to
# bypass the system private window picker" alert, which takes focus. replayd
# keeps when it is next due in a file of its own, by the responsible process,
# which for everything `tart exec` runs is the guest agent. This writes what
# GitHub's runner image writes there for its agent (actions/runner-images,
# images/macos/scripts/build/configure-tccdb-macos.sh).
#
# It grants nothing: not Screen Recording, not Accessibility. It uses no sudo,
# and when the write is refused or waits on a prompt it fails with that reason.
set -euo pipefail

# The device Tart gives every guest. This changes a permission, so it has a
# guard of its own, before anything else, and never relies on its caller's.
if ! compgen -G '/dev/cu.tart-version-*' >/dev/null; then
	echo "tart-capture-approval: this runs only inside a Tart VM, and changes nothing on any other Mac" >&2
	exit 1
fi

fail() {
	echo "tart-capture-approval: $*" >&2
	exit 1
}

# replayd's folder is another program's, where macOS may hold a write for a
# prompt nobody is there to answer, so each step that touches it is bounded.
bounded() { /usr/bin/perl -e 'alarm 30; exec @ARGV or die' "$@"; }

# The path the image's grants name: the resolved one, not Homebrew's link.
agent="$(/bin/realpath /opt/homebrew/bin/tart-guest-agent)" || fail "found no Tart guest agent to approve"
approvals="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"

bounded /bin/mkdir -p "$(dirname "$approvals")" || fail "could not make replayd's folder"
bounded /usr/bin/defaults write "$approvals" "$agent" -date "3024-01-01 00:00:00 +0000" \
	|| fail "could not write the approval for $agent"
# cfprefsd writes the file out as it stops.
killall cfprefsd 2>/dev/null || true

for _ in 1 2 3 4 5 6 7 8 9 10; do
	if written="$(bounded /usr/bin/plutil -p "$approvals" 2>/dev/null)" \
		&& grep -qF "\"$agent\" => 3024-" <<<"$written"; then
		printf 'pre-approved in this VM only: %s\nfile: %s\n%s\n' "$agent" "$approvals" "$written"
		exit 0
	fi
	sleep 1
done
fail "the approval for $agent did not reach $approvals"
