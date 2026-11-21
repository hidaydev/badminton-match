#!/bin/sh
# Quarantine register validation (QA-13).
#
# A flake that is not written down becomes a retry count or a sleep, and both
# hide the next real failure. Every quarantined test therefore has an owner, the
# day it was first seen, a day it must be fixed or re-quarantined by, and an
# issue to fix it under. This gate reads docs/handbook/flaky-tests.json and fails
# on a missing field, an expired entry, or an expiry before its first sighting.
#
# The entries are read structurally by `json_array_objects` (REL-QA-02). The
# per-line match this gate used before skipped any entry that wrapped onto a
# second physical line, so an expired quarantine passed by being reformatted.
. "$(dirname "$0")/lib.sh"

register="$REPO_ROOT/docs/handbook/flaky-tests.json"
[ -f "$register" ] || fail "missing quarantine register: docs/handbook/flaky-tests.json"

today=$(date -u +%Y-%m-%d)

status=0
tmp="$REPO_ROOT/.cache/$WORKTREE/flakeregister.$$"
mkdir -p "$REPO_ROOT/.cache/$WORKTREE"
: >"$tmp"

json_array_objects "$register" entries "$tmp" || status=1

# A reader that loses an entry is as bad as one that never saw it. Counting the
# `"test"` keys in the raw file and the objects it produced is the cross-check:
# they disagree only if an entry did not survive, and that is a failure here, not
# a reason to report a smaller number as ok.
declared=$(grep -o '"test"[[:space:]]*:' "$register" | wc -l | tr -d ' ')

awk -v today="$today" -v declared="$declared" '
function problem(text) { print "flakeregister: " text > "/dev/stderr" }
function stringField(line, key,   pattern, start, rest) {
  pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\""
  if (!match(line, pattern)) return ""
  start = RSTART + RLENGTH
  rest = substr(line, start)
  if (!match(rest, /"/)) return ""
  return substr(rest, 1, RSTART - 1)
}
function dateValue(value,   cleaned) {
  if (value !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return -1
  cleaned = value
  gsub(/-/, "", cleaned)
  return cleaned + 0
}
BEGIN { problems = 0; entries = 0 }
{
  if ($0 ~ /^[[:space:]]*$/) next
  entries++
  test = stringField($0, "test")
  owner = stringField($0, "owner")
  first = stringField($0, "firstSeen")
  expires = stringField($0, "expires")
  issue = stringField($0, "issue")
  label = (test != "") ? test : "entry " entries
  missing = 0
  if (test == "") { problem("entry " entries ": test is missing"); missing = 1 }
  if (owner == "") { problem(label ": owner is missing"); missing = 1 }
  if (first == "") { problem(label ": firstSeen is missing"); missing = 1 }
  if (expires == "") { problem(label ": expires is missing"); missing = 1 }
  if (issue == "") { problem(label ": issue is missing"); missing = 1 }
  if (missing) { problems++; next }
  firstDay = dateValue(first)
  expiryDay = dateValue(expires)
  todayDay = dateValue(today)
  if (firstDay < 0) { problem(label ": firstSeen is not YYYY-MM-DD"); problems++; next }
  if (expiryDay < 0) { problem(label ": expires is not YYYY-MM-DD"); problems++; next }
  if (expiryDay < todayDay) {
    problem(label ": quarantine expired on " expires "; fix it or renew it with a new date and issue")
    problems++
  }
  if (expiryDay < firstDay) {
    problem(label ": expires (" expires ") is before firstSeen (" first ")")
    problems++
  }
}
END {
  if (entries != declared + 0) {
    problem("read " entries " entr(ies) from the register but found " declared " \"test\" key(s); an entry the reader cannot see is a quarantine that never expires")
    problems++
  }
  if (problems > 0) exit 1
  printf "flakeregister: ok (%d quarantined)\n", entries
}
' "$tmp" || status=1
rm -f "$tmp"

[ "$status" -eq 0 ] || exit 1
