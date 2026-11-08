#!/bin/sh
# Quarantine register validation (QA-13).
#
# A flake that is not written down becomes a retry count or a sleep, and both
# hide the next real failure. Every quarantined test therefore has an owner, the
# day it was first seen, a day it must be fixed or re-quarantined by, and an
# issue to fix it under. This gate reads docs/handbook/flaky-tests.json and fails
# on a missing field, an expired entry, or an expiry before its first sighting.
#
# The file is JSON with flat entries (`{"test": "...", ...}`), so it is read with
# awk instead of a JSON library: no dependency, and the shape is enforced below.
. "$(dirname "$0")/lib.sh"

register="$REPO_ROOT/docs/handbook/flaky-tests.json"
[ -f "$register" ] || fail "missing quarantine register: docs/handbook/flaky-tests.json"

today=$(date -u +%Y-%m-%d)

awk -v today="$today" -v file="docs/handbook/flaky-tests.json" '
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
/\{[[:space:]]*"test"[[:space:]]*:/ {
  entries++
  test = stringField($0, "test")
  owner = stringField($0, "owner")
  first = stringField($0, "firstSeen")
  expires = stringField($0, "expires")
  issue = stringField($0, "issue")
  label = (test != "") ? test : "entry " entries
  missing = 0
  if (test == "") { print "flakeregister: " file ":" NR ": test is missing"; missing = 1 }
  if (owner == "") { print "flakeregister: " label ": owner is missing"; missing = 1 }
  if (first == "") { print "flakeregister: " label ": firstSeen is missing"; missing = 1 }
  if (expires == "") { print "flakeregister: " label ": expires is missing"; missing = 1 }
  if (issue == "") { print "flakeregister: " label ": issue is missing"; missing = 1 }
  if (missing) { problems++; next }
  firstDay = dateValue(first)
  expiryDay = dateValue(expires)
  todayDay = dateValue(today)
  if (firstDay < 0) { print "flakeregister: " label ": firstSeen is not YYYY-MM-DD"; problems++; next }
  if (expiryDay < 0) { print "flakeregister: " label ": expires is not YYYY-MM-DD"; problems++; next }
  if (expiryDay < todayDay) {
    print "flakeregister: " label ": quarantine expired on " expires "; fix it or renew it with a new date and issue"
    problems++
  }
  if (expiryDay < firstDay) {
    print "flakeregister: " label ": expires (" expires ") is before firstSeen (" first ")"
    problems++
  }
}
END {
  if (problems > 0) exit 1
  printf "flakeregister: ok (%d quarantined)\n", entries
}
' "$register"