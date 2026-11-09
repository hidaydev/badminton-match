import std/[algorithm, strutils, tables]

type
  Histogram* = object
    ## Cumulative buckets in the Prometheus sense: `buckets[i]` counts every
    ## observation at or below `histogramBounds[i]`.
    buckets*: seq[int64]
    total*: float64
    count*: int64

  Metrics* = object
    counters*: Table[string, int64]
    gauges*: Table[string, float64]
    histograms*: Table[string, Histogram]

const
  routeLabel = "route"
  ## Seconds. The bounds cover a healthy read (a few milliseconds) up to a
  ## rebuild-sized request, so the series answers a p95 question without
  ## inventing a bound per route.
  histogramBounds* = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5,
    5.0, 10.0]

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

proc checkLabels(labels: openArray[(string, string)]) =
  for (key, value) in labels:
    if key == routeLabel and value != templateRoute(value):
      raise newException(ValueError, "metric route label must be a template: " & value)

proc inc*(metrics: var Metrics, name: string,
          labels: openArray[(string, string)] = []) =
  checkLabels(labels)
  let key = labelKey(name, labels)
  metrics.counters[key] = metrics.counters.getOrDefault(key, 0) + 1

proc setGauge*(metrics: var Metrics, name: string, value: float64,
               labels: openArray[(string, string)] = []) =
  ## A gauge is a sample, not an event: the last writer wins. The pool size is
  ## written on every answer, so a scrape reads the state of the last request.
  checkLabels(labels)
  metrics.gauges[labelKey(name, labels)] = value

proc observe*(metrics: var Metrics, name: string, value: float64,
              labels: openArray[(string, string)] = []) =
  ## One observation of a histogram, in the unit its name declares (seconds for
  ## `http_request_duration_seconds`).
  checkLabels(labels)
  let key = labelKey(name, labels)
  var entry = metrics.histograms.getOrDefault(key)
  if entry.buckets.len == 0:
    entry.buckets = newSeq[int64](histogramBounds.len)
  entry.count.inc
  entry.total += value
  for index, bound in histogramBounds:
    if value <= bound:
      entry.buckets[index].inc
  metrics.histograms[key] = entry

proc render*(metrics: Metrics): string =
  ## Prometheus text exposition, sorted for deterministic tests.
  var lines: seq[string] = @[]
  for key in metrics.counters.keys:
    lines.add(key & " " & $metrics.counters[key])
  for key in metrics.gauges.keys:
    lines.add(key & " " & $metrics.gauges[key])
  for key in metrics.histograms.keys:
    let entry = metrics.histograms[key]
    # Split the rendered key back into its name and its labels: the bucket and
    # `_sum`/`_count` lines repeat the labels after the suffixed name.
    let brace = key.find('{')
    let base = if brace >= 0: key[0 ..< brace] else: key
    let labels = if brace >= 0: key[brace + 1 .. ^2] else: ""
    let withLabels =
      if labels.len > 0: "{" & labels & "}" else: ""
    let bucketLabels =
      if labels.len > 0: labels & "," else: ""
    for index, bound in histogramBounds:
      lines.add(base & "_bucket{" & bucketLabels & "le=\"" & $bound &
        "\"} " & $entry.buckets[index])
    lines.add(base & "_bucket{" & bucketLabels & "le=\"+Inf\"} " &
      $entry.count)
    lines.add(base & "_sum" & withLabels & " " & $entry.total)
    lines.add(base & "_count" & withLabels & " " & $entry.count)
  lines.sort()
  if lines.len == 0:
    ""
  else:
    lines.join("\n") & "\n"
