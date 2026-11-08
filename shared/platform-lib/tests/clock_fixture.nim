## Test-only clock helpers. The file sits under `tests/` because no product code
## may call it: the application reads `clock.utcNow()` and never mutates the
## environment.
import std/os

template withPinnedClock*(stamp: string, body: untyped) =
  ## Pins `MAJADU_NOW` for the duration of `body` and restores whatever the
  ## process had before, including when `body` raises. A failed `check` does not
  ## raise, so the restore also holds when an assertion only records a failure.
  block:
    let hadPrevious = existsEnv("MAJADU_NOW")
    let previous = getEnv("MAJADU_NOW")
    putEnv("MAJADU_NOW", stamp)
    try:
      body
    finally:
      if hadPrevious:
        putEnv("MAJADU_NOW", previous)
      else:
        delEnv("MAJADU_NOW")