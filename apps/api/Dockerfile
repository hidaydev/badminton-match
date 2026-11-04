# Build stage: the exact Nim version is pinned by tag and by deps.lock.
FROM nimlang/nim:2.4.0-bookworm AS build
WORKDIR /src
COPY config.nims deps.lock majadu.nimble ./
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

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*
RUN useradd --system --uid 10001 --home /nonexistent majadu
COPY --from=build /out/majadu-api /usr/local/bin/majadu-api
COPY --from=build /out/dbtools /usr/local/bin/dbtools
COPY --from=build /out/majadu-import /usr/local/bin/majadu-import
COPY --from=build /out/ownerseed /usr/local/bin/ownerseed
COPY --from=build /src/db /app/db
USER 10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/majadu-api"]
