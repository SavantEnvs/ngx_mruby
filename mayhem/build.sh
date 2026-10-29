#!/usr/bin/env bash
#
# mayhem/build.sh — build ngx_mruby's fuzz targets and the mrbtest oracle; no network is needed.
#   1) mruby (ngx_mruby/mruby) via its own rake: a host build with mrbtest (NORMAL flags, the oracle that
#      mayhem/test.sh runs) and a 'fuzz' build of libmruby.a with ngx_mruby's gem set + $SANITIZER_FLAGS.
#   2) nginx (the version pinned in ./nginx_version; its tarball is baked at /opt/mayhem-deps by the Dockerfile)
#      configured with ngx_mruby's own module sources (src/http/*.c, src/stream/*.c) via mayhem/nginx-addon,
#      compiled with $SANITIZER_FLAGS and libFuzzer coverage, linked against the fuzz libmruby.
#   3) mruby_fuzzer: embedded mruby fed Ruby source; ngx_mruby_http_fuzzer: the whole nginx + ngx_mruby module,
#      fed raw HTTP requests (see mayhem/harnesses/ngx_mruby_http_fuzzer.c).
# Everything lands in gitignored dirs (mruby/build, build/) or /mayhem; re-running is idempotent.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${MAYHEM_MRUBY_DEPS:=/opt/mayhem-deps}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS MAYHEM_MRUBY_DEPS

cd "$SRC/mruby"

# mruby's own build system (rake + ruby): host test build and sanitized fuzz build in one invocation.
MRUBY_CONFIG="$SRC/mayhem/mruby_build_config.rb" rake -m -j"$MAYHEM_JOBS" test:build

LIBMRUBY="$SRC/mruby/build/fuzz/lib/libmruby.a"
INC="-I$SRC/mruby/include -I$SRC/mruby/build/fuzz/include"
OBJ="$SRC/mayhem/obj"
rm -rf "$OBJ"
mkdir -p "$OBJ"

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

# -fsanitize=fuzzer-no-link only instruments; the engine comes from $LIB_FUZZING_ENGINE at link time.
$CC -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $INC -c "$SRC/mayhem/harnesses/mruby_fuzzer.c" \
    -o "$OBJ/mruby_fuzzer.o"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OBJ/mruby_fuzzer.o" "$OBJ/lsan_off.o" \
    "$LIBMRUBY" -lm -o "$SRC/mruby_fuzzer"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link "$OBJ/mruby_fuzzer.o" "$OBJ/lsan_off.o" "$OBJ/standalone_main.o" \
    "$LIBMRUBY" -lm -o "$SRC/mruby_fuzzer-standalone"

# nginx + ngx_mruby's module, out of tree in build/ (gitignored upstream).
. "$SRC/nginx_version"
NGX_BUILD="$SRC/build/mayhem-nginx"
NGX_SRC="$NGX_BUILD/$NGINX_SRC_VER"
rm -rf "$NGX_BUILD"
mkdir -p "$NGX_BUILD"
tar -xzf "$MAYHEM_MRUBY_DEPS/$NGINX_SRC_VER.tar.gz" -C "$NGX_BUILD"
mkdir -p "$NGX_BUILD/addon"
cp "$SRC/mayhem/nginx-addon/config.sh" "$NGX_BUILD/addon/config"
cd "$NGX_SRC"
# nginx stores every handler as a generic function pointer and calls it through another type (UBSan "function"
# check, e.g. ngx_output_chain.c:236 -> ngx_http_mruby_body_filter), memcpy()s a NULL pointer with length 0 for
# an empty request-body buffer (nonnull-attribute, ngx_http_variables.c:2215) and reads the method and version
# as unaligned uint32_t (alignment, ngx_http_parse.c:172), so those three checks are relaxed on the nginx
# tree. ASan and every other UBSan check stay on.
NGX_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link -fno-sanitize=function,nonnull-attribute,alignment -fno-common"
./configure --prefix="$NGX_BUILD/prefix" --with-cc="$CC" --with-cc-opt="$NGX_CFLAGS" --with-ld-opt="$SANITIZER_FLAGS" \
    --with-stream --without-stream_access_module --without-http_gzip_module \
    --add-module="$NGX_BUILD/addon" --add-module="$SRC/dependence/ngx_devel_kit" >"$NGX_BUILD/configure.log" 2>&1 \
    || { tail -n 40 "$NGX_BUILD/configure.log"; exit 1; }
make -j"$MAYHEM_JOBS" >"$NGX_BUILD/make.log" 2>&1 || { tail -n 60 "$NGX_BUILD/make.log"; exit 1; }

# Every nginx and ngx_mruby object except nginx.o's main(), which collides with the fuzzer's.
NGX_OBJS=$(awk '/^objs\/nginx:/{on=1} on&&/\$\(LINK\)/{exit} on{for(i=1;i<=NF;i++) if($i ~ /\.o$/ && $i != "objs/src/core/nginx.o") print $i}' objs/Makefile)
objcopy --redefine-sym main=ngx_unused_main objs/src/core/nginx.o "$OBJ/nginx_nomain.o"
NGX_INC="-I src/core -I src/event -I src/event/modules -I src/os/unix -I objs -I src/http -I src/http/modules"
$CC -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -fno-common $NGX_INC \
    -DCONF_TEMPLATE="\"$SRC/mayhem/harnesses/ngx_mruby_http.conf\"" \
    -c "$SRC/mayhem/harnesses/ngx_mruby_http_fuzzer.c" -o "$OBJ/ngx_mruby_http_fuzzer.o"

NGX_LIBS="-lcrypt -L$SRC/mruby/build/fuzz/lib -lmruby -lm -lpcre2-8"
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OBJ/ngx_mruby_http_fuzzer.o" "$OBJ/nginx_nomain.o" \
    $NGX_OBJS "$OBJ/lsan_off.o" $NGX_LIBS -Wl,-E -o "$SRC/ngx_mruby_http_fuzzer"
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link "$OBJ/ngx_mruby_http_fuzzer.o" "$OBJ/nginx_nomain.o" \
    $NGX_OBJS "$OBJ/lsan_off.o" "$OBJ/standalone_main.o" $NGX_LIBS -Wl,-E -o "$SRC/ngx_mruby_http_fuzzer-standalone"
