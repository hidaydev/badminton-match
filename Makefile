.PHONY: help dev dev-api build-web build-api check-web check-api check test ci e2e

# The source of truth is ./task. This file only keeps `make` muscle memory from
# running the wrong thing: every backend target forwards, none of them guess.

help:
	@echo "Majadu monorepo commands (./task has the full list):"
	@echo "  make dev        - Web dev server (Vite)"
	@echo "  make dev-api    - API on :8080 plus the OIDC stub"
	@echo "  make build-web  - Build the web bundle"
	@echo "  make build-api  - Build the Nim API binary"
	@echo "  make check-web  - TypeScript, ESLint, Tailwind guard, Vitest"
	@echo "  make check-api  - ./task check (no database)"
	@echo "  make test       - ./task test (needs MAJADU_PG_DSN)"
	@echo "  make ci         - ./task ci"
	@echo "  make e2e        - ./task e2e"

dev:
	pnpm dev

dev-api:
	./task dev

build-web:
	pnpm build:web

build-api:
	./task build

check-web:
	pnpm check:web

check-api check:
	./task check

test:
	./task test

ci:
	./task ci

e2e:
	./task e2e
