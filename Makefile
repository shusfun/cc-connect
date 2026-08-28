APP        := cc-connect
MODULE     := github.com/shusfun/cc-connect
CMD        := ./cmd/cc-connect
CONTROL_CMD := ./cmd/cc-connect-control
RUNTIME_CMD := ./cmd/cc-connect-runtime
DEPLOY_HOST_CMD := ./cmd/cc-connect-deploy-host
DIST       := dist
MACOSX_DEPLOYMENT_TARGET ?= 13.0

VERSION := v0.4.0
COMMIT     := $(shell git rev-parse --short HEAD 2>/dev/null || echo "none")
BUILD_TIME := $(shell date -u '+%Y-%m-%dT%H:%M:%SZ')

LDFLAGS := -s -w \
  -X main.version=$(VERSION) \
  -X main.commit=$(COMMIT) \
  -X main.buildTime=$(BUILD_TIME)

.PHONY: build build-control build-server build-runtime build-desktop build-deploy-host run clean test test-fast test-full test-smoke test-e2e test-release test-release-local test-performance pre-test lint release-all web

web:
	pnpm --dir web install --frozen-lockfile
	pnpm --dir web build

build: web
	go build -ldflags "$(LDFLAGS)" -o $(APP) $(CMD)

build-control: web
	go build -ldflags "$(LDFLAGS)" -o cc-connect-control $(CONTROL_CMD)

build-server: web
	go build -ldflags "$(LDFLAGS)" -o cc-connect-server $(CMD)

build-runtime:
	go build -ldflags "-s -w -X main.version=$(VERSION)" -o cc-connect-runtime $(RUNTIME_CMD)

build-desktop:
	mkdir -p $(DIST)
	MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) \
		CGO_CFLAGS="-mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET)" \
		CGO_LDFLAGS="-mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET)" \
		go build -ldflags "-s -w -X main.version=$(VERSION)" -o $(DIST)/CC-Connect ./desktop

build-deploy-host:
	go build -ldflags "$(LDFLAGS)" -o cc-connect-deploy-host $(DEPLOY_HOST_CMD)

run: build
	./$(APP)

clean:
	rm -f $(APP)
	rm -f cc-connect-control cc-connect-server cc-connect-runtime cc-connect-deploy-host
	rm -rf $(DIST)

# ---------------------------------------------------------------------------
# Testing targets.
#
# test-fast:  Unit tests + smoke tests (< 2 min). Runs on every push.
# test-full:   Full test suite including regression (< 10 min). PR requirement.
# test-smoke:  Smoke tests only (< 1 min). Quick sanity check.
# test-e2e:    E2E and regression tests only.
# test-release: Full + performance benchmarks. Before release.
# pre-test:    Prerequisites (build + vet) before running tests.
# ---------------------------------------------------------------------------

pre-test:
	go build ./...
	go vet ./...

# Fast test: unit tests + smoke tests
test-fast: pre-test
	go test -parallel=4 -race ./...
	go test -parallel=4 -tags=smoke ./tests/e2e/...

# Full test: unit + smoke + regression (PR requirement)
test-full: pre-test
	go test -parallel=4 -race ./...
	go test -parallel=4 -tags=smoke ./tests/e2e/...
	go test -parallel=2 -tags=regression ./tests/e2e/...

# Smoke tests only
test-smoke: pre-test
	go test -v -tags=smoke ./tests/e2e/...

# E2E/regression tests only
test-e2e: pre-test
	go test -v -tags=regression ./tests/e2e/...

# Performance benchmarks only
test-performance: pre-test
	go test -bench=. -benchmem -tags=performance ./tests/performance/...

# Release test: full + performance benchmarks
test-release: pre-test
	go test -parallel=4 -race ./...
	go test -parallel=4 -tags=smoke ./tests/e2e/...
	go test -parallel=2 -tags=regression ./tests/e2e/...
	go test -bench=. -benchmem -tags=performance ./tests/performance/...

# Release-local gate: deterministic release checks that do not require real IM
# credentials, real provider accounts, or supervisor-managed services.
test-release-local:
	go test ./tests/release_local/...
	go test ./config
	go test ./core -run 'TestEngineSendToSessionWithAttachments|TestProcessInteractiveEvents_SuppressesDuplicateSideChannelText|TestCmdList_AllSessionsVisibleAfterRepeatedNew|TestCmdList_SessionVisibleDuringAgentProcessing|TestEngine_Alias|TestEngine_BannedWords|TestEngine_DisabledCommands'
	go test ./platform/feishu -run 'TestUserIDFromEventFallsBackToUserID|TestResolveUserNameSkipsInvalidLookupID|TestNew_CanDisableInteractiveCards'

# Legacy: runs unit tests only
test:
	go test -v ./...

lint:
	golangci-lint run ./...

release-all:
	@echo "Signed multi-platform releases are created only by .github/workflows/release.yml from a v* tag."
	@exit 1
