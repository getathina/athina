#!/usr/bin/env bash
# What scripts/e2e/tart.sh runs inside its disposable VM, and only there: it
# checks what the harness needs, runs both tiers through the harness, and
# leaves everything to copy out in ~/athina-evidence. It is written for macOS's
# bash 3.2, since it is what finds out whether there is a newer one.
#
# Nothing of the image is assumed. When it has no bash 4 or newer, Homebrew
# installs one, as CI does on its runner, which only ever happens in this VM: it
# comes after the guard below. Nothing else is put right: a missing grant, or a
# bash that will not install, fails with that reason.
set -uo pipefail

# The device Tart gives every guest, which its guest agent looks for too. This
# runs the real-screen tier, so it comes before anything else.
if ! compgen -G '/dev/cu.tart-version-*' >/dev/null; then
	echo "tart-guest: this runs only inside a Tart VM, never on a Mac's own screen; use make test-e2e-tart" >&2
	exit 1
fi

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
EVIDENCE="$HOME/athina-evidence"
HARNESS="$ROOT/scripts/e2e/athina-e2e"
export ATHINA_E2E_CACHE="$HOME/athina-e2e-cache"
# The guest agent's PATH puts macOS's bash 3.2 ahead of Homebrew's.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
mkdir -p "$EVIDENCE"

fail() {
	printf '%s\n' "$*" >"$EVIDENCE/failure.txt"
	echo "tart-guest: $*" >&2
	exit 1
}

{
	sw_vers
	xcodebuild -version
	printf 'bash %s\n' "$(bash -c 'echo "$BASH_VERSION"')"
} >"$EVIDENCE/environment.txt" 2>&1

bash_is_4() { bash -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]'; }

if ! bash_is_4; then
	echo "tart-guest: no bash 4 or newer, so installing one in this VM"
	brew install bash >"$EVIDENCE/bash-install.log" 2>&1 \
		|| fail "the image has no bash 4 or newer and brew install bash failed in the VM (see evidence/bash-install.log)"
	# This shell remembers where it found the older one.
	hash -r
	printf 'bash %s, installed in this VM\n' "$(bash -c 'echo "$BASH_VERSION"')" >>"$EVIDENCE/environment.txt"
	bash_is_4 \
		|| fail "brew install bash left $(command -v bash) first on PATH in the VM, which is older than the bash 4 athina-e2e needs"
fi

echo "tart-guest: building athina-drive to check the grants"
(cd "$ROOT" && swift build -q --product athina-drive) >"$EVIDENCE/drive-build.log" 2>&1 \
	|| fail "athina-drive did not build in the VM (see evidence/drive-build.log)"
"$ROOT/.build/debug/athina-drive" permissions >"$EVIDENCE/permissions.txt" 2>&1 \
	|| fail "athina-drive could not read the grants (see evidence/permissions.txt)"
grep -qx 'accessibility=yes' "$EVIDENCE/permissions.txt" \
	|| fail "the image does not grant Accessibility to what tart exec runs"
grep -qx 'screenRecording=yes' "$EVIDENCE/permissions.txt" \
	|| fail "the image does not grant Screen Recording to what tart exec runs"

# One harness command, its output and exit status kept. Kept in files, so no
# app it leaves behind can hold tart exec's pipe open.
harness() {
	local name="$1" status=0
	shift
	echo "tart-guest: athina-e2e $*"
	"$HARNESS" "$@" >"$EVIDENCE/$name.jsonl" 2>"$EVIDENCE/$name.log" || status=$?
	printf '%s\n' "$status" >"$EVIDENCE/$name.status"
	return "$status"
}

failed=0
harness api run --tier api --out "$EVIDENCE/runs" || failed=1

# The warm home's first capture is also the proof that capture really works.
if ! harness warm warm; then
	# Its log names app.log, and only its journal says why no capture arrived.
	cp -R "$ATHINA_E2E_CACHE/runs" "$EVIDENCE/warm-runs"
	cp -R "$ATHINA_E2E_CACHE/warm-home.building/Library/Application Support/athina" "$EVIDENCE/warm-journal"
	fail "the warm home could not be prepared on the VM's screen (see evidence/warm.log)"
fi

harness screen run --tier screen --out "$EVIDENCE/runs" || failed=1
exit "$failed"
