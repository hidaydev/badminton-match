## A bounded in-process queue for rating maintenance. The HTTP layer enqueues
## and returns; the worker replays the ledger and reconciles the badge shelf in
## the same order `tools/ratingingest` does. A request therefore never holds the
## community advisory lock or a pool connection for the length of a rebuild.

import std/[json, locks, options, os, times]
import db/db
import logger
import platform/config/store
import rating/infrastructure/ingest
import rating/infrastructure/params
import rating/read
import achievement/infrastructure/backfill

type
  JobKind* = enum
    jkRebuild
    jkReconcile

  Job = object
    id: string
    kind: JobKind
    communityId: string

  RatingJobs* = ref object
    ## One worker per process. `pending` is deduplicated by (kind, community),
    ## so a burst of admin clicks cannot queue the same replay twice.
    lock: Lock
    cond: Cond
    db: Db
    pending: seq[Job]
    nextId: int
    running: bool
    ## The handle is kept alive for the process lifetime. `Thread` is passed to
    ## the runtime by reference, so a local would die with `start`.
    worker: Thread[WorkerArgs]

  WorkerArgs = object
    jobs: RatingJobs

proc newRatingJobs*(db: Db): RatingJobs =
  result = RatingJobs(db: db, pending: @[])
  initLock(result.lock)
  initCond(result.cond)

proc enqueue*(jobs: RatingJobs, kind: JobKind, communityId: string): string =
  ## Returns the job id the route reports. A duplicate joins the queued job
  ## instead of adding a second run of the same work.
  acquire(jobs.lock)
  try:
    for job in jobs.pending:
      if job.kind == kind and job.communityId == communityId:
        return job.id
    inc jobs.nextId
    result = "rating-job-" & $jobs.nextId
    jobs.pending.add(Job(id: result, kind: kind, communityId: communityId))
    signal(jobs.cond)
  finally:
    release(jobs.lock)

proc take(jobs: RatingJobs): Job =
  acquire(jobs.lock)
  try:
    while jobs.pending.len == 0:
      wait(jobs.cond, jobs.lock)
    result = jobs.pending[0]
    jobs.pending.delete(0)
    jobs.running = true
  finally:
    release(jobs.lock)

proc done(jobs: RatingJobs) =
  acquire(jobs.lock)
  try:
    jobs.running = false
  finally:
    release(jobs.lock)

proc idle*(jobs: RatingJobs): bool =
  ## True when nothing is queued and the worker is not mid-job. The integration
  ## suites use it to read the board after a queued replay instead of sleeping
  ## for a guessed interval.
  acquire(jobs.lock)
  try:
    jobs.pending.len == 0 and not jobs.running
  finally:
    release(jobs.lock)

proc waitIdle*(jobs: RatingJobs, timeoutMs = 5000): bool =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    if jobs.idle:
      return true
    sleep(5)
  jobs.idle

proc communitySettings(db: Db, communityId: string): JsonNode =
  ## Read the way the CLI reads it, so the worker and a manual rebuild see the
  ## same L2 overrides.
  let row = db.queryOne(
    """select values::text as values from community.settings
       where community_id = $1::uuid""", @[textParam(communityId)])
  if row.isSome: parseJson(row.get.get("values")) else: newJObject()

proc process(jobs: RatingJobs, job: Job) =
  let snapshot = loadSnapshot(jobs.db)
  let params = loadRatingParams(snapshot,
    communitySettings(jobs.db, job.communityId))
  if job.kind == jkRebuild:
    discard rebuild(jobs.db, job.communityId, params)
  discard backfill(jobs.db, job.communityId,
    latestEventDate(jobs.db, job.communityId), params)

proc workerLoop(args: WorkerArgs) {.thread.} =
  while true:
    let job = take(args.jobs)
    try:
      {.cast(gcsafe).}:
        process(args.jobs, job)
    except CatchableError as error:
      {.cast(gcsafe).}:
        logError("rating job failed",
          [("job", job.id), ("community", job.communityId),
           ("error", error.msg)])
    finally:
      args.jobs.done()

proc start*(jobs: RatingJobs) =
  createThread(jobs.worker, workerLoop, WorkerArgs(jobs: jobs))
