# syntax=docker/dockerfile:1.7
#
# Commit image for SuperCollider (scsynth NRT score/synthdef, sc_lexer, SCDoc fuzz harnesses).
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile --build-arg COMMIT=$(git rev-parse HEAD) -t sc .
FROM ghcr.io/savantenvs/base:20261023

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# Build deps upstream documents for Linux (README_LINUX.md). JACK is only needed to link scsynth's
# default audio driver; the harnesses run non-real-time and never open it.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        libsndfile1-dev libfftw3-dev libjack-jackd2-dev libasound2-dev libreadline-dev libudev-dev \
        libncurses-dev file \
 && rm -rf /var/lib/apt/lists/*

# Git submodules the build needs (pinned to the commits upstream's tree records, sha256-checked).
# A CI checkout does not carry submodule content, so build.sh copies these into external_libraries/.
RUN set -eu; fetch() { name=$1; repo=$2; rev=$3; sum=$4; d=/opt/toolchains/deps/$name-$rev; \
      mkdir -p "$d/src"; curl -fsSL -o /tmp/dep.tgz "https://codeload.github.com/$repo/tar.gz/$rev"; \
      echo "$sum  /tmp/dep.tgz" | sha256sum -c -; tar -xzf /tmp/dep.tgz --strip-components=1 -C "$d/src"; \
      rm -f /tmp/dep.tgz; chmod -R a+rX,go-w "$d"; }; \
    fetch nova-simd timblechmann/nova-simd b61e579ffd24004cc5c9f517714cbd30b14d0148 d485e06fba0d5cebfcd85cb3c709ec4049b517adb154c52ebcaafd7eb6657750; \
    fetch nova-tt timblechmann/nova-tt b497ec33a733c84d53e4295955d1033e0add7dae 4f2ee34f8d5bc39142748df0eaf4c64f9052aa83bb5ebf00eae1b80af4240d21; \
    fetch utf8proc JuliaStrings/utf8proc b3e0f28adaec943ac25e3e27514dd6037e7a022e 9f4b500ba24395330996951945d62cecfc2ed026cbeb9b8bd018db0352a58bc4; \
    fetch yaml-cpp jbeder/yaml-cpp 56e3bb550c91fd7005566f19c079cb7a503223cf b8e01ea231a96d6984b0795f225281d1e9989f40ccd589568a051450f41e9151

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN if [ -x /opt/mayhem/ccache/prefill ]; then /opt/mayhem/ccache/prefill bash mayhem/build.sh; \
    else bash mayhem/build.sh; fi

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
