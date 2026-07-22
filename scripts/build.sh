#!/usr/bin/env bash
set -euo pipefail

# Builds (or reuses) the component Docker images.
#
#   IMAGE_MODE=cache : build job — reuse the GHCR image for a component if its
#                      source commit is unchanged, otherwise build and push it.
#   IMAGE_MODE=pull  : shard job — just pull the images the build job produced
#                      (keyed by the same commits, passed in via *_SHA env).
#   unset            : local / test-box — plain docker build, no registry.
#
# The cache lives entirely in this repo's GHCR namespace ($GHCR_REPO) — the shards
# never rebuild, and unchanged components are not rebuilt across runs.

ENV="${1:-local}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build"
ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
GHCR_REPO="${GHCR_REPO:-ghcr.io/mocachain/moca-e2e}"

# Pass GITHUB_TOKEN for private dependency resolution in Docker builds
TOKEN_ARG=""
if [ -n "${GH_TOKEN:-}" ]; then
  TOKEN_ARG="--build-arg GITHUB_TOKEN=${GH_TOKEN}"
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  TOKEN_ARG="--build-arg GITHUB_TOKEN=${GITHUB_TOKEN}"
fi

# Cache keys = the source commit of each built image. Shard (pull) jobs receive
# these as env (they don't clone); otherwise read them from the cloned repos.
sha_of() { git -C "$BUILD_DIR/$1" rev-parse --short=12 HEAD 2>/dev/null || echo local; }
MOCA_SHA="${MOCA_SHA:-$(sha_of moca)}"
SP_SHA="${SP_SHA:-$(sha_of moca-storage-provider)}"
CMD_SHA="${CMD_SHA:-$(sha_of moca-cmd)}"

# Recipe hash: the docker/ tree (Dockerfiles + entrypoints). Folding it into the
# cache tag invalidates images when the build recipe changes, not just the source.
# Both build and shard jobs compute it from the same checkout, so keys line up.
RECIPE_HASH="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD:docker 2>/dev/null || echo r0)"

# docker_image <local-tag> <cache-name> <sha> [docker build args...]
docker_image() {
  local local_tag="$1" name="$2" sha="$3"; shift 3
  local ref="${GHCR_REPO}-${name}:${sha}-${RECIPE_HASH}"
  case "${IMAGE_MODE:-}" in
    pull)
      echo "--- pull ${ref}"
      docker pull "$ref"
      docker tag "$ref" "$local_tag"
      ;;
    cache)
      if docker manifest inspect "$ref" >/dev/null 2>&1; then
        echo "--- cache hit ${ref}"
        docker pull "$ref"
        docker tag "$ref" "$local_tag"
      else
        echo "--- cache miss, building ${ref}"
        docker build -t "$local_tag" "$@"
        docker tag "$local_tag" "$ref"
        docker push "$ref"
      fi
      ;;
    *)
      docker build -t "$local_tag" "$@"
      ;;
  esac
}

echo "=== Images (mode=${IMAGE_MODE:-local}, arch=$ARCH) ==="

# Shards (pull) have no cloned repos; only build/cache modes need them present.
if [ "${IMAGE_MODE:-}" != "pull" ] && [ ! -d "$BUILD_DIR/moca" ]; then
  echo "Error: moca repo not cloned at $BUILD_DIR/moca (run: make clone)"
  exit 1
fi

# mocad, cosmovisor and genesis-init derive from the moca chain repo.
docker_image mocad-local:latest mocad "$MOCA_SHA" \
  -f "$ROOT_DIR/docker/Dockerfile.mocad" --build-arg TARGETARCH="$ARCH" $TOKEN_ARG "$ROOT_DIR"

docker_image mocad-cosmovisor:latest cosmovisor "$MOCA_SHA" \
  -f "$ROOT_DIR/docker/Dockerfile.cosmovisor" --build-arg TARGETARCH="$ARCH" $TOKEN_ARG "$ROOT_DIR"

docker_image moca-sp-local:latest sp "$SP_SHA" \
  -f "$ROOT_DIR/docker/Dockerfile.sp" --build-arg TARGETARCH="$ARCH" $TOKEN_ARG "$ROOT_DIR"

# genesis-init COPYs --from=mocad-local:latest, present in the daemon from the
# mocad step above (built or pulled). Key it on the moca commit too.
docker_image moca-genesis-init:latest genesis-init "$MOCA_SHA" \
  -f "$ROOT_DIR/docker/Dockerfile.init" "$ROOT_DIR"

docker_image moca-cmd-local:latest moca-cmd "$CMD_SHA" \
  -f "$ROOT_DIR/docker/Dockerfile.moca-cmd" --build-arg TARGETARCH="$ARCH" $TOKEN_ARG "$ROOT_DIR"

echo "=== Images ready ==="
docker images | grep -E "(mocad-local|mocad-cosmovisor|moca-sp-local|moca-genesis-init|moca-cmd-local)" || true
