#!/usr/bin/env bash
# run_dev_orx.sh — start the Isaac ROS dev container for this workspace.
#
# Image resolution order:
#   1. Already cached locally as cached_isaac_run_dev_image_local:latest → use it
#   2. Pull DEV_IMAGE from the registry                                  → tag + use it
#   3. Build locally via isaac-ros activate (uses scripts/ config)       → tag + use it
#
# Usage:
#   ./run_dev_orx.sh                                        # normal start
#   ./run_dev_orx.sh --rebuild                              # force a local rebuild, then start
#   CYCLONEDDS_PROFILE=/path/to/dds.xml ./run_dev_orx.sh   # use an external CycloneDDS config
#   ./run_dev_orx.sh [activate flags]                       # any other flags forwarded to isaac-ros activate

set -euo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Project-specific values (PROJECT_NAME, REGISTRY, LAUNCH_PKG, LAUNCH_FILE)
source "${WORKSPACE}/project_orx.env"

# Image published by CI to the container registry
DEV_IMAGE="${REGISTRY}/${PROJECT_NAME}:dev"
CACHED="cached_isaac_run_dev_image_local:latest"

# ── CycloneDDS docker args ────────────────────────────────────────────────────
# Inject CYCLONEDDS_URI via DOCKER_ARGS_FILE so it is set AFTER the workspace
# .isaac_ros_dev-dockerargs (which no longer sets it), giving this the final say.
#
# If CYCLONEDDS_PROFILE is set on the host, mount that file into the container
# and point CycloneDDS at it — useful for sharing one config across projects.
# Otherwise fall back to cyclone_profile_orx.xml at the workspace root.
_CYCLONE_ARGS=$(mktemp)
if [[ -n "${CYCLONEDDS_PROFILE:-}" ]]; then
    [[ -f "${CYCLONEDDS_PROFILE}" ]] || \
        { echo "[run_dev] ERROR: CYCLONEDDS_PROFILE not found: ${CYCLONEDDS_PROFILE}"; exit 1; }
    echo "-v ${CYCLONEDDS_PROFILE}:/cyclone_profile.xml:ro" >> "${_CYCLONE_ARGS}"
    echo "-e CYCLONEDDS_URI=/cyclone_profile.xml" >> "${_CYCLONE_ARGS}"
    echo "[run_dev] Using external CycloneDDS profile: ${CYCLONEDDS_PROFILE}"
else
    echo "-e CYCLONEDDS_URI=/workspaces/isaac_ros-dev/cyclone_profile_orx.xml" >> "${_CYCLONE_ARGS}"
fi
export DOCKER_ARGS_FILE="${_CYCLONE_ARGS}"

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
elif ! docker image inspect "${CACHED}" &>/dev/null; then
    echo "[run_dev] No local image found, pulling ${DEV_IMAGE}..."
    if docker pull "${DEV_IMAGE}"; then
        docker tag "${DEV_IMAGE}" "${CACHED}"
    else
        echo "[run_dev] Pull failed — building locally via isaac-ros activate..."
        ISAAC_DIR="${WORKSPACE}" ISAAC_ROS_WS="${WORKSPACE}/scripts" \
            isaac-ros activate --build-local "$@"
        docker tag "${CACHED}" "${DEV_IMAGE}"
    fi
fi

# ── Launch via isaac-ros activate ────────────────────────────────────────────
# ISAAC_DIR      → workspace root, mounted at /workspaces/isaac_ros-dev
# ISAAC_ROS_WS   → points at scripts/ so the CLI discovers:
#                    scripts/.isaac_ros_common-config  (Dockerfile search dirs)
#                    scripts/.isaac_ros_dev-dockerargs (extra docker run flags)
export ISAAC_DIR="${WORKSPACE}"
export ISAAC_ROS_WS="${WORKSPACE}/scripts"

exec isaac-ros activate --use-cached-build-image "$@"
