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

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*
RUN useradd --system --uid 10001 --home /nonexistent majadu
COPY --from=build /out/majadu-api /usr/local/bin/majadu-api
USER 10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/majadu-api"]
