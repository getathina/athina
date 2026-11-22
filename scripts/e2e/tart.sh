#!/usr/bin/env bash
# `make test-e2e-tart`: both end-to-end tiers inside a disposable macOS VM,
# with Tart (https://tart.run), so that nothing is driven or captured on this
# Mac's screen. It runs only when asked for by that name: no other make target,
# hook or check calls it.
#
# It clones a VM of its own from the image pinned below, runs it with no
# window, sends it HEAD's files, runs scripts/e2e/lib/tart-guest.sh there, copies
# the evidence out and deletes that VM, however it ends. It passes only when
# both tiers pass and the copied capture-race report reads dropped=0.
#
# What the VM gets from this Mac is `git archive HEAD` and nothing else: no
# untracked or ignored file, no .git (so the harness's own build.txt names no
# commit, and provenance.txt in the evidence does), no shared directory, no
# clipboard and no audio. Every command in it goes through Tart's guest agent
# (`tart exec`), so no SSH, password or agent is involved, and none of this
# environment is passed on. It does have Tart's default NAT network, which
# SwiftPM needs, and over which a guest can reach what this Mac serves on every
# interface.
#
# It installs nothing, changes no permission on this Mac and has no fallback:
# without Tart, or without the disk the image needs, it stops and says why.
set -euo pipefail

# cirruslabs/macos-golden-gate-xcode, tag 27.1. The sizes are its manifest's:
# 82.3 GB to download, 96.8 GB on disk.
IMAGE="ghcr.io/cirruslabs/macos-golden-gate-xcode@sha256:9ae66619fed9abc4740efefc0e2f6ac9440560095c79fa1ebe2b95d89d9b61b9"
IMAGE_GB=97
# What a run writes to its copy-on-write clone (builds, caches, swap), with room
# left over for this Mac.
RUN_GB=30
# The display the committed fixtures were recorded on, in pixels at 1x. The
# image's own 1024x768 cuts the tallest Settings panes off above the Dock.
DISPLAY_SIZE="1728x1117px"
BOOT_SECONDS=300

# Tart makes room for a clone or a pull by deleting other cached images, unless
# this is set. This command deletes the VM it made and nothing else.
export TART_NO_AUTO_PRUNE=1

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
vm=""
run_pid=""
work=""
out=""

die() {
	echo "test-e2e-tart: failed, $*${out:+; evidence in $out}" >&2
	exit 1
}

run_is_up() {
	[ -n "$run_pid" ] && grep -qx "$run_pid" <<<"$(jobs -rp)"
}

# Stops and deletes the VM this run made, by its name, which holds a new UUID.
remove_vm() {
	[ -n "$vm" ] || return 0
	if run_is_up; then
		tart stop "$vm" >/dev/null 2>&1 || true
		if run_is_up; then kill -KILL "$run_pid" 2>/dev/null || true; fi
	fi
	if [ -n "$run_pid" ]; then wait "$run_pid" 2>/dev/null || true; fi
	run_pid=""
	local names
	# An interrupted clone may have made no VM to delete.
	if names="$(tart list --source local --quiet)" && ! grep -qxF -- "$vm" <<<"$names"; then
		vm=""
	elif tart delete "$vm"; then
		vm=""
	else
		echo "test-e2e-tart: could not delete the VM it made; run: tart delete $vm" >&2
		return 1
	fi
}

on_exit() {
	local status=$?
	trap '' INT TERM HUP
	set +e
	remove_vm || status=1
	[ -z "$work" ] || rm -rf "$work"
	exit "$status"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$#" -eq 0 ] || die "it takes no arguments"
command -v tart >/dev/null \
	|| die "Tart is not installed (https://tart.run); this installs nothing and never uses this Mac's screen instead"
changed="$(git -C "$ROOT" status --porcelain)" || die "could not read the checkout's git status"
[ -z "$changed" ] || die "the checkout has uncommitted changes, and the VM is sent only HEAD: commit them first"
commit="$(git -C "$ROOT" rev-parse HEAD)" || die "could not read HEAD"

# The disk, before anything is pulled. An image already cached needs none.
cached="$(tart list --source oci --quiet)" || die "tart could not list its cached images"
needed=$RUN_GB
grep -qxF -- "$IMAGE" <<<"$cached" || needed=$((IMAGE_GB + RUN_GB))
volume="${TART_HOME:-$HOME/.tart}"
until [ -e "$volume" ]; do volume="$(dirname "$volume")"; done
free_kb="$(df -Pk "$volume" | awk 'NR == 2 { print $4 }')"
case "$free_kb" in
'' | *[!0-9]*) die "could not read the free disk space at $volume" ;;
esac
free_gb=$((free_kb * 1024 / 1000000000))
[ "$free_gb" -ge "$needed" ] \
	|| die "$volume has $free_gb GB free and this needs $needed GB; nothing was pulled or deleted"

out="${ATHINA_E2E_CACHE:-$HOME/Library/Caches/athina-e2e}/tart/$(date '+%Y%m%d-%H%M%S')-$$"
mkdir -p "$out/evidence"
work="$(mktemp -d "${TMPDIR:-/tmp}/athina-tart.XXXXXX")"
printf 'commit %s\nimage %s\ntart %s\n' "$commit" "$IMAGE" "$(tart --version)" >"$out/provenance.txt"
git -C "$ROOT" archive --format=tar --output="$work/source.tar" "$commit" || die "could not archive $commit"

vm="athina-e2e-$(uuidgen)"
echo "test-e2e-tart: cloning $vm from $IMAGE ($free_gb GB free, $needed GB needed)"
tart clone "$IMAGE" "$vm" || die "tart could not clone the image"
tart set "$vm" --display "$DISPLAY_SIZE" || die "tart could not set the VM's display"

echo "test-e2e-tart: starting $vm with no window"
# No --dir: nothing on this Mac is shared. Clipboard and audio, the microphone
# with it, are shared unless turned off.
tart run --no-graphics --no-clipboard --no-audio "$vm" </dev/null >"$out/tart-run.log" 2>&1 &
run_pid=$!

# The guest agent is a LaunchAgent of the image's logged-in user, so once it
# answers there is a desktop session.
deadline=$((SECONDS + BOOT_SECONDS))
until [ "$(tart exec "$vm" /bin/echo ready 2>>"$out/boot.log")" = ready ]; do
	run_is_up || die "the VM stopped while starting (see tart-run.log)"
	[ "$SECONDS" -lt "$deadline" ] || die "the VM's guest agent did not answer in $BOOT_SECONDS seconds"
	sleep 5
done

echo "test-e2e-tart: sending $commit"
# In the guest, cd alone is its home.
tart exec -i "$vm" /bin/sh -c 'cd && cat >athina-source.tar' <"$work/source.tar" \
	|| die "could not send the source to the VM"
sent="$(shasum -a 256 <"$work/source.tar")"
got="$(tart exec "$vm" /bin/sh -c 'cd && shasum -a 256 <athina-source.tar')" \
	|| die "could not read back the source's checksum"
[ "$sent" = "$got" ] || die "the source did not reach the VM intact"
tart exec "$vm" /bin/sh -c 'cd && mkdir athina && tar -xf athina-source.tar -C athina' \
	|| die "could not unpack the source in the VM"

echo "test-e2e-tart: running both tiers in the VM"
guest_status=0
tart exec "$vm" /bin/sh -c 'cd && exec /bin/bash athina/scripts/e2e/lib/tart-guest.sh' || guest_status=$?

# Copied out whatever happened, since the VM is deleted next.
tart exec "$vm" /bin/sh -c 'cd && exec tar -czf - -C athina-evidence .' >"$work/evidence.tar.gz" \
	|| die "could not copy the evidence out of the VM"
tar -xzf "$work/evidence.tar.gz" -C "$out/evidence" || die "the evidence copied out of the VM is unreadable"
remove_vm || die "the VM is still there"

# The verdict is read from what was copied out, not only from an exit status.
if [ -f "$out/evidence/failure.txt" ]; then die "in the VM: $(head -n 1 "$out/evidence/failure.txt")"; fi
for tier in api screen; do
	[ "$(cat "$out/evidence/$tier.status" 2>/dev/null)" = 0 ] \
		|| die "the $tier tier did not pass (see evidence/$tier.log)"
done
report="$(find "$out/evidence" -type f -path '*/runs/capture-race-*/capture-race.tsv')"
[ -n "$report" ] || die "capture-race left no report"
case "$report" in
*$'\n'*) die "capture-race left more than one report" ;;
esac
dropped="$(sed -nE 's/^moments=[0-9]+ kept=[0-9]+ dropped=([0-9]+) pending=[0-9]+$/\1/p' "$report")"
[ -n "$dropped" ] || die "capture-race's report has no dropped count ($report)"
[ "$dropped" = 0 ] || die "capture-race read dropped=$dropped, and dropped=0 is required ($report)"
[ "$guest_status" = 0 ] || die "the run in the VM exited $guest_status"

echo "test-e2e-tart: passed, both tiers with capture-race dropped=0 at $commit; evidence in $out"
