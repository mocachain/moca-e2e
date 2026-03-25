FROM golang:1.23-bullseye AS builder

ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY build/moca-storage-provider/ .

RUN git init && git add -A && git commit -m "build" --allow-empty 2>/dev/null || true

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=1 \
    GOARCH=${TARGETARCH} \
    make build

FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl jq mysql-client \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/build/moca-sp /usr/local/bin/moca-sp
COPY docker/entrypoint-sp.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 9033 9063 9400

ENTRYPOINT ["/entrypoint.sh"]
