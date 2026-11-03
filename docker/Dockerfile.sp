ARG GO_IMAGE=golang:1.26.10-trixie
ARG BASE_IMAGE=debian:trixie-slim
FROM ${GO_IMAGE} AS builder

ARG TARGETARCH
ARG GITHUB_TOKEN=""

RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY build/moca-storage-provider/ .

RUN git init && git add -A && git commit -m "build" --allow-empty 2>/dev/null || true
RUN if [ -n "$GITHUB_TOKEN" ]; then git config --global url."https://${GITHUB_TOKEN}:@github.com/".insteadOf "https://github.com/"; fi

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=1 \
    GOARCH=${TARGETARCH} \
    make build

FROM ${BASE_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl jq default-mysql-client openssl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/build/moca-sp /usr/local/bin/moca-sp
COPY docker/entrypoint-sp.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 9033 9063 9400

ENTRYPOINT ["/entrypoint.sh"]
