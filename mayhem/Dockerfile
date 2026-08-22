# syntax=docker/dockerfile:1.7
FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      python3-dev python3-venv cmake \
    && rm -rf /var/lib/apt/lists/*
# The offline pip wheelhouse build.sh fills (SPEC §6.5). It lives OUTSIDE /mayhem so the
# `git clean -ffdX` that rlenv's patch grader runs before every graded build cannot delete it
# (pypcode's .gitignore covers *.so/*.sla/build/), and it is created here as root because the
# build user cannot mkdir outside its own tree. HOME is deliberately NOT used: docker leaves
# HOME=/root across `USER mayhem`, so a $HOME-derived path is not writable by uid 2000.
RUN mkdir -p /opt/wheelhouse && chown 2000:2000 /opt/wheelhouse
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
