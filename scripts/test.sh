#!/usr/bin/env bash
# `make test`, which CI's test check runs as it stands: swift test, the
# replayed loop and the fixture freshness check included, then the check that
# a build without the ControlAPI trait carries no control API (docs/e2e.md "The
# control API"). The debug Athina the tests' build already made is such a
# build, so it checks that one rather than compiling the package again; `swift
# build` only confirms it is current. Ends in one summary line; the whole
# output is in build/logs (scripts/quietly.sh).
#
# AthinaFeaturesTests runs in a swift test of its own, after the rest: its
# TestStores put every task in their process on the main thread, where a test
# that blocks waiting for the main actor waits for good, and CI's toolchain
# otherwise runs every test target in one process (docs/testing.md "Stores in
# tests"). Both runs always happen, and either one failing fails this.
#
# The tests on the quarantine list, Tests/quarantine.json, run on their own
# after the rest, and their failure is reported, not counted; nothing runs
# again (docs/testing.md "Quarantine"). A filter runs exactly the tests it
# matches, quarantined or not, and counts every one.
#
# Usage: scripts/test.sh [<filter>]
#   <filter> runs only the tests matching it, as swift test --filter takes it
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
# What each of the two processes skips, over <target>.<suite>/<test>(): the
# features' tests, and every test that is not one of them.
features='^AthinaFeaturesTests\.'
others='^(?!AthinaFeaturesTests\.)'
# Runs swift test once in each process, adding the arguments after the name to
# both, into build/logs/<name>.log and build/logs/<name>-features.log. It
# fails when either run does.
in_two_processes() {
	local name="$1" failed=0
	shift
	scripts/quietly.sh "$name" swift test "$@" --skip "$features" || failed=1
	scripts/quietly.sh "$name-features" swift test "$@" --skip "$others" || failed=1
	return "$failed"
}
# Swift Testing ends each test binary's run with "Test run with <n> tests in
# <m> suites passed after ..." or "... failed after ... with <k> issues", and
# swift test runs several binaries, so the counts are summed. The issues
# withKnownIssue expects are among that k, "(including <j> known issues)", and
# are no failure, so they are taken off.
runs() {
	grep -hE 'Test run with [0-9]+ tests? ' "build/logs/$1.log" "build/logs/$1-features.log" 2>/dev/null
}
tests() { runs "$1" | sed -E 's/.*Test run with ([0-9]+) tests?.*/\1/' | awk '{ n += $1 } END { print n + 0 }'; }
issues() { runs "$1" | grep ' failed after ' | sed -nE 's/.* with ([0-9]+) issues?( \(including ([0-9]+) known issues?\))?.*/\1 \3/p' | awk '{ n += $1 - $2 } END { print n + 0 }'; }

quarantined=""
if [ -n "${1:-}" ]; then
	in_two_processes test --filter "$1"
else
	quarantined="$(scripts/quarantine.sh tests)" || exit 2
	in_two_processes test ${quarantined:+--skip "$quarantined"}
fi
status=$?
if [ "$status" -ne 0 ]; then
	if [ -n "$(runs test)" ]; then
		echo "test: failed, $(issues test) issues in $(tests test) tests; rerun one with make test FILTER=<name>, logs build/logs/test.log and build/logs/test-features.log" >&2
	else
		echo "test: failed before any test ran; log build/logs/test.log, and make doctor names a missing tool" >&2
	fi
	exit 1
fi
count="$(tests test)"
aside=""
if [ -n "$quarantined" ]; then
	if in_two_processes test-quarantined --filter "$quarantined"; then
		aside=" (the $(tests test-quarantined) quarantined passed too)"
	else
		scripts/quarantine.sh report tests
		aside=" (the $(tests test-quarantined) quarantined failed, not counted: build/logs/test-quarantined.log and build/logs/test-quarantined-features.log)"
	fi
fi
if ! scripts/quietly.sh test-build swift build --product Athina; then
	echo "test: failed, swift build --product Athina did not build; log build/logs/test-build.log" >&2
	exit 1
fi
if ! scripts/check-no-control-api.sh "$(swift build --show-bin-path)/Athina" >/dev/null; then
	echo "test: failed, a build without the ControlAPI trait carries the control API" >&2
	exit 1
fi
echo "test: passed, ${count:-0} tests${aside} and no control API in a build without the trait; logs build/logs/test.log and build/logs/test-features.log"
