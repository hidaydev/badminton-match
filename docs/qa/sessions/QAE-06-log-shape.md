# QAE-06: what the process writes when it drops a body

Session of 2026-11-10 on `w3/qae` (based on `0e3000c1`), charter
`docs/qa/charter-http-boundary.md`. Scratch database `bm2_w3qa`, release build on
8098, no session cookie.

## The answered rejection

A body one byte over the configured limit is answered by the guard, and the
answer is logged like every other request:

```
{"ts":"2026-11-09T19:30:56Z","level":"info","msg":"request","method":"POST",
 "route":"/auth/start","status":"413",
 "request_id":"01a1c1ca-cf69-769c-96ce-1c2729a18ec7"}
```

Route label, status, method and a generated request id. This half of the finding
is fixed.

## The transport drop

A body past the 16 MiB ceiling is closed by mummy before a handler runs. The
line is JSON, and it has no route, no status and an empty request id:

```
{"ts":"2026-11-09T19:26:58Z","level":"debug","msg":"server",
 "detail":"Dropped connection, body too long","request_id":""}
```

`renderServerLog` (`apps/api/src/server.nim:179-200`) replaced the plain text
line the audit saw, so the journal parses. What the DoD also asked for is absent:
the request never reached the request chain, so `currentRequestId()` is empty,
there is no `route` and no `status`, and the level is `debug`, which a production
log filter may drop entirely.

## A second observation: the journal is written in 4 KiB chunks

The process writes to `stdout` through a block buffer when stdout is not a
terminal, and never flushes per line:

```
# after the process started and answered three requests
wc -c /tmp/w3qa-api.log
# 0

# after roughly forty more requests
wc -c /tmp/w3qa-api.log
# 4096
```

So an operator tailing the journal during an incident sees nothing until 4 KiB
of lines have accumulated, and then a chunk at once. That is not specific to
rejections, but it is why the check below writes traffic while it waits: reading
the file once after a request would be a race on a quiet machine and a flake on
a busy one.

## DoD status

"the rejection path emits the same JSON shape as every other request, including
a generated request id": **partly**.

- The shape is JSON with the same parser-visible fields, and the guarding path
  emits the full request line. Satisfied there.
- The transport path has no `request_id`, no `route` and no `status`, and it is
  logged at `debug`. Emitting a request id there means starting one before the
  body is read, which is a change to the request chain in `apps/api/src/server.nim`
  and `apps/api/src/main.nim`, so it is recorded, not changed.
- The 4 KiB buffering is a separate gap with the same owner: flush after each
  line, or the journal lags reality by a chunk.

## Permanent check

`e2e/api.spec.ts` holds the two properties that do hold:

- "the 413 is logged with route, status and a request id" counts the
  `/auth/start` 413 lines before and after sending one, so the line it parses
  can only be that request's.
- "no line the API writes is plain text" parses every line the file holds and
  requires `ts`, `level` and `msg` on each, which is the audit's plain text line
  returning as a failure.
- "the transport drop is a JSON line, not a bare sentence" sends 20 MiB and
  requires the new `body too long` line to parse with the same fields, including
  a `request_id` key.
