const
  AppVersion* {.strdefine.} = "dev"
  GitCommit* {.strdefine.} = "unknown"

proc buildInfoJson*(workerThreads: int): string =
  ## Stable shape so `/version` and the startup log cannot drift apart.
  """{"version":""" & "\"" & AppVersion & "\"" &
    ""","commit":""" & "\"" & GitCommit & "\"" &
    ""","worker_threads":""" & $workerThreads & "}"
