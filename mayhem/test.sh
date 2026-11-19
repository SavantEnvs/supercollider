#!/usr/bin/env bash
# mayhem/test.sh — run SuperCollider's own test suites (built by mayhem/build.sh in build-tests/)
# and known-answer probes through the built CLIs. Emits CTRF; exit non-zero iff a test failed.
#   boost.test: sc_lexer_test, scsynth_test, readwrite_test, sc_msg_iter_test (counts parsed from
#               each module's report; a module that prints no report counts as one failure)
#   KAT probes: sc_lexer_standalone token stream, SCDoc parse tree of a help file, and an
#               `scsynth -N` render of a two-channel DC synthdef whose samples are checked exactly,
#               and sclang compiling the class library and evaluating a fixed script.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

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

T=build-tests
K=mayhem/kat
PASSED=0; FAILED=0
ok()   { PASSED=$((PASSED+1)); echo "PASS: $1"; }
fail() { FAILED=$((FAILED+1)); echo "FAIL: $1"; }

for t in langutils/sc_lexer/test/sc_lexer_test testsuite/server/scsynth/scsynth_test \
         testsuite/server/scsynth/readwrite_test testsuite/server/scsynth/sc_msg_iter_test; do
  name=$(basename "$t")
  if [ ! -x "$T/$t" ]; then fail "$name: not built"; continue; fi
  out=$("$T/$t" --report_level=short 2>&1); rc=$?
  echo "$out" | tail -4
  p=$(sed -nE 's/^ *([0-9]+) test cases? out of [0-9]+ passed.*/\1/p' <<<"$out" | head -n1)
  f=$(sed -nE 's/^ *([0-9]+) test cases? out of [0-9]+ failed.*/\1/p' <<<"$out" | head -n1)
  if [ -z "$p" ] && [ -z "$f" ]; then fail "$name: no boost.test report (rc=$rc)"; continue; fi
  PASSED=$((PASSED + ${p:-0})); FAILED=$((FAILED + ${f:-0}))
  if [ "$rc" -ne 0 ] && [ -z "$f" ]; then fail "$name: exit $rc"; fi
  echo "$name: passed=${p:-0} failed=${f:-0}"
done

# KAT 1: lexer token stream for a fixed snippet.
if diff -u "$K/lexer.expected" <("$T/langutils/sc_lexer/standalone/sc_lexer_standalone" 'x = 1 + 2.5; \sym' 2>&1); then
  ok "sc_lexer_standalone token stream"; else fail "sc_lexer_standalone token stream"; fi

# KAT 2: SCDoc parse tree of HelpSource/Classes/Latch.schelp (copied to mayhem/kat).
if diff -u "$K/Latch.expected" <("$T/scdoc/scdoc_cli" "$K/Latch.schelp" 2>&1); then
  ok "scdoc parse tree"; else fail "scdoc parse tree"; fi

# KAT 3: scsynth NRT render. katdc = Out.ar(0, [DC.ar(0.5), DC.ar(0.25)]) for 10 ms, then freed:
# 448 frames (7 blocks of 64) of int16 stereo, the first 6 blocks at (16384, 8192), the last silent.
work=$(mktemp -d "${TMPDIR:-/tmp}/sc-test-XXXXXX")
HOME="$work" "$T/server/scsynth/scsynth" -N "$K/katdc.osc" _ "$work/o.wav" 44100 WAV int16 -o 2 >"$work/log" 2>&1
hist=$(od -A n -t d2 -v -j 44 "$work/o.wav" 2>/dev/null | tr -s ' ' '\n' | sed '/^$/d' | sort -n | uniq -c | tr -s ' ' | tr '\n' ';')
if [ "$hist" = " 128 0; 384 8192; 384 16384;" ]; then ok "scsynth NRT render"; else
  cat "$work/log"; fail "scsynth NRT render (sample histogram '$hist')"; fi
rm -rf "$work"

# KAT 4: sclang compiles SCClassLibrary and evaluates mayhem/kat/eval.scd.
work=$(mktemp -d "${TMPDIR:-/tmp}/sc-test-XXXXXX")
printf 'includePaths:\n  - %s\nexcludePaths: []\nexcludeDefaultPaths: true\n' "$SRC/SCClassLibrary" > "$work/conf.yaml"
got=$(cd "$work" && HOME="$work" timeout 120 "$SRC/$T/lang/sclang" -u 57998 -l "$work/conf.yaml" "$SRC/$K/eval.scd" </dev/null 2>&1 \
      | sed -n 's/^KAT: //p')
if [ "$got" = "$(cat "$K/eval.expected")" ]; then ok "sclang eval"; else
  echo "got: $got"; fail "sclang eval"; fi
rm -rf "$work"

emit_ctrf "boost-test+kat" "$PASSED" "$FAILED" 0
