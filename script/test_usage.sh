#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-all}"
case "$MODE" in
  all|--benchmark) ;;
  *) echo "usage: $0 [all|--benchmark]" >&2; exit 2 ;;
esac
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/codexmeter-tests.XXXXXX")}"
mkdir -p "$WORK_DIR/fixtures"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
export CODEX_HEALTH_TEST_ROOT="$WORK_DIR/fixtures"
# Cleanup is an explicit opt-in after confirmation of the fixture targets.
export CODEX_HEALTH_TEST_CLEANUP="${CODEX_HEALTH_TEST_CLEANUP:-0}"
echo "Synthetic test fixtures and build retained at $WORK_DIR"
cd "$ROOT_DIR"
if [[ "$MODE" == --benchmark ]]; then
  CODEX_HEALTH_BENCHMARK=1 xcrun swift test --scratch-path "$WORK_DIR/build" --filter UsageBenchmarkTests
else
  xcrun swift test --scratch-path "$WORK_DIR/build"
fi
