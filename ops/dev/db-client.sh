#!/bin/sh
# Postgres client for the local dev host. Sourced by ops/dev/*.sh and
# task.d/lib.sh, never executed.
#
# This host runs Postgres in a container (`pg18`) and carries no psql, createdb
# or dropdb; the binaries live inside the image. When the host binary is absent
# the functions below run the same SQL through the container. The connection
# string is unchanged and still names the database, only the client moves.
#
#   MAJADU_DB_CLIENT=docker|host   force a route instead of detecting one
#   MAJADU_PG_CONTAINER=pg18       container name on this host
#   MAJADU_PG_SUPERUSER=postgres   role used when the DSN names none (the OS user
#                                  inside the container is root, so a bare
#                                  `psql -d postgres` would look for role `root`)
#
# An explicit `-U` or a user in the DSN overrides MAJADU_PG_SUPERUSER.

: "${MAJADU_PG_CONTAINER:=pg18}"
: "${MAJADU_PG_SUPERUSER:=postgres}"

majadu_container_ready() {
  command -v docker >/dev/null 2>&1 || return 1
  [ "$(docker inspect -f '{{.State.Running}}' "$MAJADU_PG_CONTAINER" 2>/dev/null)" = "true" ]
}

if [ -z "${MAJADU_DB_CLIENT:-}" ]; then
  if command -v psql >/dev/null 2>&1; then
    MAJADU_DB_CLIENT=host
  elif majadu_container_ready; then
    MAJADU_DB_CLIENT=docker
  else
    MAJADU_DB_CLIENT=missing
  fi
fi

case "$MAJADU_DB_CLIENT" in
  docker)
    # -i matters: several callers hand SQL over stdin (ops/db/roles.sql, a
    # migration file) because a host path is not visible inside the container.
    psql() {
      docker exec -i -e PGUSER="$MAJADU_PG_SUPERUSER" "$MAJADU_PG_CONTAINER" psql "$@"
    }
    createdb() {
      docker exec -i -e PGUSER="$MAJADU_PG_SUPERUSER" "$MAJADU_PG_CONTAINER" createdb "$@"
    }
    dropdb() {
      docker exec -i -e PGUSER="$MAJADU_PG_SUPERUSER" "$MAJADU_PG_CONTAINER" dropdb "$@"
    }
    ;;
  missing)
    # Defined on purpose: `command -v psql` then still succeeds, so a target
    # reaches this explanation instead of a bare "command not found" many lines
    # before the real problem.
    _majadu_db_client_missing() {
      printf 'error: psql is not on PATH and container %s is not running\n' \
        "$MAJADU_PG_CONTAINER" >&2
      printf 'start it (docker start %s), or set MAJADU_DB_CLIENT=host with the binaries installed\n' \
        "$MAJADU_PG_CONTAINER" >&2
      exit 1
    }
    psql() { _majadu_db_client_missing; }
    createdb() { _majadu_db_client_missing; }
    dropdb() { _majadu_db_client_missing; }
    ;;
esac

# Apply a .sql file to one database of an admin connection.
#
# On the host the file is readable by psql and goes through `-f`; inside the
# container a host path does not exist, so the file and the `\connect` that
# selects the database are handed over on stdin instead. Both write the same
# thing, and `\connect` keeps the host, port and user of the admin connection.
#
#   majadu_apply_sql_file <admin-dsn> <database> <file> [psql args...]
majadu_apply_sql_file() {
  _masf_dsn=$1
  _masf_db=$2
  _masf_file=$3
  shift 3
  if [ "$MAJADU_DB_CLIENT" = "docker" ]; then
    { printf '\\connect %s\n' "$_masf_db"; cat "$_masf_file"; } |
      psql -v ON_ERROR_STOP=1 -d "$_masf_dsn" -v db="$_masf_db" "$@" -f -
  else
    psql -v ON_ERROR_STOP=1 -d "$_masf_dsn" -v db="$_masf_db" \
      -c "\\connect $_masf_db" -f "$_masf_file" "$@"
  fi
}

# Run a .sql file against an already chosen database, for callers that pass the
# database in the DSN instead of connecting to it first.
#
#   majadu_apply_sql_stdin <dsn> <file> [psql args...]
majadu_apply_sql_stdin() {
  _mass_dsn=$1
  _mass_file=$2
  shift 2
  if [ "$MAJADU_DB_CLIENT" = "docker" ]; then
    psql -v ON_ERROR_STOP=1 -d "$_mass_dsn" "$@" -f - <"$_mass_file"
  else
    psql -v ON_ERROR_STOP=1 -d "$_mass_dsn" -f "$_mass_file" "$@"
  fi
}
