## SEC-05: the scanner exits 1 for any advisory, so the severity decision lives
## here. These cases fix the two properties the gate must keep: a HIGH or
## CRITICAL finding blocks, and a severity the database does not name blocks too
## instead of passing as harmless.

import std/[json, unittest]

import ../main as osvgate

proc finding(severity: string; id = "GHSA-test"; name = "left-pad";
             version = "1.0.0"): JsonNode =
  ## One report shaped like `osv-scanner scan source --format=json`.
  var vulnerability = %*{"id": id}
  if severity.len > 0:
    vulnerability["database_specific"] = %*{"severity": severity}
  %*{
    "results": [{
      "source": {"path": "pnpm-lock.yaml", "type": "lockfile"},
      "packages": [{
        "package": {"name": name, "version": version, "ecosystem": "npm"},
        "vulnerabilities": [vulnerability]
      }]
    }]
  }

suite "osvgate":
  test "a moderate and a low finding do not block":
    let findings = osvgate.collect(finding("MODERATE"))
    check findings.len == 1
    check osvgate.blockers(findings).len == 0
    check osvgate.blockers(osvgate.collect(finding("LOW"))).len == 0

  test "a high finding blocks and names the advisory and the package":
    let findings = osvgate.collect(finding("HIGH", id = "GHSA-high", name = "glob"))
    let found = osvgate.blockers(findings)
    check found.len == 1
    check found[0].id == "GHSA-high"
    check found[0].package == "glob"
    check found[0].version == "1.0.0"
    check found[0].source == "pnpm-lock.yaml"

  test "a critical finding blocks":
    check osvgate.blockers(osvgate.collect(finding("CRITICAL"))).len == 1

  test "a severity the database does not name blocks":
    # Fail closed: an advisory with only a CVSS vector is reported, not passed.
    let unnamed = %*{
      "results": [{
        "source": {"path": "pnpm-lock.yaml"},
        "packages": [{
          "package": {"name": "left-pad", "version": "1.0.0"},
          "vulnerabilities": [{"id": "OSV-1", "severity": [{"type": "CVSS_V3"}]}]
        }]
      }]
    }
    let findings = osvgate.collect(unnamed)
    check findings.len == 1
    check findings[0].severity == "UNKNOWN"
    check osvgate.blockers(findings).len == 1

  test "an empty report is a clean scan":
    check osvgate.collect(%*{}).len == 0
    check osvgate.collect(%*{"results": []}).len == 0

  test "a result with no packages is a clean scan":
    check osvgate.collect(%*{"results": [{"source": {"path": "x.lock"}}]}).len == 0
