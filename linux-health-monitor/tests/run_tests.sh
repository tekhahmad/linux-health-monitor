#!/usr/bin/env bash
# Minimal dependency-free test runner for healthcheck.sh functions.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HM_PROC_DIR="$HERE/fixtures/proc" HM_CORES=2
# shellcheck source=../bin/healthcheck.sh
source "$HERE/../bin/healthcheck.sh"

PASS=0; FAIL=0
assert_eq() {  # name expected actual
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}

assert_eq "level_for below warn"   OK   "$(level_for 79 80 90)"
assert_eq "level_for at warn"      WARN "$(level_for 80 80 90)"
assert_eq "level_for at crit"      CRIT "$(level_for 90 80 90)"
assert_eq "level_for_days healthy" OK   "$(level_for_days 60 21 7)"
assert_eq "level_for_days warn"    WARN "$(level_for_days 10 21 7)"
assert_eq "level_for_days crit"    CRIT "$(level_for_days 3 21 7)"
assert_eq "json_escape quotes"     'a\"b\\c' "$(json_escape 'a"b\c')"

check_cpu
assert_eq "cpu pct from fixture (1.80 load / 2 cores)" 90 "$M_CPU"
assert_eq "cpu level CRIT at 90%" CRIT "${R_LEVEL[0]}"

check_memory
assert_eq "memory pct from fixture (75%)" 75 "$M_MEM"
assert_eq "memory level OK" OK "${R_LEVEL[1]}"

compute_overall
assert_eq "overall is worst level" CRIT "$OVERALL"

out=$(render_json)
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$out" 2>/dev/null
assert_eq "json output parses" 0 "$?"

echo; echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
