#!/usr/bin/env bash
# run_dev.sh — start the face_blur workspace in an Isaac ROS dev container
#
# Image resolution order:
#   1. Already cached locally as cached_isaac_run_dev_image_local:latest → use it
#   2. Pull DEV_IMAGE from the registry                                  → tag + use it
#   3. Build locally via isaac-ros activate (uses scripts/ config)       → tag + use it
#
# Usage:
#   ./run_dev.sh                  # normal start
#   ./run_dev.sh --rebuild        # force a local rebuild regardless of cache
#   ./run_dev.sh [activate flags] # any other flags are forwarded to isaac-ros activate

set -euo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_NAME="$(basename "${WORKSPACE}")"

# Image published by CI to the GitLab Container Registry
DEV_IMAGE="cr.gitlab.uzh.ch/bal-orx/${PKG_NAME}:dev"
CACHED="cached_isaac_run_dev_image_local:latest"

# ── Image resolution ─────────────────────────────────────────────────────────
# The goal is to always end up with a valid cached_isaac_run_dev_image_local:latest
# before handing off to `isaac-ros activate --use-cached-build-image`.
#
# Resolution order:
#   1. --rebuild flag      → build locally via `isaac-ros activate --build-local`
#                            using scripts/.isaac_ros_common-config to find the
#                            right Dockerfiles; also tags the result as DEV_IMAGE
#                            so CI can push it to the registry afterwards.
#   2. Image already local → nothing to do, use it as-is.
#   3. Pull from registry  → pull DEV_IMAGE and re-tag it as the local cache name
#                            so the CLI finds it with --use-cached-build-image.
#   4. Pull failed         → fall back to a local build (same as --rebuild).
if [[ "${1:-}" == "--rebuild" ]]; then
    shift
    echo "[run_dev] --rebuild: building image locally via isaac-ros activate..."
    ISAAC_DIR="${WORKSPACE}" ISAAC_ROS_WS="${WORKSPACE}/scripts" \
        isaac-ros activate --build-local "$@"
    docker tag "${CACHED}" "${DEV_IMAGE}"
    exit 0
elif ! docker image inspect "${CACHED}" &>/dev/null; then
    echo "[run_dev] No local image found, pulling ${DEV_IMAGE}..."
    if docker pull "${DEV_IMAGE}"; then
        docker tag "${DEV_IMAGE}" "${CACHED}"
    else
        echo "[run_dev] Pull failed — building locally via isaac-ros activate..."
        ISAAC_DIR="${WORKSPACE}" ISAAC_ROS_WS="${WORKSPACE}/scripts" \
            isaac-ros activate --build-local "$@"
        docker tag "${CACHED}" "${DEV_IMAGE}"
        exit 0
    fi
fi

# ── Launch via isaac-ros activate ────────────────────────────────────────────
# ISAAC_DIR      → workspace root, mounted at /workspaces/isaac_ros-dev
# ISAAC_ROS_WS   → points at scripts/ so the CLI discovers:
#                    scripts/.isaac_ros_common-config  (Dockerfile search dirs)
#                    scripts/.isaac_ros_dev-dockerargs (CycloneDDS flags)
export ISAAC_DIR="${WORKSPACE}"
export ISAAC_ROS_WS="${WORKSPACE}/scripts"

exec isaac-ros activate --use-cached-build-image "$@"
