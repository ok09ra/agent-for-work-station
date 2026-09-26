FROM node:22-bookworm-slim@sha256:43ac6c60b8f89723f746e8a92ce91abd5017e627ce1ddfe4238355d3a30b772c

ARG CODEX_VERSION=0.157.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates python3 \
    && rm -rf /var/lib/apt/lists/* \
    && npm install --global "@openai/codex@${CODEX_VERSION}"

COPY child.py /opt/afws/child.py

RUN useradd --create-home --uid 10001 --shell /bin/sh afws \
    && mkdir -p /job/input /job/output /job/scratch /auth \
    && chown -R afws:afws /job /auth \
    && chmod 700 /auth

USER afws
ENV HOME=/home/afws CODEX_HOME=/auth
WORKDIR /job
