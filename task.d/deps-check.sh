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
                 which cannot be recomputed over a partial entry set
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
    *)
      report "$name: unknown source scheme in '$source'"
      return 1
      ;;
  esac

  printf '%s %s %s %s\n' "$name" "$version" "$source" "$computed"
}

seen=
: >"$tmp/entries"

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*) continue ;;
    'tree '*) continue ;;
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
