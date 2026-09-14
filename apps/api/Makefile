VERSION ?= dev
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo none)
DATE    ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -X majadu-api/internal/build.Version=$(VERSION) \
           -X majadu-api/internal/build.Commit=$(COMMIT) \
           -X majadu-api/internal/build.Date=$(DATE)

.PHONY: build run test test-integration vet fmt check docker-build

build:
	go build -ldflags "$(LDFLAGS)" -o bin/majadu-api ./cmd/server

run:
	go run ./cmd/server

test:
	go test ./...

# Integration test — butuh Postgres ber-schema (tunnel ke VPS). Test di-skip
# kalau env kosong, jadi target ini memaksa env terisi supaya tidak menipu.
test-integration:
	@if [ -z "$$MAJADU_TEST_DATABASE_URL" ]; then \
		echo "MAJADU_TEST_DATABASE_URL belum di-set."; \
		echo "Buka tunnel ke Postgres VPS, lalu contoh:"; \
		echo "  MAJADU_TEST_DATABASE_URL='postgres://...@localhost:15432/bm_test' MAJADU_TEST_DB_SCHEMA=bm_test make test-integration"; \
		exit 1; \
	fi
	@if [ -z "$$MAJADU_TEST_DB_SCHEMA" ]; then \
		echo "MAJADU_TEST_DB_SCHEMA belum di-set (mis. bm_test)."; \
		exit 1; \
	fi
	go test ./internal/store/ -count=1

vet:
	go vet ./...

fmt:
	gofmt -l .

check: vet fmt test

docker-build:
	podman build -t majadu-api:$(VERSION) .
