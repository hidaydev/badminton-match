.PHONY: help dev dev-api build-web build-api check-web check-api

help:
	@echo "Majadu monorepo commands:"
	@echo "  make dev        - Run web dev server (Vite)"
	@echo "  make dev-api    - Run Go backend API server"
	@echo "  make build-web  - Build web for production"
	@echo "  make build-api  - Build Go backend binary"
	@echo "  make check-web  - Full web validation (types+lint+tailwind+regression)"
	@echo "  make check-api  - Go vet + fmt + tests"

dev:
	cd apps/web && npm run dev

dev-api:
	cd apps/api && go run ./cmd/server

build-web:
	cd apps/web && npm run build

build-api:
	cd apps/api && go build -o bin/majadu-api ./cmd/server

check-web:
	cd apps/web && npm run check

check-api:
	cd apps/api && make check