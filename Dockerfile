FROM golang:1.23-alpine AS base

RUN apk add --no-cache bash git curl make jq

# Install yq
RUN wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && \
    chmod +x /usr/local/bin/yq

WORKDIR /e2e

COPY . .

RUN chmod +x scripts/*.sh

ENTRYPOINT ["make"]
CMD ["test"]
