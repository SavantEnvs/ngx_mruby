# syntax=docker/dockerfile:1.7
# Commit image for ngx_mruby: builds the embedded mruby with its own rake build system on the org base.
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# mruby builds with rake (ruby); bison is already in the base. nginx (built with ngx_mruby's module for the
# ngx_mruby_http_fuzzer target) needs PCRE2 for ngx_devel_kit's rewrite module. build.sh re-runs offline, so the
# pinned nginx tarball (version from ./nginx_version) and the mruby-stringio gem that rack-based-api depends on
# (upstream's build_config.rb fetches it from github) are baked outside the tree.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends ruby rake libpcre2-dev \
 && rm -rf /var/lib/apt/lists/*
COPY nginx_version /tmp/nginx_version
RUN . /tmp/nginx_version && mkdir -p /opt/mayhem-deps && cd /opt/mayhem-deps \
 && curl -fsSL -o "$NGINX_SRC_VER.tar.gz" "https://nginx.org/download/$NGINX_SRC_VER.tar.gz" \
 && echo "0652b760b3b772d2ec17b47c2fc15d9a95e6fe35cd5b877eadc1a62d9bc75af1  $NGINX_SRC_VER.tar.gz" | sha256sum -c - \
 && git clone -q https://github.com/ksss/mruby-stringio \
 && git -C mruby-stringio checkout -q 32acb9ea9ad1aa1db8088625252988e98770188a \
 && rm -rf mruby-stringio/.git && chmod -R a+rX /opt/mayhem-deps
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN if [ -x /opt/mayhem/ccache/prefill ]; then /opt/mayhem/ccache/prefill bash mayhem/build.sh; \
    else bash mayhem/build.sh; fi

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
