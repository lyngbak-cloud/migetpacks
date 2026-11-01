#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
source "$ROOT_DIR/lib/common.sh"

assert() {
  local name="$1" condition="$2" detail="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  echo -n "Testing $name... "
  if eval "$condition"; then
    echo -e "${GREEN}PASSED${NC}"; TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo -e "${RED}FAILED${NC}"; [ -n "$detail" ] && echo "  $detail"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/build.log"

export REGISTRY_MIRROR="registry.eu-east-1.miget.io/mirror"
export OUTPUT_IMAGE="registry.eu-east-1.miget.io/miget123/app:1-abc"
export CACHE_IMAGE="registry.eu-east-1.miget.io/miget123/app-cache:latest"

cat > "$WORK/harbor-db-switchover.log" <<'EOF'
#7 [internal] load metadata for registry.eu-east-1.miget.io/mirror/library/node:24-slim
#7 ERROR: failed to copy: httpReadSeeker: failed open: unexpected status from GET request to https://registry.eu-east-1.miget.io/v2/mirror/library/node/manifests/sha256:c86ecead9e55a5210ac1727de38a4ca840bf03dcaf34dc9749addbf383b1920c: 401 Unauthorized
unauthorized: failed to connect to `user=harbor database=registry`: 10.43.231.106:5432 (harbor-db-rw.harbor.svc.cluster.local): server error: FATAL: the database system is shutting down (SQLSTATE 57P03)
ERROR: failed to build: failed to solve: failed to copy: httpReadSeeker: failed open: unexpected status from GET request to https://registry.eu-east-1.miget.io/v2/mirror/library/node/manifests/sha256:c86e: 401 Unauthorized
EOF

cat > "$WORK/own-registry-401.log" <<'EOF'
ERROR: failed to solve: failed to fetch anonymous token: unexpected status from GET request to https://registry.eu-east-1.miget.io/service/token?scope=repository: 401 Unauthorized
EOF

cat > "$WORK/registry-503.log" <<'EOF'
ERROR: failed to solve: ghcr.io/acme/base:1: failed to resolve source metadata for ghcr.io/acme/base:1: unexpected status from HEAD request to https://ghcr.io/v2/acme/base/manifests/1: 503 Service Unavailable
EOF

cat > "$WORK/registry-timeout.log" <<'EOF'
ERROR: failed to solve: node:24-slim: failed to resolve source metadata for docker.io/library/node:24-slim: failed to do request: Head "https://registry-1.docker.io/v2/library/node/manifests/24-slim": dial tcp 52.1.1.1:443: i/o timeout
EOF

cat > "$WORK/dockerhub-401.log" <<'EOF'
ERROR: failed to solve: acme/private:1: failed to resolve source metadata for docker.io/acme/private:1: unexpected status from HEAD request to https://registry-1.docker.io/v2/acme/private/manifests/1: 401 Unauthorized
EOF

cat > "$WORK/app-failure.log" <<'EOF'
#12 [build 5/7] RUN npm run build
#12 ERROR: process "/bin/sh -c npm run build" did not complete successfully: exit code: 1
ERROR: failed to solve: process "/bin/sh -c npm run build" did not complete successfully: exit code: 1
EOF

assert "harbor db switchover 401 is transient" 'is_transient_registry_error "$WORK/harbor-db-switchover.log"'
assert "401 from our own registry is transient" 'is_transient_registry_error "$WORK/own-registry-401.log"'
assert "503 from any registry is transient" 'is_transient_registry_error "$WORK/registry-503.log"'
assert "registry request timeout is transient" 'is_transient_registry_error "$WORK/registry-timeout.log"'
assert "401 from a foreign registry is not transient" '! is_transient_registry_error "$WORK/dockerhub-401.log"'
assert "application build failure is not transient" '! is_transient_registry_error "$WORK/app-failure.log"'
assert "missing log is not transient" '! is_transient_registry_error "$WORK/does-not-exist.log"'

filter_buildx_output() { cat >/dev/null; }
SLEPT=""
sleep() { SLEPT="$SLEPT $1"; }

run_with_fake_docker() {
  local outcomes="$1"; shift
  echo 0 > "$WORK/calls"
  docker() {
    local n outcome
    n=$(( $(cat "$WORK/calls") + 1 ))
    echo "$n" > "$WORK/calls"
    outcome=$(echo "$outcomes" | cut -d, -f"$n")
    case "$outcome" in
      ok) echo "#10 DONE"; return 0 ;;
      transient) cat "$WORK/harbor-db-switchover.log"; return 1 ;;
      *) cat "$WORK/app-failure.log"; return 1 ;;
    esac
  }
  SLEPT=""
  if buildx_with_retry "$LOG" "$@"; then RESULT=0; else RESULT=1; fi
  CALLS=$(cat "$WORK/calls")
  unset -f docker
}

BUILD_RETRY_ATTEMPTS=3 BUILD_RETRY_DELAY=15 run_with_fake_docker "transient,transient,ok" --push .
assert "retries transient failures until success" '[ "$RESULT" = 0 ] && [ "$CALLS" = 3 ]' "result=$RESULT calls=$CALLS"
assert "backs off between attempts" '[ "$SLEPT" = " 15 30" ]' "slept:$SLEPT"
assert "log holds the successful attempt" 'grep -q "#10 DONE" "$LOG" && ! grep -q "shutting down" "$LOG"'

BUILD_RETRY_ATTEMPTS=3 BUILD_RETRY_DELAY=15 run_with_fake_docker "app" --push .
assert "application failure is not retried" '[ "$RESULT" = 1 ] && [ "$CALLS" = 1 ] && [ -z "$SLEPT" ]' "result=$RESULT calls=$CALLS slept:$SLEPT"
assert "log keeps the application error" 'grep -q "npm run build" "$LOG"'

BUILD_RETRY_ATTEMPTS=3 BUILD_RETRY_DELAY=15 run_with_fake_docker "transient,transient,transient,ok" --push .
assert "gives up after the attempt limit" '[ "$RESULT" = 1 ] && [ "$CALLS" = 3 ]' "result=$RESULT calls=$CALLS"

unset BUILD_RETRY_ATTEMPTS BUILD_RETRY_DELAY
run_with_fake_docker "transient,ok" --push .
assert "defaults to retrying" '[ "$RESULT" = 0 ] && [ "$CALLS" = 2 ] && [ "$SLEPT" = " 15" ]' "result=$RESULT calls=$CALLS slept:$SLEPT"

passes_args() {
  docker() { [ "$1 $2 $3" = "buildx build --push" ] && [ "$4" = "my dir" ]; }
  buildx_with_retry "$LOG" --push "my dir"
  local rc=$?
  unset -f docker
  return $rc
}
assert "passes build arguments through unchanged" 'passes_args'

echo ""
echo "Tests: $TESTS_RUN, passed: $TESTS_PASSED, failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
