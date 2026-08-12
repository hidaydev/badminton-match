VERSION ?= dev
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo none)
DATE    ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -X majadu-api/internal/build.Version=$(VERSION) \
           -X majadu-api/internal/build.Commit=$(COMMIT) \
           -X majadu-api/internal/build.Date=$(DATE)

.PHONY: build run test vet fmt check docker-build

build:
	go build -ldflags "$(LDFLAGS)" -o bin/majadu-api ./cmd/server

run:
	go run ./cmd/server

test:
	go test ./...

vet:
	go vet ./...

fmt:
	gofmt -l .

check: vet fmt test

docker-build:
	podman build -t majadu-api:$(VERSION) .
