## Rate-limit scope comes from the contract route table, never from the raw
## path. An unmatched path shares one bucket, so a scanner cannot mint a pinned
## bucket per invented URL and push the global sweep into evicting live budgets.
import std/strutils
import routes_gen

const
  UnmatchedRoute* = "/unmatched"
  ## Paths served outside the generated contract. Each keeps its own fixed
  ## bucket; sharing "unmatched" would let 404 traffic starve readiness.
  FixedRoutes* = ["/ops/ping"]

proc matches(pattern, actual: seq[string]): bool =
  if pattern.len != actual.len:
    return false
  for index in 0 ..< pattern.len:
    let expected = pattern[index]
    if expected.len >= 2 and expected[0] == '{' and expected[^1] == '}':
      # A path parameter always stands for one non-empty segment.
      if actual[index].len == 0:
        return false
    elif expected != actual[index]:
      return false
  true

let patterns* = block:
  ## One entry per distinct contract path. Methods share a path, so the label
  ## is chosen from the shape alone.
  var built: seq[(string, seq[string])] = @[]
  for spec in routes:
    let parts = spec.path.split('/')
    var known = false
    for (_, existing) in built:
      if existing == parts:
        known = true
        break
    if not known:
      built.add((spec.path, parts))
  built

proc quotaRoute*(path: string): string =
  for fixed in FixedRoutes:
    if path == fixed:
      return path
  let actual = path.split('/')
  for (shape, pattern) in patterns:
    if matches(pattern, actual):
      return shape
  UnmatchedRoute
