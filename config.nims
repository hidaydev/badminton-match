# The compiler evaluates this file inside the NimScript VM. Every builtin is
# qualified with `system.` because editors that check this file also import the
# `nimscript` module, which would otherwise make `switch`, `thisDir` and friends
# ambiguous between the two copies of the same routine.
system.switch("path", system.thisDir() & "/shared")
system.switch("path", system.thisDir() & "/shared/platform-lib")
system.switch("path", system.thisDir() & "/modules")
system.switch("path", system.thisDir() & "/apps")
system.switch("path", system.thisDir() & "/tools")

# `nim check config.nims` treats the config as the target project too, and
# --mm:atomicArc makes the checker fail inside system.nim. When the target is the
# config file itself the switches are skipped, so that check stays clean; every
# real build still gets them.
when system.projectName() != "config":
  system.switch("threads", "on")
  system.switch("mm", "atomicArc")
  system.switch("stackTrace", "on")
  system.switch("lineTrace", "on")

# Local libpq resolution on macOS. Homebrew keeps libpq outside the default
# dyld search path, and macOS strips DYLD_* from protected shells, so an rpath
# is the only reliable option. Override MAJADU_LIBPQ_DIR for other layouts.
when defined(macosx):
  block:
    let libpqDir = system.getEnv("MAJADU_LIBPQ_DIR",
      "/opt/homebrew/opt/postgresql@18/lib/postgresql")
    if system.dirExists(libpqDir):
      system.switch("passL", "-Wl,-rpath," & libpqDir)

# OpenSSL 3 is a keg on macOS; same rpath reasoning as libpq above.
when defined(macosx):
  block:
    let opensslDir = system.getEnv("MAJADU_OPENSSL_DIR",
      "/opt/homebrew/opt/openssl@3/lib")
    if system.dirExists(opensslDir):
      system.switch("passL", "-Wl,-rpath," & opensslDir)
# begin Nimble config (version 2)
when system.fileExists(system.thisDir() & "/nimble.paths"):
  include "nimble.paths"
# end Nimble config
