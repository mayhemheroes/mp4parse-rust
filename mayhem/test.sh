#!/usr/bin/env bash
#
# mp4parse-rust/mayhem/test.sh — RUN the project's OWN upstream test suite and
# emit a CTRF summary. exit 0 iff no test failed.
#
# Mirrors upstream CI (.github/workflows/build.yml) test invocations:
#   cargo test --all                                     (default features)
#   cargo test --all --features missing-pixi-permitted
# These are real known-answer suites: mp4parse's unit tests (src/tests.rs) and
# integration tests (tests/public.rs & friends) parse dozens of checked-in
# mp4/avif/3gp assets and assert exact parsed structure (track counts, codecs,
# dimensions, expected-error results for corrupt files); mp4parse_capi's tests
# assert the C API surface. A no-op / exit(0) patch FAILS these oracles.
# (Upstream CI's release-mode repeats of the same tests and the fmt/clippy lints
# are not re-run here — identical assertions / style-only.)
#
# Everything was compiled by mayhem/build.sh (cargo test --no-run, normal
# flags) — this script only RUNS the pre-built tests (offline-safe).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASSED=0; FAILED=0; SKIPPED=0; RC=0
LOG="$SRC/mayhem-test.log"
: > "$LOG"

# run_suite <label> <cargo test args...>
# Runs one upstream `cargo test` invocation and accumulates the libtest
# "test result: ok. N passed; M failed; S ignored; ..." summary lines.
run_suite() {
  local label="$1"; shift
  echo "=== running: cargo test $* ($label) ==="
  local out rc=0
  out="$(cargo test "$@" 2>&1)" || rc=$?
  echo "$out" | tail -25
  echo "$out" >> "$LOG"
  local p f s
  read -r p f s <<<"$(echo "$out" | awk '
    /^test result: / { for (i=1;i<=NF;i++) { if ($(i+1)=="passed;") P+=$i; if ($(i+1)=="failed;") F+=$i; if ($(i+1)=="ignored;") S+=$i } }
    END { printf "%d %d %d", P+0, F+0, S+0 }')"
  : "${p:=0}" "${f:=0}" "${s:=0}"
  if [ "$(( p + f + s ))" -eq 0 ]; then
    # No libtest summaries at all (build error / neutered runner) — that's a failure.
    echo "ERROR: no test results parsed from '$label' (rc=$rc)" >&2
    f=1
  fi
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then f=1; fi   # honest on non-zero exits
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); SKIPPED=$(( SKIPPED + s ))
  [ "$rc" -ne 0 ] && RC=1
}

run_suite "default features"      --all
run_suite "missing-pixi-permitted" --all --features missing-pixi-permitted

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$SKIPPED"
