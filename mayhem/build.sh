#!/usr/bin/env bash
# mayhem/build.sh — build SuperCollider's fuzz harnesses and the test build mayhem/test.sh runs.
#
#   build-fuzz/   scsynth (libscsynth + static UGen plugins), libsclang, sc_lexer, utf8proc with
#                 $SANITIZER_FLAGS + SanitizerCoverage; SCDoc compiled directly. Harnesses:
#                 /mayhem/{scsynth_nrt,scsynth_synthdef,sclang_compile,sc_lexer,scdoc}_fuzzer
#                 (+ -standalone)
#   build-tests/  normal flags + ENABLE_TESTSUITE: upstream's boost.test suites (sc_lexer_test,
#                 scsynth_test, readwrite_test, sc_msg_iter_test), the scsynth CLI and
#                 sclang, sc_lexer_standalone, plus scdoc_cli from SCDoc/main.cpp (the test.sh probes).
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 0) Git submodules: a CI checkout has empty submodule directories. The Dockerfile caches the
#    pinned commits under /opt/toolchains/deps; copy them in (idempotent, offline).
for dep in nova-simd:b61e579ffd24004cc5c9f517714cbd30b14d0148 nova-tt:b497ec33a733c84d53e4295955d1033e0add7dae \
           utf8proc:b3e0f28adaec943ac25e3e27514dd6037e7a022e yaml-cpp:56e3bb550c91fd7005566f19c079cb7a503223cf; do
  name=${dep%%:*}; rev=${dep#*:}; dst="external_libraries/$name"
  if [ -z "$(ls -A "$dst" 2>/dev/null)" ]; then
    mkdir -p "$dst"; cp -a "/opt/toolchains/deps/$name-$rev/src/." "$dst/"; chmod -R u+w "$dst"
  fi
done

COMMON_CMAKE=(-G Ninja -DSC_QT=OFF -DSC_IDE=OFF -DSUPERNOVA=OFF -DSC_ABLETON_LINK=OFF -DSC_HIDAPI=OFF
  -DNO_X11=ON -DNO_AVAHI=ON -DSTATIC_PLUGINS=ON -DSC_EL=OFF -DSC_VIM=OFF -DINSTALL_HELP=OFF
  -DUSE_CCACHE=OFF -DNATIVE=OFF)

# 1) Sanitized + coverage-instrumented project build. SC_MEMORY_DEBUGGING turns off scsynth's own
#    real-time memory pool so ASan sees every allocation.
#    UBSan relaxation: include/plugin_interface/Hash.h's string hash (Hash(const char*), used for
#    every UGen/command name at startup) relies on wrapping int32 arithmetic, so the
#    signed-integer-overflow check fires before any input is read; and scsynth stores every node and
#    UGen calc function as a generic pointer type (Node::mCalcFunc, Unit::mCalcFunc) and calls it
#    through that type, so -fsanitize=function fires on the first rendered block; and Graph_New packs
#    every Unit struct into one block right after 4-byte float arrays (SC_Unit.cpp Unit_New), so
#    -fsanitize=alignment fires on every synth; and OffsetOut (in the stock "default" synthdef) does
#    Copy(0, m_saved=nullptr, ...) -> memcpy(NULL, p, 0) whenever its sample offset is 0
#    (server/plugins/IOUGens.cpp OffsetOut_next_a), so nonnull-attribute fires on nearly every score
#    (a real NULL access still faults under ASan); and sclang's clock sync
#    (lang/LangPrimSource/PyrSched.cpp, at start-up and from its resync thread) left-shifts a
#    negative seconds value, so shift-base fires before any input; and sclang's VM computes
#    &slotRawSymbolArray(&block->argNames)->symbols on a NULL array for argument-less blocks
#    (lang/LangSource/PyrMessage.cpp prepareArgsForExecute) while the class library starts up, so
#    the `null` member-access check fires before any input (real NULL dereferences still SEGV under
#    ASan). Only these six checks are off, and
#    only when sanitizers are on; ASan and the rest of UBSan stay halting.
UB_RELAX=""; case "$SANITIZER_FLAGS" in *undefined*) UB_RELAX="-fno-sanitize=signed-integer-overflow,function,alignment,nonnull-attribute,shift-base,null";; esac
FUZZ_FLAGS="$SANITIZER_FLAGS $UB_RELAX -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
cmake -S . -B build-fuzz "${COMMON_CMAKE[@]}" -DENABLE_TESTSUITE=OFF -DSC_MEMORY_DEBUGGING=ON \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_C_FLAGS_DEBUG="-O1" -DCMAKE_CXX_FLAGS_DEBUG="-O1" \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS"
cmake --build build-fuzz -j"$MAYHEM_JOBS" --target scsynth sclang sc_lexer utf8proc

# Compile flags (-D/-I/-std) libscsynth itself was built with, so the harness sees the same
# World/HiddenWorld layout; and the link inputs CMake uses for the scsynth executable.
B="$SRC/build-fuzz"
cmd_of() { (cd "$B" && ninja -t commands "$1") ; }
SCSYNTH_CMDS=$(cmd_of server/scsynth/scsynth)
SC_CFLAGS=$(grep 'SC_World\.cpp' <<<"$SCSYNTH_CMDS" | head -n1 | tr ' ' '\n' | grep -E '^(-D|-I|-std=)' | grep -v '\\"' | tr '\n' ' ')
SC_LIBS=$(tail -n1 <<<"$SCSYNTH_CMDS" | sed 's#.*-o server/scsynth/scsynth##; s#&& :##' | tr ' ' '\n' \
  | sed -e '/^$/d' -e "s#^\([a-z_][a-z_]*/\)#$B/\1#" | tr '\n' ' ')
SCLANG_CMDS=$(cmd_of lang/sclang)
LANG_CFLAGS=$(grep 'cmdLineFuncs\.cpp' <<<"$SCLANG_CMDS" | head -n1 | tr ' ' '\n' | grep -E '^(-D|-I|-std=)' | grep -v '\\"' | tr '\n' ' ')
LANG_LIBS=$(tail -n1 <<<"$SCLANG_CMDS" | sed 's#.*-o lang/sclang##; s#&& :##' | tr ' ' '\n' \
  | sed -e '/^$/d' -e "s#^\([a-z_][a-z_]*/\)#$B/\1#" | tr '\n' ' ')
[ -n "$SC_CFLAGS" ] && [ -n "$SC_LIBS" ] && [ -n "$LANG_CFLAGS" ] && [ -n "$LANG_LIBS" ] || { echo "could not read scsynth flags from build.ninja" >&2; exit 1; }

# SCDoc parser (flex/bison output is committed upstream); SCDocPrim.cpp is the sclang glue, left out.
mkdir -p "$B/scdoc"
for f in SCDoc SCDoc.tab lex.scdoc; do
  $CXX $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1 -std=c++17 -Wno-null-conversion -ISCDoc -c "SCDoc/$f.cpp" -o "$B/scdoc/$f.o"
done
SCDOC_OBJS="$B/scdoc/SCDoc.o $B/scdoc/SCDoc.tab.o $B/scdoc/lex.scdoc.o"

# 2) Harnesses: each linked twice, with libFuzzer and with the standalone run-once driver.
HB="$B/harness"; mkdir -p "$HB"
HFLAGS="$SANITIZER_FLAGS $UB_RELAX -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1"
$CXX $HFLAGS -c mayhem/lsan_off.cc -o "$HB/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$HB/standalone_main.o"
$CXX $HFLAGS $SC_CFLAGS -c mayhem/harnesses/scsynth_nrt_fuzzer.cpp -o "$HB/scsynth_nrt.o"
$CXX $HFLAGS $SC_CFLAGS -DSC_FUZZ_SYNTHDEF -c mayhem/harnesses/scsynth_nrt_fuzzer.cpp -o "$HB/scsynth_synthdef.o"
$CXX $HFLAGS $LANG_CFLAGS -c mayhem/harnesses/sclang_compile_fuzzer.cpp -o "$HB/sclang_compile.o"
$CXX $HFLAGS -std=c++20 -Ilangutils/sc_lexer/include -c mayhem/harnesses/sc_lexer_fuzzer.cpp -o "$HB/sc_lexer.o"
$CXX $HFLAGS -std=c++17 -ISCDoc -c mayhem/harnesses/scdoc_fuzzer.cpp -o "$HB/scdoc.o"
LEXER_LIBS="$B/langutils/sc_lexer/libsc_lexer.a $B/external_libraries/utf8proc/libutf8proc.a"

link() { # <name> <objects/libs...>
  local name=$1; shift
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$HB/lsan_off.o" "$@" -o "/mayhem/$name"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$HB/standalone_main.o" "$HB/lsan_off.o" "$@" -o "/mayhem/$name-standalone"
}
# shellcheck disable=SC2086
link scsynth_nrt_fuzzer "$HB/scsynth_nrt.o" $SC_LIBS
# shellcheck disable=SC2086
link scsynth_synthdef_fuzzer "$HB/scsynth_synthdef.o" $SC_LIBS
# shellcheck disable=SC2086
link sclang_compile_fuzzer "$HB/sclang_compile.o" $LANG_LIBS
# shellcheck disable=SC2086
link sc_lexer_fuzzer "$HB/sc_lexer.o" $LEXER_LIBS
# shellcheck disable=SC2086
link scdoc_fuzzer "$HB/scdoc.o" $SCDOC_OBJS

# 3) Test build, normal upstream flags (no sanitizers, no -gdwarf-3): upstream's boost.test suites
#    plus the CLIs mayhem/test.sh probes with known answers.
cmake -S . -B build-tests "${COMMON_CMAKE[@]}" -DENABLE_TESTSUITE=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build-tests -j"$MAYHEM_JOBS" --target scsynth sclang sc_lexer_standalone sc_lexer_test \
  scsynth_test readwrite_test sc_msg_iter_test
mkdir -p build-tests/scdoc
$CXX -O2 -std=c++17 $COVERAGE_FLAGS -Wno-null-conversion -ISCDoc SCDoc/main.cpp SCDoc/SCDoc.cpp SCDoc/SCDoc.tab.cpp \
  SCDoc/lex.scdoc.cpp -o build-tests/scdoc/scdoc_cli
