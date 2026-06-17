#!/usr/bin/env bash
# run_dev_orx.sh — start the Isaac ROS dev container for this workspace.
#
# Image resolution order:
#   1. Already cached locally as cached_isaac_run_dev_image_local_${PROJECT_NAME}:latest → use it
#   2. Pull DEV_IMAGE from the registry                                                   → tag + use it
#   3. Build locally via isaac-ros activate (uses scripts/ config)                        → tag + use it
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
CACHED="cached_isaac_run_dev_image_local:latest"           # global tag read by the CLI
CACHED_LOCAL="cached_isaac_run_dev_image_local_${PROJECT_NAME}:latest"  # project-specific

# ── Docker args ───────────────────────────────────────────────────────────────
# The Isaac ROS CLI reads dockerargs from $ISAAC_ROS_WS/scripts/.isaac_ros_dev-dockerargs,
# but run_dev.py and isaac_ros_common_config_utils.py disagree on what ISAAC_ROS_WS means
# (workspace root vs scripts/ dir). We work around this by reading the file ourselves
# and injecting all flags via DOCKER_ARGS_FILE, which is always reliably read.
_DOCKER_ARGS=$(mktemp)

# Static flags from the workspace dockerargs file
grep -v '^\s*#' "${WORKSPACE}/scripts/.isaac_ros_dev-dockerargs" | \
    grep -v '^\s*$' >> "${_DOCKER_ARGS}"

# CycloneDDS URI — injected here so CYCLONEDDS_PROFILE can override per-invocation.
# If CYCLONEDDS_PROFILE is set on the host, mount that file into the container
# and point CycloneDDS at it — useful for sharing one DDS config across projects.
if [[ -n "${CYCLONEDDS_PROFILE:-}" ]]; then
    [[ -f "${CYCLONEDDS_PROFILE}" ]] || \
        { echo "[run_dev] ERROR: CYCLONEDDS_PROFILE not found: ${CYCLONEDDS_PROFILE}"; exit 1; }
    echo "-v ${CYCLONEDDS_PROFILE}:/cyclone_profile.xml:ro" >> "${_DOCKER_ARGS}"
    echo "-e CYCLONEDDS_URI=/cyclone_profile.xml" >> "${_DOCKER_ARGS}"
    echo "[run_dev] Using external CycloneDDS profile: ${CYCLONEDDS_PROFILE}"
else
    echo "-e CYCLONEDDS_URI=/workspaces/isaac_ros-dev/cyclone_profile_orx.xml" >> "${_DOCKER_ARGS}"
fi
export DOCKER_ARGS_FILE="${_DOCKER_ARGS}"

# ── X11 auth cookie ──────────────────────────────────────────────────────────
# Create /tmp/.docker.xauth with a FamilyWild cookie so GUI tools (rqt, rviz2)
# can connect to the host X server from inside the container.
if [[ -n "${DISPLAY:-}" ]]; then
    XAUTH_FILE=/tmp/.docker.xauth
    touch "${XAUTH_FILE}"
    xauth nlist "${DISPLAY}" 2>/dev/null \
        | sed -e 's/^..../ffff/' \
        | xauth -f "${XAUTH_FILE}" nmerge - 2>/dev/null || true
    chmod 777 "${XAUTH_FILE}"
fi

# ── Image resolution ─────────────────────────────────────────────────────────
# All image state is tracked via CACHED_LOCAL (project-specific tag) so that
# multiple projects can coexist on the same machine without fighting over the
# global CACHED tag. CACHED is only written at the last moment, just before
# `isaac-ros activate`, to minimise the race window.
#
# Resolution order:
#   1. --rebuild flag      → build via `isaac-ros activate --build-local`;
#                            tag result as CACHED_LOCAL and DEV_IMAGE.
#                            Run GC to remove stale dependency-layer hashes.
#   2. CACHED_LOCAL exists → nothing to do, use it.
#   3. Pull from registry  → pull DEV_IMAGE, tag as CACHED_LOCAL.
#   4. Pull failed         → fall back to a local build (same as --rebuild).
if [[ "${1:-}" == "--rebuild" ]]; then
    shift
    echo "[run_dev] --rebuild: building image locally via isaac-ros activate..."
    ISAAC_DIR="${WORKSPACE}" ISAAC_ROS_WS="${WORKSPACE}/scripts" \
        isaac-ros activate --build-local "$@"
    docker tag "${CACHED}" "${CACHED_LOCAL}"
    docker tag "${CACHED}" "${DEV_IMAGE}"
    _new_id=$(docker inspect --format '{{.Id}}' "${CACHED}")
    while IFS=' ' read -r _tag _id; do
        if [[ "${_id}" == "${_new_id}" ]]; then
            echo "[run_dev] Removing redundant nvcr tag: ${_tag}"
            docker rmi "${_tag}" 2>/dev/null || true
        fi
    done < <(docker images --no-trunc \
        --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
        | grep -E 'nvcr\.io/nvidia/isaac/ros[:/]')
    unset _new_id _tag _id
elif ! docker image inspect "${CACHED_LOCAL}" &>/dev/null; then
    echo "[run_dev] No local image found, pulling ${DEV_IMAGE}..."
    if docker pull "${DEV_IMAGE}"; then
        docker tag "${DEV_IMAGE}" "${CACHED_LOCAL}"
    else
        echo "[run_dev] Pull failed — building locally via isaac-ros activate..."
        ISAAC_DIR="${WORKSPACE}" ISAAC_ROS_WS="${WORKSPACE}/scripts" \
            isaac-ros activate --build-local "$@"
        docker tag "${CACHED}" "${CACHED_LOCAL}"
        docker tag "${CACHED}" "${DEV_IMAGE}"
    fi
fi

# ── Project consistency guard ────────────────────────────────────────────────
# CACHED_LOCAL is project-specific, so it won't be clobbered by other projects.
# This guard catches the rarer case where DEV_IMAGE was updated remotely (CI
# push) and local CACHED_LOCAL is stale.
_cached_id=$(docker inspect --format '{{.Id}}' "${CACHED_LOCAL}" 2>/dev/null || true)
_dev_id=$(docker inspect --format '{{.Id}}' "${DEV_IMAGE}" 2>/dev/null || true)
if [[ -n "${_dev_id}" && "${_cached_id}" != "${_dev_id}" ]]; then
    echo "[run_dev] Updating local cache from ${DEV_IMAGE}..."
    docker tag "${DEV_IMAGE}" "${CACHED_LOCAL}"
fi
unset _cached_id _dev_id

# Stamp the global tag just before exec — minimises the race window when
# multiple projects start simultaneously.
docker tag "${CACHED_LOCAL}" "${CACHED}"

# ── Launch via isaac-ros activate ────────────────────────────────────────────
# ISAAC_DIR      → workspace root, mounted at /workspaces/isaac_ros-dev
# ISAAC_ROS_WS   → points at scripts/ so the CLI discovers:
#                    scripts/.isaac_ros_common-config  (Dockerfile search dirs)
#                    scripts/.isaac_ros_dev-dockerargs (extra docker run flags)
export ISAAC_DIR="${WORKSPACE}"
export ISAAC_ROS_WS="${WORKSPACE}/scripts"

exec isaac-ros activate --use-cached-build-image "$@"
