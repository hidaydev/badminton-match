#!/bin/sh
. "$(dirname "$0")/lib.sh"

: "${MAJADU_AUDIT_DSN:?MAJADU_AUDIT_DSN is required (owner role, not bm2_app)}"
if [ "${MAJADU_AUDIT_DSN}" = "${MAJADU_PG_DSN:-}" ]; then
  fail "MAJADU_AUDIT_DSN must differ from MAJADU_PG_DSN; audit pruning runs as the owner role"
fi

nim_build -o:"$NIMCACHE_BUILD/bin/auditretention" tools/auditretention/main.nim

MAJADU_AUDIT_DSN="$MAJADU_AUDIT_DSN" "$NIMCACHE_BUILD/bin/auditretention"
