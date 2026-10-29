#!/usr/bin/env bash
#
# mayhem/test.sh — RUN mruby's own test suite (mrbtest, built by mayhem/build.sh with normal flags).
# The suite is mruby's assert()-based unit tests for the embedded interpreter; we only parse its totals.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

RUNNER="$SRC/mruby/build/host/bin/mrbtest"
[ -x "$RUNNER" ] || { echo "missing $RUNNER (mayhem/build.sh should have built it)" >&2; emit_ctrf "mrbtest" 0 1 0; exit 1; }

out="$("$RUNNER" 2>&1)"; rc=$?
printf '%s\n' "$out" | tail -n 20

num() { printf '%s\n' "$out" | sed -n "s/^ *$1: *\([0-9][0-9]*\).*/\1/p" | tail -n 1; }
total="$(num Total)"; ok="$(num OK)"; ko="$(num KO)"; crash="$(num Crash)"; skip="$(num Skip)"

# A neutered or crashed runner prints no totals: that is a failure, never a pass.
if [ -z "$total" ] || [ -z "$ok" ] || [ "$total" -lt 1000 ]; then
  echo "mrbtest produced no usable summary (rc=$rc)" >&2
  emit_ctrf "mrbtest" 0 1 0; exit 1
fi
failed=$(( ${ko:-0} + ${crash:-0} ))
[ "$rc" -eq 0 ] || failed=$(( failed > 0 ? failed : 1 ))
emit_ctrf "mrbtest" "$ok" "$failed" "${skip:-0}"
