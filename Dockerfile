# syntax=docker/dockerfile:1

FROM node:22-alpine3.24@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS frontend-builder
WORKDIR /build
COPY package.json package-lock.json ./
RUN npm ci
COPY frontend ./frontend
RUN npm run build

FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS postgrest-downloader
ARG POSTGREST_VERSION=14.16
ARG POSTGREST_SHA256=36b8ae140f188cfcd6003494805bf35a41e895f88c12be9183d60f91782145c6
RUN apk add --no-cache ca-certificates curl xz
RUN archive="postgrest-v${POSTGREST_VERSION}-linux-static-x86-64.tar.xz" \
    && curl --fail --location --retry 3 \
       "https://github.com/PostgREST/postgrest/releases/download/v${POSTGREST_VERSION}/${archive}" \
       --output "/tmp/${archive}" \
    && echo "${POSTGREST_SHA256}  /tmp/${archive}" | sha256sum -c - \
    && tar -xJf "/tmp/${archive}" -C /usr/local/bin postgrest \
    && chmod 0755 /usr/local/bin/postgrest

FROM postgres:18-alpine@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2 AS appliance-root
RUN apk add --no-cache age ca-certificates coreutils curl libstdc++ su-exec tar tini util-linux \
    && adduser -S -D -H -h /nonexistent -s /sbin/nologin -G postgres njord \
    && rm /usr/local/bin/gosu \
    && ln -s /sbin/su-exec /usr/local/bin/gosu
COPY --from=frontend-builder /usr/local/bin/node /usr/local/bin/node
COPY --from=postgrest-downloader /usr/local/bin/postgrest /usr/local/bin/postgrest

WORKDIR /opt/njord
COPY postgrest.conf ./
COPY examples ./examples
COPY scripts ./scripts
COPY sql ./sql
COPY frontend/index.html frontend/style.css frontend/bootstrap.js ./frontend/
COPY --from=frontend-builder /build/frontend/app.js ./frontend/app.js
RUN find examples sql -type d -exec chmod 0755 {} + \
    && find examples sql -type f -exec chmod 0644 {} +

FROM scratch
COPY --from=appliance-root / /

WORKDIR /opt/njord
VOLUME ["/var/lib/postgresql"]
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=en_US.utf8 \
    PG_MAJOR=18 \
    PG_VERSION=18.6 \
    PGDATA=/var/lib/postgresql/18/docker \
    POSTGREST_BIN=/usr/local/bin/postgrest \
    GHCRTS=-N2 \
    NJORD_CONTROL_DATABASE=njord \
    NJORD_BOOK_SCHEMA_VERSION=1 \
    NJORD_FOREGROUND_LOGS=1 \
    NJORD_INSTALL_EXAMPLES=0 \
    NJORD_LOCK_DIR=/run/njord/locks \
    NJORD_MANAGE_BOOK_DATABASES=1 \
    NJORD_UI_HOST=0.0.0.0 \
    NJORD_UI_PORT=8080

EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=60s --retries=5 \
    CMD curl --fail --silent --show-error "http://127.0.0.1:${NJORD_UI_PORT:-8080}/readyz" >/dev/null || exit 1
STOPSIGNAL SIGTERM
ENTRYPOINT ["/sbin/tini", "--", "/opt/njord/scripts/run-appliance"]
