#!/bin/sh
# Verify installed toolchain and dependencies against deps.lock.
# Format and update procedure: docs/handbook/deps-format.md
. "$(dirname "$0")/lib.sh"

LOCK="$REPO_ROOT/deps.lock"
[ -f "$LOCK" ] || fail "missing $LOCK"

mode=check
skip=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --print) mode=print ;;
    --skip)
      [ "$#" -ge 2 ] || fail "--skip needs a comma-separated list of kinds"
      skip=$(printf '%s' "$2" | tr ',' ' ')
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: ./task deps-check [--print] [--skip <kinds>]

  (no argument)  verify installed content against deps.lock
  --print        print the recomputed tree line and entries; writes nothing
  --skip         do not verify entries of these kinds (comma-separated, for
                 example --skip npm,playwright-browser) and skip the tree hash,
                 which cannot be recomputed over a partial entry set.
                 `advisory` skips the SEC-05 block: a build that carries no
                 `.github` (the container image) also carries no curl.
EOF
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

# Entry fields never contain globs; disable expansion so `set -- $line` splits on spaces only.
set -f

NIMBLE_PKGS="${NIMBLE_DIR:-$HOME/.nimble}/pkgs2"
browsers_dir=${PLAYWRIGHT_BROWSERS_PATH:-}
if [ -z "$browsers_dir" ]; then
  case "$(uname -s)" in
    Darwin) browsers_dir="$HOME/Library/Caches/ms-playwright" ;;
    *) browsers_dir="$HOME/.cache/ms-playwright" ;;
  esac
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/majadu-deps-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

errors=0
unresolved=0
report() {
  printf 'deps-check: %s\n' "$*" >&2
}
mismatch() {
  errors=$((errors + 1))
  report "$*"
}

if command -v sha256sum >/dev/null 2>&1; then
  sha256_stdin() { sha256sum | cut -d' ' -f1; }
else
  require_cmd shasum
  sha256_stdin() { shasum -a 256 | cut -d' ' -f1; }
fi

sha256_file() { sha256_stdin <"$1"; }

# Content digest: sorted relative paths plus their file digests, no timestamps
# and no nimblemeta.json (its "files" array order depends on the install order).
dir_digest() {
  ( cd "$1" && find . -type f ! -path './nimblemeta.json' | LC_ALL=C sort |
    while IFS= read -r rel; do
      printf '%s\n' "${rel#./}"
      sha256_file "$rel"
    done ) | sha256_stdin
}

json_version() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1
}

# Version probing for `toolchain:` entries. Unknown tools fall back to the first
# numeric token of `--version`; if that yields nothing the entry fails closed.
tool_version() {
  case "$1" in
    nim) nim --version | sed -n '1s/^Nim Compiler Version \([^ ]*\).*/\1/p' ;;
    *) "$1" --version 2>&1 | sed -n '1s/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9.]*\).*/\1/p' ;;
  esac
}

# Echo the canonical "name version source sha256" line for one entry, or return 1
# after reporting why it cannot be resolved.
resolve() {
  name=$1 version=$2 source=$3
  computed=
  case "$source" in
    nimble:*)
      ref=
      url=${source#nimble:}
      case "$url" in
        *@*) ref=${url##*@}; url=${url%@*} ;;
      esac
      dirs=$(find "$NIMBLE_PKGS" -mindepth 1 -maxdepth 1 -type d -name "$name-$version-*" 2>/dev/null |
        LC_ALL=C sort)
      count=0
      if [ -n "$dirs" ]; then
        count=$(printf '%s\n' "$dirs" | wc -l | tr -d ' ')
      fi
      if [ "$count" -eq 0 ]; then
        installed=$(find "$NIMBLE_PKGS" -mindepth 1 -maxdepth 1 -type d -name "$name-*" 2>/dev/null |
          LC_ALL=C sort | head -1)
        installed=${installed##*/}
        report "$name: expected $name-$version, installed: ${installed:-absent}"
        return 1
      fi
      if [ "$count" -gt 1 ]; then
        report "$name: $count installed copies of $name-$version under $NIMBLE_PKGS"
        return 1
      fi
      pkg_dir=$dirs
      if [ -n "$ref" ]; then
        actual_ref=$(sed -n 's/.*"vcsRevision"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
          "$pkg_dir/nimblemeta.json")
        if [ "$actual_ref" != "$ref" ]; then
          report "$name: expected commit $ref, installed ${actual_ref:-unknown}"
          return 1
        fi
      fi
      computed=$(dir_digest "$pkg_dir")
      ;;
    repo:*)
      rel=${source#repo:}
      target="$REPO_ROOT/$rel"
      if [ ! -e "$target" ]; then
        report "$name: missing $rel"
        return 1
      fi
      if [ -d "$target" ]; then
        computed=$(dir_digest "$target")
      else
        computed=$(sha256_file "$target")
      fi
      ;;
    toolchain:*)
      cmd=${source#toolchain:}
      if [ "$version" = absent ]; then
        if command -v "$cmd" >/dev/null 2>&1; then
          report "$cmd: declared absent but installed at $(command -v "$cmd"); update deps.lock"
          return 1
        fi
      else
        require_cmd "$cmd"
        actual_version=$(tool_version "$cmd")
        if [ "$actual_version" != "$version" ]; then
          report "$cmd: expected $version, installed ${actual_version:-unknown}"
          return 1
        fi
      fi
      computed=-
      ;;
    npm:*)
      pkg=${source#npm:}
      manifest="$REPO_ROOT/apps/web/node_modules/$pkg/package.json"
      if [ ! -f "$manifest" ]; then
        report "$name: not installed at apps/web/node_modules/$pkg (run pnpm install)"
        return 1
      fi
      actual_version=$(json_version "$manifest")
      if [ "$actual_version" != "$version" ]; then
        report "$name: expected $version, installed ${actual_version:-unknown}"
        return 1
      fi
      computed=-
      ;;
    playwright-browser:*)
      dir="$browsers_dir/$name-$version"
      if [ ! -f "$dir/INSTALLATION_COMPLETE" ]; then
        report "$name: $name-$version is not installed in $browsers_dir"
        return 1
      fi
      computed=-
      ;;
    docker:*)
      # `source` is the exact `name:tag` referenced by apps/api/Dockerfile. The
      # entry's fourth field is the manifest digest that FROM must carry, so a
      # base image can only move when deps.lock moves with it.
      image=${source#docker:}
      manifest="$REPO_ROOT/apps/api/Dockerfile"
      if [ ! -f "$manifest" ]; then
        report "$name: missing $manifest"
        return 1
      fi
      computed=$(awk -v want="$image" '
        $1 == "FROM" {
          ref = $2
          split(ref, parts, "@")
          if (parts[1] == want && parts[2] != "") print parts[2]
        }' "$manifest" | head -1)
      if [ -z "$computed" ]; then
        report "$name: apps/api/Dockerfile has no FROM $image@sha256:..."
        return 1
      fi
      if ! printf '%s\n' "$computed" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
        report "$name: $image is not pinned to a 64-hex sha256 digest (found '$computed')"
        return 1
      fi
      ;;
    release:*)
      # A tool that only CI runs, installed by downloading a release asset. The
      # workflow cannot carry a content digest of its own, so the entry's fourth
      # field is the sha256 the workflow must verify, and the workflows that
      # name the URL are read back here. A re-pin therefore needs the lock and
      # the workflow in one change, and two workflows may not disagree.
      url=${source#release:}
      digest=""
      found=0
      # `set -f` above disables globbing, so the workflow list comes from find.
      for _workflow in $(find "$REPO_ROOT/.github/workflows" -maxdepth 1 -type f \
        \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | LC_ALL=C sort); do
        grep -qF -- "$url" "$_workflow" || continue
        found=1
        _digest=$(grep -A5 -F -- "$url" "$_workflow" |
          grep -oE '[0-9a-f]{64}' | head -1)
        _where=${_workflow#"$REPO_ROOT"/}
        if [ -z "$_digest" ]; then
          report "$name: $_where downloads $url with no 64-hex sha256"
          return 1
        fi
        if [ -n "$digest" ] && [ "$_digest" != "$digest" ]; then
          report "$name: workflows disagree on the sha256 for $url ($_where)"
          return 1
        fi
        digest=$_digest
      done
      if [ "$found" -eq 0 ]; then
        report "$name: no workflow downloads $url"
        return 1
      fi
      computed=$digest
      ;;
    *)
      report "$name: unknown source scheme in '$source'"
      return 1
      ;;
  esac

  printf '%s %s %s %s\n' "$name" "$version" "$source" "$computed"
}

# A workflow file is code, and an action pin is a dependency. `ci-guards`
# proves the shape (40-hex); this pass asks GitHub whether the commit exists, so
# a pin that was resolved once and later removed is caught before the workflow
# fails at setup. Offline and rate-limited runs report a skip: the shape check
# already ran, and a laptop without network must still be able to check a lock.
audit_action_pins() {
  _workflows="$REPO_ROOT/.github/workflows"
  [ -d "$_workflows" ] || return 0
  require_cmd curl
  _token=${GITHUB_TOKEN:-${GH_TOKEN:-}}
  : >"$tmp/actions"
  # `set -f` above disables globbing for the lock parser, so the workflow list
  # comes from find rather than a shell glob.
  find "$_workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) |
    while IFS= read -r _workflow; do
      grep -o 'uses:[[:space:]]*[^[:space:]#]*' "$_workflow" |
        sed 's/^uses:[[:space:]]*//' |
        grep -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$' \
          >>"$tmp/actions" || true
    done
  LC_ALL=C sort -u "$tmp/actions" -o "$tmp/actions"
  # Read from a file, not a pipeline: `mismatch` has to change the caller's
  # counter, and a pipeline would run the loop in a subshell that discards it.
  while IFS= read -r _ref; do
    [ -n "$_ref" ] || continue
    _repo=${_ref%@*}
    _sha=${_ref##*@}
    _code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
      ${_token:+-H "Authorization: Bearer $_token"} \
      "https://api.github.com/repos/$_repo/commits/$_sha" 2>/dev/null || echo 000)
    case "$_code" in
      200) ;;
      404|422)
        mismatch "workflow pin $_repo@$_sha does not resolve on GitHub"
        ;;
      403|000)
        report "workflow pin $_repo@$_sha: GitHub not reachable or rate limited (HTTP $_code); shape was checked"
        ;;
      *)
        mismatch "workflow pin $_repo@$_sha: unexpected HTTP $_code"
        ;;
    esac
  done <"$tmp/actions"
  return 0
}

# SEC-05: the advisory universe.
#
# A content digest proves the bytes did not change; it says nothing about whether
# those bytes are known to be safe, and OSV has no Nimble ecosystem to match a
# Nim package by name and version. The only subject OSV can match is the commit
# the package is pinned to, so that query *is* the verification step: for every
# `nimble:` entry carrying `@<commit>` the lock records what OSV answered, and
# this pass asks again. A published advisory on a pinned commit, a re-pin that
# did not re-query, and a package added without a line all fail here.
#
# The npm universe is `pnpm-lock.yaml`, which `./task osv-scan` already reads,
# and the two base images are pinned by digest in `apps/api/Dockerfile`. This
# block is deliberately only the half nothing else can reach.

advisory_pins() {
  # `name commit` for every nimble entry the lock resolves to a commit.
  LC_ALL=C awk '
    $1 == "tree" || $1 == "advisory" { next }
    NF == 4 && $3 ~ /^nimble:/ && $3 ~ /@/ {
      source = $3
      sub(/^nimble:/, "", source)
      sub(/.*@/, "", source)
      print $1, source
    }' "$LOCK" | LC_ALL=C sort
}

advisory_recorded() {
  # `nim:<name> commit verdict` as written in the lock.
  LC_ALL=C awk '$1 == "advisory" { print }' "$LOCK" | LC_ALL=C sort
}

osv_verdict() {
  # POST one commit to OSV and echo the verdict the lock records: `none`, or the
  # advisory ids sorted and comma-separated. `skip` means no answer was obtained
  # and must never be read as clean.
  _file="$tmp/osv.json"
  rm -f "$_file"
  _code=$(curl -sS -m 20 -o "$_file" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    --data "{\"commit\":\"$1\"}" \
    https://api.osv.dev/v1/query 2>/dev/null) || _code=000
  if [ "$_code" != "200" ] || [ ! -f "$_file" ]; then
    printf 'skip\n'
    return 0
  fi
  _ids=$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$_file" 2>/dev/null |
    sed 's/.*"\([^"]*\)"$/\1/' | LC_ALL=C sort -u | tr '\n' ',')
  _ids=${_ids%,}
  printf '%s\n' "${_ids:-none}"
}

audit_advisory_universe() {
  case " $skip " in
    *" advisory "*)
      report "advisory universe not checked: skipped"
      return 0
      ;;
    *" nimble "*)
      report "advisory universe not checked: nimble entries were skipped"
      return 0
      ;;
  esac
  advisory_pins >"$tmp/pins"
  [ -s "$tmp/pins" ] || return 0
  advisory_recorded >"$tmp/adv"
  require_cmd curl
  while IFS= read -r _pin; do
    _name=${_pin%% *}
    _commit=${_pin#* }
    _line=$(awk -v want="nim:$_name" '$2 == want' "$tmp/adv")
    _count=$(printf '%s\n' "$_line" | grep -c . || true)
    if [ "$_count" -eq 0 ]; then
      mismatch "advisory: $_name is pinned at $_commit with no recorded verdict; query it and add the line"
      continue
    fi
    if [ "$_count" -gt 1 ]; then
      mismatch "advisory: $_name has $_count recorded verdicts"
      continue
    fi
    set -- $_line
    _recorded_commit=$3
    _recorded_verdict=$4
    if [ "$_recorded_commit" != "$_commit" ]; then
      mismatch "advisory: $_name is recorded against $_recorded_commit but pinned at $_commit; re-query the new pin"
      continue
    fi
    _live=$(osv_verdict "$_commit")
    if [ "$_live" = "skip" ]; then
      report "advisory: $_name $_commit could not be queried (OSV unreachable)"
      continue
    fi
    if [ "$_live" != "$_recorded_verdict" ]; then
      mismatch "advisory: $_name $_commit recorded '$_recorded_verdict', OSV now answers '$_live'"
      printf '  lock:     %s\n  computed: advisory nim:%s %s %s\n' \
        "$_line" "$_name" "$_commit" "$_live" >&2
    fi
  done <"$tmp/pins"
  # A line for a package the lock no longer pins is stale data, and a line under
  # an ecosystem this pass cannot query would be a claim nobody checks.
  while IFS= read -r _adv; do
    [ -n "$_adv" ] || continue
    set -- $_adv
    case "$2" in
      nim:*) ;;
      *)
        mismatch "advisory: '$2' is not a subject this check can query"
        continue
        ;;
    esac
    if ! grep -q "^${2#nim:} " "$tmp/pins"; then
      mismatch "advisory: '$2' has a recorded verdict but no pinned nimble entry"
    fi
  done <"$tmp/adv"
}

print_advisories() {
  # The lines `--print` emits for the advisory block, so recording one is a copy
  # out of a single run like every other entry.
  advisory_pins >"$tmp/pins"
  [ -s "$tmp/pins" ] || return 0
  require_cmd curl
  while IFS= read -r _pin; do
    _name=${_pin%% *}
    _commit=${_pin#* }
    _live=$(osv_verdict "$_commit")
    if [ "$_live" = "skip" ]; then
      report "advisory: $_name $_commit could not be queried; no line printed"
      unresolved=$((unresolved + 1))
      continue
    fi
    printf 'advisory nim:%s %s %s\n' "$_name" "$_commit" "$_live"
  done <"$tmp/pins"
}

seen=
: >"$tmp/entries"

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*) continue ;;
    'tree '*) continue ;;
    'advisory '*) continue ;;
  esac
  # Intentional word splitting: an entry is exactly four space-separated fields.
  # shellcheck disable=SC2086
  set -- $line
  if [ "$#" -ne 4 ]; then
    mismatch "malformed entry (expected: name version source sha256): $line"
    continue
  fi
  name=$1 version=$2 source=$3
  kind=${source%%:*}
  case " $skip " in
    *" $kind "*)
      # A job that never runs the frontend gate does not install npm or browser
      # entries; asking it to verify them only reports absence, never drift.
      continue
      ;;
  esac
  case " $seen " in
    *" $name "*)
      mismatch "duplicate entry: $name"
      continue
      ;;
  esac
  seen="$seen $name"

  if actual=$(resolve "$name" "$version" "$source"); then
    printf '%s\n' "$actual" >>"$tmp/entries"
    if [ "$mode" = check ] && [ "$actual" != "$line" ]; then
      mismatch "entry differs: $name"
      printf '  lock:     %s\n  computed: %s\n' "$line" "$actual" >&2
    fi
  else
    unresolved=$((unresolved + 1))
    errors=$((errors + 1))
  fi
done <"$LOCK"

actual_tree=$(LC_ALL=C sort <"$tmp/entries" | sha256_stdin)

if [ "$mode" = print ]; then
  printf 'tree %s\n' "$actual_tree"
  LC_ALL=C sort <"$tmp/entries"
  print_advisories
  if [ "$unresolved" -ne 0 ]; then
    printf 'deps-check: %d entr(y/ies) could not be resolved and are not printed\n' \
      "$unresolved" >&2
    exit 1
  fi
else
  # A tree digest over a partial entry set says nothing; entry errors already fail.
  if [ "$unresolved" -eq 0 ] && [ -z "$skip" ]; then
    expected_tree=$(sed -n 's/^tree \([0-9a-f]\{64\}\)$/\1/p' "$LOCK" | head -1)
    if [ -z "$expected_tree" ]; then
      mismatch "missing or malformed 'tree <sha256>' header"
    elif [ "$actual_tree" != "$expected_tree" ]; then
      mismatch "tree hash differs"
      printf '  lock:     %s\n  computed: %s\n' "$expected_tree" "$actual_tree" >&2
    fi
  fi

  audit_action_pins
  audit_advisory_universe

  if [ "$errors" -ne 0 ]; then
    printf 'deps-check: %d problem(s); update deps.lock (docs/handbook/deps-format.md)\n' "$errors" >&2
    exit 1
  fi
  if [ -n "$skip" ]; then
    printf 'deps-check: ok (skipped %s; tree not compared)\n' "$(printf '%s' "$skip" | tr ' ' ',')"
  else
    printf 'deps-check: ok\n'
  fi
fi
