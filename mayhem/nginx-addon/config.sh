#!/bin/sh
# Copied to build/mayhem-nginx/addon/config by build.sh (an in-tree file named "config" would be gitignored).
# nginx addon for the fuzz build: ngx_mruby's own config.in (static link), with libmruby taken from the
# sanitizer-instrumented 'fuzz' build (mayhem/mruby_build_config.rb) instead of mruby/build/host.
ngx_addon_name=ngx_http_mruby_module
ngx_mruby_root=$SRC
mruby_root=$ngx_mruby_root/mruby
mruby_incdir="$mruby_root/include $mruby_root/build/fuzz/include"
mruby_libdir=$mruby_root/build/fuzz/lib

NGX_MRUBY_SRCS="$ngx_mruby_root/src/http/ngx_http_mruby_module.c \
                $ngx_mruby_root/src/http/ngx_http_mruby_core.c \
                $ngx_mruby_root/src/http/ngx_http_mruby_init.c \
                $ngx_mruby_root/src/http/ngx_http_mruby_request.c \
                $ngx_mruby_root/src/http/ngx_http_mruby_var.c \
                $ngx_mruby_root/src/http/ngx_http_mruby_connection.c \
                $ngx_mruby_root/src/http/ngx_http_mruby_server.c \
                $ngx_mruby_root/src/http/ngx_http_mruby_filter.c \
                $ngx_mruby_root/src/http/ngx_http_mruby_upstream.c \
                $ngx_mruby_root/src/http/ngx_http_mruby_ssl.c \
                $ngx_mruby_root/src/http/ngx_http_mruby_async.c \
                "

if [ $STREAM = YES ]; then
  NGX_MRUBY_SRCS="$NGX_MRUBY_SRCS \
                  $ngx_mruby_root/src/stream/ngx_stream_mruby_module.c \
                  $ngx_mruby_root/src/stream/ngx_stream_mruby_init.c \
                  $ngx_mruby_root/src/stream/ngx_stream_mruby_core.c \
                  $ngx_mruby_root/src/stream/ngx_stream_mruby_connection.c \
                  $ngx_mruby_root/src/stream/ngx_stream_mruby_async.c \
                  "
fi

HTTP_FILTER_MODULES="$HTTP_FILTER_MODULES __ngx_http_upstream_keepalive_module ngx_http_mruby_module"
if [ $STREAM = YES ]; then
  HTTP_FILTER_MODULES="$HTTP_FILTER_MODULES ngx_stream_mruby_module"
fi
NGX_ADDON_SRCS="$NGX_ADDON_SRCS $NGX_MRUBY_SRCS"
CORE_LIBS="$CORE_LIBS -L$mruby_libdir -lmruby -lm"
CORE_INCS="$CORE_INCS $mruby_incdir"

have=NDK_SET_VAR . auto/have
