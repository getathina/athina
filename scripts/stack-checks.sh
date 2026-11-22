#!/usr/bin/env bash
# Prints what CI may skip for the run that asks, from the event that started
# it, which each workflow's changes job does on a pull request (docs/ci.md
# "Stacked pull requests"):
#
#   screenshots=run|skip          skip only on the first attempt of a pull
#                                 request's run whose stack metadata proves
#                                 its position below the stack's size
#   docs-only-allowed=true|false  true only for a pull request that is in no
#                                 stack and goes into the default branch
#   reason=<text>                 why, on one line, for the job summary
#
# When in doubt it answers run and false, so everything runs: no metadata,
# metadata it cannot read or that does not add up, a rerun, whose payload is
# the first attempt's and may be stale, and any event but pull_request. The
# position and size never renumber: they still count the layers that merged or
# closed. A layer's merge ref holds only its own change over the layers below,
# so a docs-only answer for it would say nothing of the stack it completes.
# StackChecksTests checks these rules.
#
# Usage: scripts/stack-checks.sh <event name> <run attempt> <payload file>
# Exit: 0 with the three lines printed, 2 bad usage.
set -uo pipefail

if [ "$#" -ne 3 ]; then
	echo "usage: scripts/stack-checks.sh <event name> <run attempt> <payload file>" >&2
	exit 2
fi
event="$1"
attempt="$2"
payload="$3"

decide() {
	printf 'screenshots=%s\ndocs-only-allowed=%s\nreason=%s\n' "$1" "$2" "$3"
	exit 0
}

[ "$event" = pull_request ] || decide run false "only a pull request's run skips anything"

# One word for where the pull request stands, then its position and size when
# it is in a stack. Anything jq cannot read is unreadable.
found="$(jq -rs '
  def count: type == "number" and . == floor and . >= 1;
  if length != 1 then "unreadable"
  else .[0] | .repository.default_branch as $default | .pull_request |
    if type != "object" then "unreadable"
    elif .stack == null then
      if (.base.ref | type) == "string" and .base.ref == $default then "unstacked"
      else "unlinked" end
    else .stack |
      if (.position | count) and (.size | count) and .position <= .size then
        (if .position < .size then "below" else "top" end) + " \(.position) \(.size)"
      else "unreadable" end
    end
  end
' "$payload" 2>/dev/null)" || found=unreadable
read -r place position size <<<"$found"

case "$place" in
unstacked) decide run true "the pull request is in no stack" ;;
unlinked) decide run false "the pull request is on another branch and is not linked into a stack" ;;
top) decide run false "the pull request is the top of its stack of $size" ;;
below)
	[ "$attempt" = 1 ] || decide run false "a rerun replays its first payload, which may be stale"
	decide skip false "this pull request was layer $position of $size in its stack when the run started, and screenshot tests run only on a stack's top"
	;;
*) decide run false "the event's stack metadata cannot be read or does not add up" ;;
esac
