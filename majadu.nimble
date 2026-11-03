# Package metadata for the Majadu v2 backend.
#
# There is no Nimble dependency graph and no nimble.lock: exact versions are
# recorded in deps.lock and verified by ./task deps-check (docs/plan/deps-format.md).
version       = "2.0.0"
author        = "Majadu"
description   = "Badminton community session, rating, and tournament backend"
license       = "MIT"

requires "nim >= 2.4.0 & < 2.5.0"

# Installed by hand into ~/.nimble/pkgs2; pinned again in deps.lock.
requires "mummy == 0.4.8"
requires "nimcrypto == 0.7.3"
requires "zippy == 0.10.20"
requires "webby == 0.2.1"
requires "crunchy == 0.1.11"
requires "nimsimd == 1.3.2"

# Commit pin: the release has no server-side binder (TECH-SPEC §4B).
requires "db_connector#29450a2063970712422e1ab857695c12d80112a6"
