#!/usr/bin/env node
// Repeatable load test for the capacity statement in docs/ops/operations.md.
//
//   node ops/scripts/loadtest.mjs --http https://api.qouver.com/majadu/readyz \
//     --requests 10000 --concurrency 50
//   node ops/scripts/loadtest.mjs --http ... --ws-file ws-urls.txt --hold-ms 60000
//
// `--ws-file` is one complete watcher WebSocket URL per line, because every
// watcher ticket is single-use: the operator mints them from the API before the
// run rather than reusing one. Without a file the HTTP half runs alone.
//
// Node 22+ has fetch and WebSocket as globals; this script has no dependencies.
// It prints one JSON object and exits non-zero when any request or socket fails,
// so it can be the command in the T-074 record.
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

function option(name, fallback) {
  const index = process.argv.indexOf(name);
  return index >= 0 && index + 1 < process.argv.length
    ? process.argv[index + 1]
    : fallback;
}

const httpUrl = option("--http", "");
const requests = Number(option("--requests", "1000"));
const concurrency = Number(option("--concurrency", "20"));
const wsFile = option("--ws-file", "");
const holdMs = Number(option("--hold-ms", "30000"));
const timeoutMs = Number(option("--timeout-ms", "5000"));
// The API process to sample, so a run reports memory as well as latency. The
// capacity statement is about a 512 MB container limit; latency alone cannot
// tell an OOM from a slow reply.
const pid = option("--pid", "");

function rssKb() {
  if (!pid) return null;
  try {
    const value = Number(execFileSync("ps", ["-o", "rss=", "-p", pid], {
      encoding: "utf8",
    }).trim());
    return Number.isFinite(value) ? value : null;
  } catch {
    return null;
  }
}

if (!httpUrl && !wsFile) {
  console.error("loadtest: pass --http and/or --ws-file");
  process.exit(2);
}

const latencies = [];
let failures = 0;

async function oneRequest() {
  const started = performance.now();
  try {
    const response = await fetch(httpUrl, {
      signal: AbortSignal.timeout(timeoutMs),
    });
    await response.arrayBuffer();
    if (!response.ok) failures += 1;
  } catch {
    failures += 1;
  }
  latencies.push(performance.now() - started);
}

async function runHttp() {
  if (!httpUrl || requests <= 0) return;
  let next = 0;
  const workers = Array.from({ length: Math.max(1, concurrency) }, async () => {
    while (next < requests) {
      next += 1;
      await oneRequest();
    }
  });
  await Promise.all(workers);
}

function percentile(values, fraction) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * fraction))];
}

async function runWatchers() {
  if (!wsFile) return { opened: 0, errors: 0, expected: 0 };
  const urls = readFileSync(wsFile, "utf8")
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  let opened = 0;
  let errors = 0;
  const sockets = [];
  await Promise.all(
    urls.map(
      (url) =>
        new Promise((resolve) => {
          const socket = new WebSocket(url);
          sockets.push(socket);
          socket.addEventListener("open", () => {
            opened += 1;
            resolve();
          });
          socket.addEventListener("error", () => {
            errors += 1;
            resolve();
          });
        }),
    ),
  );
  await new Promise((resolve) => setTimeout(resolve, holdMs));
  for (const socket of sockets) socket.close();
  return { opened, errors, expected: urls.length };
}

const startedAt = Date.now();
const rssBefore = rssKb();
let rssPeak = rssBefore ?? 0;
const sampler = pid
  ? setInterval(() => {
      const value = rssKb();
      if (value !== null && value > rssPeak) rssPeak = value;
    }, 250)
  : null;
const watchers = await runWatchers();
const httpStarted = Date.now();
await runHttp();
if (sampler) clearInterval(sampler);
const rssAfter = rssKb();

const report = {
  http: {
    url: httpUrl,
    requests: latencies.length,
    failures,
    durationMs: Date.now() - httpStarted,
    p50Ms: Number(percentile(latencies, 0.5).toFixed(1)),
    p95Ms: Number(percentile(latencies, 0.95).toFixed(1)),
    p99Ms: Number(percentile(latencies, 0.99).toFixed(1)),
  },
  process: {
    pid: pid || null,
    rssKbBefore: rssBefore,
    rssKbAfter: rssAfter,
    rssPeakKb: pid ? rssPeak : null,
  },
  watchers,
  wallMs: Date.now() - startedAt,
};
console.log(JSON.stringify(report));

const watcherFailed = watchers.errors > 0 || watchers.opened !== watchers.expected;
if (failures > 0 || watcherFailed) process.exit(1);
