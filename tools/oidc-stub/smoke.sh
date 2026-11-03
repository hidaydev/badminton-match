#!/bin/sh
# Smoke test: authorize -> token -> verify RS256 with the public key.
set -eu
cd "$(dirname "$0")/../.."
port=${1:-19091}
OIDC_STUB_PORT=$port OIDC_STUB_ISSUER=http://127.0.0.1:$port \
  nim c --hints:off -o:/tmp/oidc-stub tools/oidc-stub/main.nim >/dev/null
OIDC_STUB_PORT=$port OIDC_STUB_ISSUER=http://127.0.0.1:$port /tmp/oidc-stub &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
sleep 1
location=$(curl -s -o /dev/null -D - \
  "http://127.0.0.1:$port/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A5173%2Fcb&state=abc&nonce=n1" \
  | grep -i '^location:' | tr -d '\r' | cut -d' ' -f2)
code=$(printf '%s' "$location" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
token=$(curl -s -X POST -d "code=$code&grant_type=authorization_code" \
  "http://127.0.0.1:$port/token" | sed -n 's/.*"id_token":"\([^"]*\)".*/\1/p')
python3 - "$token" <<'PY'
import sys, base64
parts = sys.argv[1].split(".")
open("/tmp/oidc-smoke-input", "w").write(parts[0] + "." + parts[1])
sig = parts[2] + "=" * (-len(parts[2]) % 4)
open("/tmp/oidc-smoke-sig", "wb").write(base64.urlsafe_b64decode(sig))
PY
openssl dgst -sha256 -verify tools/oidc-stub/test_key.pub.pem \
  -signature /tmp/oidc-smoke-sig /tmp/oidc-smoke-input
