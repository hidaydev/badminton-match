#!/bin/sh
# Install the Nim packages pinned in deps.lock into ~/.nimble.
#
# The image build runs this before compiling anything: nimlang/nim starts without
# the packages and nimble.paths is not part of the build, so without this step
# the compiler would use whatever a previous layer happened to leave behind.
#
# Re-running is safe: an entry already installed at its pinned version or commit
# is left alone. A nimble entry is `nimble:<url>` for a release and
# `nimble:<url>@<commit>` for a commit pin; nimble spells the latter
# `url@#commit`.
set -eu

# `./task deps-install` provides REPO_ROOT and the shared helpers. The Docker
# build runs this file alone, so it derives the root and defines the two helpers
# it uses instead of failing on the missing task environment.
if [ -n "${WORKTREE:-}" ] && [ -f "$(dirname "$0")/lib.sh" ]; then
  . "$(dirname "$0")/lib.sh"
else
  REPO_ROOT=${REPO_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
  fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
  require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
  }
fi

LOCK="$REPO_ROOT/deps.lock"
[ -f "$LOCK" ] || fail "missing $LOCK"

require_cmd nimble

NIMBLE_PKGS="${NIMBLE_DIR:-$HOME/.nimble}/pkgs2"
NIMBLE_DIR_ARGS=""
if [ -n "${NIMBLE_DIR:-}" ]; then
  NIMBLE_DIR_ARGS="--nimbleDir:$NIMBLE_DIR"
fi

# Succeeds only when exactly one copy of name-version is installed and, for a
# commit pin, its nimblemeta.json records that commit.
installed_at_pin() {
  _name=$1 _version=$2 _ref=$3
  _dirs=$(find "$NIMBLE_PKGS" -mindepth 1 -maxdepth 1 -type d -name "$_name-$_version-*" 2>/dev/null |
    LC_ALL=C sort)
  _count=0
  [ -n "$_dirs" ] && _count=$(printf '%s\n' "$_dirs" | wc -l | tr -d ' ')
  case "$_count" in
    0) return 1 ;;
    1) ;;
    *) fail "$_name: $_count installed copies of $_name-$_version under $NIMBLE_PKGS" ;;
  esac
  if [ -n "$_ref" ]; then
    _actual=$(sed -n 's/.*"vcsRevision"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$_dirs/nimblemeta.json")
    [ "$_actual" = "$_ref" ] || return 1
  fi
  return 0
}

install_entry() {
  _name=$1 _version=$2 _url=$3 _ref=$4
  if installed_at_pin "$_name" "$_version" "$_ref"; then
    printf 'deps-install: %s %s already installed\n' "$_name" "$_version"
    return 0
  fi
  if [ -n "$_ref" ]; then
    _spec="$_url@#$_ref"
    _pin=$_ref
  else
    _spec="$_url@$_version"
    _pin=$_version
  fi
  printf 'deps-install: installing %s at %s\n' "$_name" "$_pin"
  # A neutral directory keeps nimble from also resolving this project's
  # requirements when the script runs from the repository root.
  _work=$(mktemp -d "${TMPDIR:-/tmp}/majadu-deps.XXXXXX")
  if ! ( cd "$_work" && nimble install -y $NIMBLE_DIR_ARGS "$_spec" ); then
    rm -rf "$_work"
    fail "$_name: nimble install failed for $_spec"
  fi
  rm -rf "$_work"
  installed_at_pin "$_name" "$_version" "$_ref" ||
    fail "$_name: installed but not at the pinned commit/version ($_pin)"
}

# Entry fields never contain globs; disable expansion so `set -- $line` splits on
# spaces only.
set -f

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*) continue ;;
    'tree '*) continue ;;
  esac
  # Intentional word splitting: an entry is exactly four space-separated fields.
  # shellcheck disable=SC2086
  set -- $line
  [ "$#" -eq 4 ] ||
    fail "malformed deps.lock entry (expected name version source sha256): $line"
  _name=$1
  _version=$2
  _source=$3
  case "$_source" in
    nimble:*) ;;
    *) continue ;;
  esac
  _url=${_source#nimble:}
  _ref=""
  case "$_url" in
    *@*) _ref=${_url##*@}; _url=${_url%@*} ;;
  esac
  _ref=${_ref#\#}
  install_entry "$_name" "$_version" "$_url" "$_ref"
done <"$LOCK"
