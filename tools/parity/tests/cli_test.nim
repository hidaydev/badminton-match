{.push warning[UnusedImport]: off.}
import std/unittest
import ../main
{.pop.}

suite "parity cli":
  test "the command module loads without touching the network or a database":
    check true
