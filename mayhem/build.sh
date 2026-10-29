#!/usr/bin/env bash
#
# mayhem/build.sh — build the embedded mruby (ngx_mruby/mruby) twice and link the fuzz harness:
#   1) host build, NORMAL flags, with mrbtest: the functional oracle that mayhem/test.sh runs
#   2) 'fuzz' build: libmruby.a with $SANITIZER_FLAGS $DEBUG_FLAGS, linked into the harness
# Everything lands in mruby/build (gitignored upstream) or /mayhem; no network is needed.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC/mruby"

# mruby's own build system (rake + ruby): host test build and sanitized fuzz build in one invocation.
MRUBY_CONFIG="$SRC/mayhem/mruby_build_config.rb" rake -m -j"$MAYHEM_JOBS" test:build

LIBMRUBY="$SRC/mruby/build/fuzz/lib/libmruby.a"
INC="-I$SRC/mruby/include -I$SRC/mruby/build/fuzz/include"
HARNESS="$SRC/mayhem/harnesses/mruby_fuzzer.c"
OBJ="$SRC/mayhem/obj"
rm -rf "$OBJ"
mkdir -p "$OBJ"

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

# -fsanitize=fuzzer-no-link only instruments; the engine comes from $LIB_FUZZING_ENGINE at link time.
$CC -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $INC -c "$HARNESS" -o "$OBJ/mruby_fuzzer.o"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OBJ/mruby_fuzzer.o" "$OBJ/lsan_off.o" \
    "$LIBMRUBY" -lm -o "$SRC/mruby_fuzzer"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link "$OBJ/mruby_fuzzer.o" "$OBJ/lsan_off.o" "$OBJ/standalone_main.o" \
    "$LIBMRUBY" -lm -o "$SRC/mruby_fuzzer-standalone"
