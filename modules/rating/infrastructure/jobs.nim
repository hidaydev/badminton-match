## A bounded in-process queue for rating maintenance. The HTTP layer enqueues
## and returns; the worker replays the ledger and reconciles the badge shelf in
## the same order `tools/ratingingest` does. A request therefore never holds the
## community advisory lock or a pool connection for the length of a rebuild.

import std/[locks, os, times]
import clock
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
    ## Failed runs so far. The counter lives with the in-memory job instead of a
    ## table column: the queue is not durable (see `maxPendingJobs`), so a
    ## restart loses both the job and its attempt count together.
    attempts: int

  OnJobFailed* = proc(kind: JobKind, communityId: string)

  RatingJobs* = ref object
    ## One worker per process. `pending` is deduplicated by (kind, community),
    ## so a burst of admin clicks cannot queue the same replay twice.
    lock: Lock
    cond: Cond
    db: Db
    pending: seq[Job]
    nextId: int
    running: bool
    ## Set by the API so a failure reaches the process registry. The module
    ## cannot import the edge's metrics (that would point a domain helper at the
    ## app layer), so the edge hands its counter in at construction.
    onFailed: OnJobFailed
    ## The handle is kept alive for the process lifetime. `Thread` is passed to
    ## the runtime by reference, so a local would die with `start`.
    worker: Thread[WorkerArgs]

  WorkerArgs = object
    jobs: RatingJobs

const
  ## The queue is a courtesy, not durable storage: a restart loses it (accepted
  ## risk). The cap keeps a burst of admin clicks or many communities from
  ## turning the in-memory list into unbounded growth; a caller that cannot be
  ## queued is told to retry instead of waiting behind an endless backlog.
  maxPendingJobs* = 64
  ## REL-BE-05: one retry, so a transient failure (a statement timeout, an
  ## exhausted pool) gets a second chance and a persistent one stops instead of
  ## spinning. A rebuild is a full recompute, so running it twice is safe.
  maxAttempts* = 2

proc newRatingJobs*(db: Db, onFailed: OnJobFailed = nil): RatingJobs =
  result = RatingJobs(db: db, pending: @[], onFailed: onFailed)
  initLock(result.lock)
  initCond(result.cond)

proc enqueue*(jobs: RatingJobs, kind: JobKind, communityId: string): string =
  ## Returns the job id the route reports, or "" when the bounded queue is
  ## full. A duplicate joins the queued job instead of adding a second run of
  ## the same work, so the cap is only reached by distinct communities. A drop
  ## is logged with the work it lost: the write that triggered it already
  ## committed, so the caller cannot turn the refusal into a response.
  var dropped = false
  acquire(jobs.lock)
  try:
    for job in jobs.pending:
      if job.kind == kind and job.communityId == communityId:
        return job.id
    if jobs.pending.len >= maxPendingJobs:
      dropped = true
    else:
      inc jobs.nextId
      result = "rating-job-" & $jobs.nextId
      jobs.pending.add(Job(id: result, kind: kind, communityId: communityId))
      signal(jobs.cond)
  finally:
    release(jobs.lock)
  if dropped:
    logWarn("rating job dropped: queue is full",
      [("kind", $kind), ("community", communityId)])

proc retryAfterFailure*(attempts: int): bool =
  ## REL-BE-05: one retry, and the count that decides it is the attempt just
  ## spent. `attempts` is 0 for the first run, so a failure at 0 retries once and
  ## a failure at 1 gives up instead of spinning.
  attempts + 1 < maxAttempts

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

proc requeue(jobs: RatingJobs, job: Job) =
  ## Puts a failed job back at the head so the retry is the next thing the
  ## worker does, never queued behind a rebuild that arrived meanwhile. A job the
  ## caller has already enqueued again (same kind and community) is not added a
  ## second time: `enqueue` deduplicates, so the retry must too, and the higher
  ## attempt count wins so a duplicate cannot reset the bound.
  acquire(jobs.lock)
  try:
    var existing = -1
    for index in 0 ..< jobs.pending.len:
      if jobs.pending[index].kind == job.kind and
          jobs.pending[index].communityId == job.communityId:
        existing = index
        break
    if existing >= 0:
      if jobs.pending[existing].attempts < job.attempts:
        jobs.pending[existing].attempts = job.attempts
      return
    jobs.pending.insert(job, 0)
    signal(jobs.cond)
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
  let deadline = utcNow().toTime.toUnixFloat + timeoutMs.float / 1000.0
  while utcNow().toTime.toUnixFloat < deadline:
    if jobs.idle:
      return true
    sleep(5)
  jobs.idle

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
      # REL-BE-05: a failed rebuild used to be logged once and forgotten, so the
      # board kept stale numbers until some later write happened to enqueue
      # another one. The job is re-queued once — a rebuild is a full recompute,
      # so a second run is safe — and the failure is counted so a scrape and
      # `rating_jobs_failed` see it instead of only a log line.
      let attempt = job.attempts + 1
      {.cast(gcsafe).}:
        logError("rating job failed",
          [("job", job.id), ("community", job.communityId),
           ("attempt", $attempt), ("maxAttempts", $maxAttempts),
           ("error", error.msg)])
        if not args.jobs.onFailed.isNil:
          args.jobs.onFailed(job.kind, job.communityId)
      if retryAfterFailure(job.attempts):
        args.jobs.requeue(Job(id: job.id, kind: job.kind,
          communityId: job.communityId, attempts: attempt))
      else:
        {.cast(gcsafe).}:
          logError("rating job gave up after its retry",
            [("job", job.id), ("community", job.communityId),
             ("attempts", $attempt)])
    finally:
      args.jobs.done()

proc start*(jobs: RatingJobs) =
  createThread(jobs.worker, workerLoop, WorkerArgs(jobs: jobs))
