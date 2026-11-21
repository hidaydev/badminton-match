## REL-BE-05: a failed rebuild is retried once and then reported, instead of
## being logged and forgotten. The retry bound and the source of the report are
## asserted here; the worker thread itself needs a database, so the integration
## set covers the run.

import std/[os, strutils, unittest]
import ../infrastructure/jobs

let jobsSource = readFile(currentSourcePath().parentDir /
  "../infrastructure/jobs.nim")

suite "failed rating job":
  test "the first failure retries and the second gives up":
    # 0 is the first run, so a failure at 0 retries once and a failure at 1
    # stops. Without this bound a broken rebuild would spin forever.
    check retryAfterFailure(0)
    check not retryAfterFailure(1)
    check not retryAfterFailure(2)
    check maxAttempts == 2

  test "the attempt count is carried with the job, not a table column":
    ## The queue is in-memory and a restart loses it, so the count rides on the
    ## job; a schema column here would promise durability the module does not
    ## have.
    check jobsSource.contains("attempts: int")
    check jobsSource.contains("attempts: attempt")

  test "a failure reaches the registry through the callback the edge passes in":
    # The rating module must not import the API edge's metrics, so `newApp`
    # supplies the counter and this pins both halves of that wiring.
    let appSource = readFile(currentSourcePath().parentDir /
      "../../../apps/api/src/app.nim")
    let serverSource = readFile(currentSourcePath().parentDir /
      "../../../apps/api/src/server.nim")
    check appSource.contains("recordRatingJobFailed()")
    check serverSource.contains("""registry.inc("rating_jobs_failed")""")

  test "a job that cannot be run says so instead of vanishing":
    check jobsSource.contains("rating job gave up after its retry")
