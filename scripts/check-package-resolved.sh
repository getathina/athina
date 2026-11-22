#!/usr/bin/env bash
# Fails when the committed Package.resolved is not the one Package.swift
# resolves to with every package trait on, which CI's test check runs before
# it builds (docs/ci.md "Dependency updates"); --fix writes that one.
#
# SwiftPM stamps the file with the SHA-256 of the manifest it resolved (its
# originHash) and resolves again whenever the two differ, so a stale stamp has
# every build rewrite the file: one without the UISnapshotsSmoke trait writes
# it without the smoke test's package, and one with the trait writes it back.
# So the file must carry this manifest's hash and pin every package the
# manifest names, that trait's included.
#
# Point-Free's manifests also differ by toolchain: below Swift 6.4 they depend
# on xctest-dynamic-overlay, from 6.4 on swift-issue-reporting. With only one
# pinned, the other toolchain resolves again and rewrites the file, so it pins
# both for as long as .xcode-version and a developer's Xcode can sit either side
# of 6.4. All of this is read from the two files: nothing is resolved or
# fetched.
#
# --fix resolves again, keeping every version pinned, then resolves with every
# trait on in a build directory of its own, since one that already has the
# smoke test's package checked out never adds its pin back. A toolchain cannot
# resolve the other's issue-reporting package, so that pin is carried over from
# the file as it was, or as HEAD has it when a build has already dropped it.
#
# Usage: scripts/check-package-resolved.sh [--fix]
# Exit: 0 it matches (or was fixed), 1 it does not, 2 usage.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
by_toolchain=(
	https://github.com/pointfreeco/swift-issue-reporting
	https://github.com/pointfreeco/xctest-dynamic-overlay
)

if [ "${1:-}" = --fix ]; then
	scratch="$(mktemp -d)"
	trap 'rm -rf "$scratch"' EXIT
	# The pins to carry over, oldest first, so the newest of each wins.
	earlier=()
	if git show HEAD:Package.resolved >"$scratch/head.json" 2>/dev/null; then
		earlier+=("$scratch/head.json")
	fi
	if jq -e .pins Package.resolved >/dev/null 2>&1; then
		cp Package.resolved "$scratch/before.json"
		earlier+=("$scratch/before.json")
	fi
	scripts/quietly.sh resolve swift package resolve || {
		echo "package-resolved: swift package resolve failed; log build/logs/resolve.log" >&2
		exit 1
	}
	scripts/quietly.sh resolve-all-traits \
		swift package --scratch-path "$scratch" --enable-all-traits resolve || {
		echo "package-resolved: swift package resolve failed; log build/logs/resolve-all-traits.log" >&2
		exit 1
	}
	# Written as SwiftPM writes it: pins by identity, a space before each colon.
	if ! jq -s --indent 2 --arg urls "${by_toolchain[*]}" '
		($urls | split(" ")) as $either
		| .[-1] as $resolved
		| [.[].pins[] | select(.location as $url | $either | index($url))] + $resolved.pins
		| INDEX(.identity) as $pins
		| $resolved | .pins = ([$pins[]] | sort_by(.identity))
	' ${earlier[@]+"${earlier[@]}"} Package.resolved \
		| sed -E 's/^( *"[^"]+"): /\1 : /' >"$scratch/fixed.json" ||
		! cp "$scratch/fixed.json" Package.resolved; then
		echo "package-resolved: could not carry the other toolchain's pin over" >&2
		exit 1
	fi
elif [ "$#" -gt 0 ]; then
	echo "usage: scripts/check-package-resolved.sh [--fix]" >&2
	exit 2
fi

[ -f Package.resolved ] || {
	echo "package-resolved: failed, there is no Package.resolved; write it with scripts/check-package-resolved.sh --fix" >&2
	exit 1
}
problems=()
manifest="$(shasum -a 256 Package.swift | cut -d' ' -f1)"
stamped="$(sed -nE 's/.*"originHash"[[:space:]]*:[[:space:]]*"([0-9a-f]+)".*/\1/p' Package.resolved)"
if [ "$stamped" != "$manifest" ]; then
	problems+=("it was resolved from another Package.swift (originHash ${stamped:-missing}, Package.swift $manifest)")
fi
# The packages that differ by toolchain, then each .package(url: ...) the
# manifest declares, joined onto one line first, since a declaration may break
# before its url.
while IFS= read -r url; do
	pattern="\"location\"[[:space:]]*:[[:space:]]*\"$(printf '%s' "$url" | sed 's/[][\\.*^$+?(){}|]/\\&/g')\""
	grep -qE "$pattern" Package.resolved || problems+=("it pins no $url")
done < <(
	printf '%s\n' "${by_toolchain[@]}"
	tr '\n' ' ' <Package.swift | grep -oE '\.package\([[:space:]]*url:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/'
)

if [ "${#problems[@]}" -gt 0 ]; then
	printf 'package-resolved: %s\n' "${problems[@]}" >&2
	echo "package-resolved: failed, Package.resolved does not match Package.swift; run scripts/check-package-resolved.sh --fix and commit it" >&2
	exit 1
fi
echo "package-resolved: passed, $(grep -c '"identity"' Package.resolved) packages pinned for this Package.swift"
