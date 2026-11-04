# The compiler evaluates this file inside the NimScript VM, where switch(),
# thisDir() and the filesystem helpers are built in. The import keeps the file
# resolvable for editors.
import std/os

switch("path", thisDir() & "/shared")
switch("path", thisDir() & "/shared/platform-lib")
switch("path", thisDir() & "/modules")
switch("path", thisDir() & "/apps")
switch("path", thisDir() & "/tools")
# `nim check config.nims` treats the config as the target project too, and
# --mm:atomicArc makes the checker fail inside system.nim. When the target is the
# config file itself the switches are skipped, so that check stays clean; every
# real build still gets them.
when projectName() != "config":
  switch("threads", "on")
  switch("mm", "atomicArc")
  switch("stackTrace", "on")
  switch("lineTrace", "on")

# Local libpq resolution on macOS. Homebrew keeps libpq outside the default
# dyld search path, and macOS strips DYLD_* from protected shells, so an rpath
# is the only reliable option. Override MAJADU_LIBPQ_DIR for other layouts.
when defined(macosx):
  block:
    let libpqDir = getEnv("MAJADU_LIBPQ_DIR",
      "/opt/homebrew/opt/postgresql@18/lib/postgresql")
    if dirExists(libpqDir):
      switch("passL", "-Wl,-rpath," & libpqDir)

# OpenSSL 3 is a keg on macOS; same rpath reasoning as libpq above.
when defined(macosx):
  block:
    let opensslDir = getEnv("MAJADU_OPENSSL_DIR",
      "/opt/homebrew/opt/openssl@3/lib")
    if dirExists(opensslDir):
      switch("passL", "-Wl,-rpath," & opensslDir)
# begin Nimble config (version 2)
when fileExists(thisDir() & "/nimble.paths"):
  include "nimble.paths"
# end Nimble config
