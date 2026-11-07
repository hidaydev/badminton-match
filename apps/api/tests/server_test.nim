import std/[os, strutils, unittest]
import ../src/server

suite "process contract":
  test "MAJADU_PORT is required":
    delEnv("MAJADU_PORT")
    expect ValueError:
      discard loadConfig()

  test "MAJADU_PORT must be numeric":
    putEnv("MAJADU_PORT", "abc")
    putEnv("MAJADU_DRAIN_MS", "0")
    expect ValueError:
      discard loadConfig()

  test "MAJADU_PORT must fit in 16 bits":
    putEnv("MAJADU_PORT", "70000")
    putEnv("MAJADU_DRAIN_MS", "0")
    expect ValueError:
      discard loadConfig()

  test "MAJADU_DRAIN_MS is required":
    putEnv("MAJADU_PORT", "8080")
    delEnv("MAJADU_DRAIN_MS")
    expect ValueError:
      discard loadConfig()

  test "accepts a valid contract":
    putEnv("MAJADU_PORT", "8080")
    putEnv("MAJADU_DRAIN_MS", "0")
    delEnv("MAJADU_SHUTDOWN_TIMEOUT_MS")
    delEnv("MAJADU_METRICS_PORT")
    let config = loadConfig()
    check config.port.int == 8080
    check config.drainMs == 0
    check config.shutdownTimeoutMs == 30000
    check config.testRoutes == false
    check config.metricsPort == 0

suite "metrics listener":
  test "is off unless a port is configured":
    delEnv("MAJADU_METRICS_PORT")
    check loadMetricsPort() == 0

  test "a bad port refuses to start instead of hiding the listener":
    putEnv("MAJADU_METRICS_PORT", "not-a-port")
    expect ValueError:
      discard loadMetricsPort()
    putEnv("MAJADU_METRICS_PORT", "70000")
    expect ValueError:
      discard loadMetricsPort()
    delEnv("MAJADU_METRICS_PORT")

  test "counts the route template, never the raw path":
    discard recordResponse("GET", "/c/acme/clubs", 200)
    check metricsText().contains(
      """route="/c/{slug}/clubs",status="200"} 1""")

  test "unmatched paths share one bucket so a scanner cannot mint series":
    discard recordResponse("GET", "/nope/one", 404)
    discard recordResponse("GET", "/nope/two", 404)
    let text = metricsText()
    check text.contains("""method="GET",route="unmatched",status="404"}""")
    check not text.contains("/nope/one")

suite "healthz":
  test "returns ok without touching the database":
    let outcome = route("/healthz", testRoutes = false)
    check outcome.status == 200
    check outcome.body == """{"status":"ok"}"""

  test "unknown paths are 404":
    let outcome = route("/nope", testRoutes = false)
    check outcome.status == 404

  test "test route is disabled by default":
    let outcome = route("/__test/slow", testRoutes = false)
    check outcome.status == 404

  test "test route is reachable when enabled":
    let outcome = route("/__test/slow", testRoutes = true)
    check outcome.status == 200
