# Build stage: the exact Nim version is pinned by tag and by deps.lock. The
# digest is the multi-arch manifest list published on 2026-11-01; Dependabot
# bumps it and ./task deps-check refuses a Dockerfile that drifts from deps.lock.
FROM docker.io/nimlang/nim:2.4.0@sha256:e35e49da9bb8a5d4562f9c4f8afc1945c9cdeb525b2a9b3e76431d0556ac0c8f AS build
# The API talks to Google over https, which needs `-d:ssl` and therefore the
# OpenSSL headers at compile time. The tools above do not, so the flag stays on
# the API line only.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY config.nims deps.lock majadu.nimble VERSION ./
COPY task.d/deps-install.sh ./task.d/deps-install.sh
# The base image starts with an empty ~/.nimble and nimble.paths is not part of
# the build, so the exact packages pinned in deps.lock are installed first.
RUN sh task.d/deps-install.sh
COPY shared ./shared
COPY modules ./modules
COPY apps/api ./apps/api
COPY db ./db
COPY tools ./tools
# The content gate must run on the path that produces the deployed image, not
# only in a CI job. The npm packages, the Playwright builds and the fonts live
# outside this build context, and the compiler is pinned by the base image
# digest, so those kinds are skipped; the Nim packages are verified against
# deps.lock's content hashes and the two FROM digests are read back from this
# file, so a moved tag or an unpinned base image fails the build here.
# One COPY per source. With several sources Docker copies the *contents* of a
# directory source into the destination, so `COPY task task.d ./` left
# `/src/task.d` holding only the file copied above and the gate below answered
# "Unknown target: deps-check".
COPY task ./task
COPY task.d ./task.d
RUN sh task deps-check --skip npm,playwright-browser,repo,toolchain
# `appVersion` is read from the VERSION file at compile time; the commit only
# exists in the build arguments, which is what `/version` reports back and what
# makes a running container traceable to a revision.
ARG APP_VERSION=""
ARG APP_COMMIT="unknown"
RUN APP_VERSION="${APP_VERSION:-$(cat VERSION)}" && \
    nim c -d:release --opt:speed --stackTrace:on --lineTrace:on \
      --threads:on --mm:atomicArc -d:ssl \
      -d:appVersion="$APP_VERSION" -d:appCommit="$APP_COMMIT" \
      --nimcache:/tmp/nimcache -o:/out/majadu-api apps/api/src/main.nim
# The cutover runs on the VPS, which has no Nim toolchain: migrations, the ETL
# and the first-owner seed therefore ship in the same image as the API, so the
# operator runs the exact code of the release instead of building at 3 a.m.
RUN nim c -d:release --opt:speed --threads:on --mm:atomicArc \
      --nimcache:/tmp/nimcache-tools -o:/out/dbtools tools/dbtools/main.nim
RUN nim c -d:release --opt:speed --threads:on --mm:atomicArc \
      --nimcache:/tmp/nimcache-import -o:/out/majadu-import tools/import/main.nim
RUN nim c -d:release --opt:speed --threads:on --mm:atomicArc \
      --nimcache:/tmp/nimcache-owner -o:/out/ownerseed tools/ownerseed/main.nim
# The daily rank snapshot runs from the same image as a systemd timer.
RUN nim c -d:release --opt:speed --threads:on --mm:atomicArc \
      --nimcache:/tmp/nimcache-snapshot -o:/out/ranksnapshot tools/ranksnapshot/main.nim
# The ingest tick is what moves the board after a session is approved; without
# it asOf stays on the last rated event and the 12-week window never moves.
RUN nim c -d:release --opt:speed --threads:on --mm:atomicArc \
      --nimcache:/tmp/nimcache-ingest -o:/out/ratingingest tools/ratingingest/main.nim
# Retention runs on the VPS too, where there is no Nim toolchain: the janitor
# (application role), the audit pruner (owner role) and account anonymisation
# are shipped as binaries and started by their own timers.
RUN nim c -d:release --opt:speed --threads:on --mm:atomicArc \
      --nimcache:/tmp/nimcache-janitor -o:/out/janitorcli tools/janitorcli/main.nim
RUN nim c -d:release --opt:speed --threads:on --mm:atomicArc \
      --nimcache:/tmp/nimcache-audit -o:/out/auditretention tools/auditretention/main.nim
RUN nim c -d:release --opt:speed --threads:on --mm:atomicArc \
      --nimcache:/tmp/nimcache-account -o:/out/account tools/accountlifecycle/main.nim

FROM docker.io/library/debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
# libpcre3 is the dynamic dependency of Nim's re module: the API and the ETL both
# import it, and without the shared object they abort at the first match.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 libpcre3 ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*
RUN useradd --system --uid 10001 --home /nonexistent majadu
COPY --from=build /out/majadu-api /usr/local/bin/majadu-api
COPY --from=build /out/dbtools /usr/local/bin/dbtools
COPY --from=build /out/majadu-import /usr/local/bin/majadu-import
COPY --from=build /out/ownerseed /usr/local/bin/ownerseed
COPY --from=build /out/ranksnapshot /usr/local/bin/ranksnapshot
# `account` is tools/accountlifecycle: the operator name is shorter than the
# directory that holds the implementation.
COPY --from=build /out/ratingingest /usr/local/bin/ratingingest
COPY --from=build /out/janitorcli /usr/local/bin/janitorcli
COPY --from=build /out/auditretention /usr/local/bin/auditretention
COPY --from=build /out/account /usr/local/bin/account
COPY --from=build /src/db /app/db
USER 10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/majadu-api"]
