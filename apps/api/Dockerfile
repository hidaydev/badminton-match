# Build stage: the exact Nim version is pinned by tag and by deps.lock.
FROM nimlang/nim:2.4.0-bookworm AS build
WORKDIR /src
COPY config.nims deps.lock majadu.nimble ./
COPY task.d/deps-install.sh ./task.d/deps-install.sh
# The base image starts with an empty ~/.nimble and nimble.paths is not part of
# the build, so the exact packages pinned in deps.lock are installed first.
RUN sh task.d/deps-install.sh
COPY shared ./shared
COPY apps/api ./apps/api
COPY db ./db
COPY tools ./tools
RUN nim c -d:release --opt:speed --stackTrace:on --lineTrace:on \
      --threads:on --mm:atomicArc \
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

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 ca-certificates tzdata \
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
