import std/[algorithm, strutils, tables]

type
  Metrics* = object
    counters*: Table[string, int64]

const
  routeLabel = "route"

proc isIdSegment(segment: string): bool =
  if segment.len == 0:
    return false
  if segment.len == 36 and segment.count('-') == 4:
    return true
  for c in segment:
    if c notin {'0'..'9'}:
      return false
  true

proc templateRoute*(path: string): string =
  ## Collapses identifiers so metric labels never contain a code, slug or id.
  let parts = path.split('/')
  var segments: seq[string] = @[]
  for i, part in parts:
    var value = part
    if i >= 2 and parts[i - 1] == "s":
      value = "{code}"
    elif i >= 3 and parts[i - 2] == "ws" and parts[i - 1] == "share":
      value = "{code}"
    elif i == 2 and parts[i - 1] == "c":
      value = "{slug}"
    elif isIdSegment(part):
      value = "{id}"
    segments.add(value)
  result = segments.join("/")
  if result.len == 0:
    result = "/"

proc labelKey*(name: string, labels: openArray[(string, string)]): string =
  var rendered: seq[string] = @[]
  for (key, value) in labels:
    rendered.add(key & "=\"" & value & "\"")
  if rendered.len == 0:
    name
  else:
    name & "{" & rendered.join(",") & "}"

proc inc*(metrics: var Metrics, name: string, labels: openArray[(string, string)] = []) =
  for (key, value) in labels:
    if key == routeLabel and value != templateRoute(value):
      raise newException(ValueError, "metric route label must be a template: " & value)
  let key = labelKey(name, labels)
  metrics.counters[key] = metrics.counters.getOrDefault(key, 0) + 1

proc render*(metrics: Metrics): string =
  ## Prometheus text exposition, sorted for deterministic tests.
  var lines: seq[string] = @[]
  for key in metrics.counters.keys:
    lines.add(key & " " & $metrics.counters[key])
  lines.sort()
  if lines.len == 0:
    ""
  else:
    lines.join("\n") & "\n"
