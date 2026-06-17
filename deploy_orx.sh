#!/usr/bin/env bash
# deploy_orx.sh — build (if needed) and run a ROS 2 launch file in the Isaac ROS container.
#
# If the dev container (from run_dev_orx.sh) is already running, exec-s into it.
# Otherwise uses `isaac-ros activate` to start it in the background.
#
# Usage:
#   ./deploy_orx.sh [LAUNCH_FILE [LAUNCH_ARGS...]]
#   CYCLONEDDS_PROFILE=/path/to/dds.xml ./deploy_orx.sh   # use an external CycloneDDS config
#
# Examples:
#   ./deploy_orx.sh
#   ./deploy_orx.sh zed_camera.launch.py

set -euo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Project-specific values (PROJECT_NAME, REGISTRY, LAUNCH_PKG, LAUNCH_FILE)
source "${WORKSPACE}/project_orx.env"

# Allow the launch file to be overridden as the first argument
LAUNCH_FILE="${1:-${LAUNCH_FILE}}"
shift 2>/dev/null || true
LAUNCH_ARGS="${*:-}"

# Container name is canonical in scripts/.isaac-ros-cli/config.yaml
CONTAINER=$(grep -m1 'container_name:' "${WORKSPACE}/scripts/.isaac-ros-cli/config.yaml" | awk '{print $2}')

DEV_IMAGE="${REGISTRY}/${PROJECT_NAME}:dev"
CACHED="cached_isaac_run_dev_image_local:latest"           # global tag read by the CLI
CACHED_LOCAL="cached_isaac_run_dev_image_local_${PROJECT_NAME}:latest"  # project-specific

# ── Project consistency guard ────────────────────────────────────────────────
# deploy can be invoked without run_dev (e.g. when juggling multiple projects),
# so it guards independently using the project-specific CACHED_LOCAL.
_cached_id=$(docker inspect --format '{{.Id}}' "${CACHED_LOCAL}" 2>/dev/null || true)
_dev_id=$(docker inspect --format '{{.Id}}' "${DEV_IMAGE}" 2>/dev/null || true)
if [[ -z "${_cached_id}" ]]; then
    echo "[deploy] No local image found — pulling ${DEV_IMAGE}..."
    docker pull "${DEV_IMAGE}" && docker tag "${DEV_IMAGE}" "${CACHED_LOCAL}" \
        || { echo "[deploy] ERROR: image not found. Run ./run_dev_orx.sh --rebuild"; exit 1; }
elif [[ -n "${_dev_id}" && "${_cached_id}" != "${_dev_id}" ]]; then
    echo "[deploy] Updating local cache from ${DEV_IMAGE}..."
    docker tag "${DEV_IMAGE}" "${CACHED_LOCAL}"
fi
unset _cached_id _dev_id

# ── Startup script (runs inside the container via docker exec) ──────────────
# Host variables expand now; \${...} expands inside the container.
read -r -d '' STARTUP <<HEREDOC || true
set -e
WS=/workspaces/isaac_ros-dev

# Source ROS — no-op if workspace-entrypoint already did it, required otherwise
source "/opt/ros/\${ROS_DISTRO:-jazzy}/setup.bash" 2>/dev/null || true
# Source the image's pre-built workspace (matches what /etc/bash.bashrc does in interactive shells)
source "/opt/ros_ws/install/setup.bash" 2>/dev/null || true

if [ ! -f "\${WS}/install/${LAUNCH_PKG}/share/${LAUNCH_PKG}/package.xml" ]; then
    echo "[deploy] No colcon build found — building..."
    cd "\${WS}"
    bash "\${WS}/scripts/build_package.sh"
fi

source "\${WS}/install/setup.bash"
exec ros2 launch ${LAUNCH_PKG} ${LAUNCH_FILE}${LAUNCH_ARGS:+ ${LAUNCH_ARGS}}
HEREDOC

# Stamp the global tag just before activate — minimises the race window when
# multiple projects start simultaneously.
docker tag "${CACHED_LOCAL}" "${CACHED}"

# ── X11 auth cookie ──────────────────────────────────────────────────────────
# Ensure /tmp/.docker.xauth exists as a file before Docker tries to bind-mount
# it (from scripts/.isaac_ros_dev-dockerargs). Without this, Docker creates it
# as an empty directory and X11 forwarding silently breaks.
if [[ -n "${DISPLAY:-}" ]]; then
    XAUTH_FILE=/tmp/.docker.xauth
    touch "${XAUTH_FILE}"
    xauth nlist "${DISPLAY}" 2>/dev/null \
        | sed -e 's/^..../ffff/' \
        | xauth -f "${XAUTH_FILE}" nmerge - 2>/dev/null || true
    chmod 777 "${XAUTH_FILE}"
fi

# ── Ensure a container is running ───────────────────────────────────────────
if ! docker ps --quiet --filter "name=^/${CONTAINER}$" | grep -q .; then
    echo "[deploy] Starting container..."

    # Build the DOCKER_ARGS_FILE: --detach so activate returns immediately,
    # plus CYCLONEDDS_URI injected here so it overrides the workspace dockerargs
    # (DOCKER_ARGS_FILE is loaded first by the CLI, but workspace is loaded last
    # and would override — so we removed CYCLONEDDS_URI from the workspace file
    # and set it exclusively here).
    _DETACH_ARGS=$(mktemp)
    echo "--detach" > "${_DETACH_ARGS}"
    grep -v '^\s*#' "${WORKSPACE}/scripts/.isaac_ros_dev-dockerargs" | \
        grep -v '^\s*$' >> "${_DETACH_ARGS}"
    if [[ -n "${CYCLONEDDS_PROFILE:-}" ]]; then
        [[ -f "${CYCLONEDDS_PROFILE}" ]] || \
            { echo "[deploy] ERROR: CYCLONEDDS_PROFILE not found: ${CYCLONEDDS_PROFILE}"; exit 1; }
        echo "-v ${CYCLONEDDS_PROFILE}:/cyclone_profile.xml:ro" >> "${_DETACH_ARGS}"
        echo "-e CYCLONEDDS_URI=/cyclone_profile.xml" >> "${_DETACH_ARGS}"
        echo "[deploy] Using external CycloneDDS profile: ${CYCLONEDDS_PROFILE}"
    else
        echo "-e CYCLONEDDS_URI=/workspaces/isaac_ros-dev/cyclone_profile_orx.xml" >> "${_DETACH_ARGS}"
    fi

    DOCKER_ARGS_FILE="${_DETACH_ARGS}" \
    ISAAC_DIR="${WORKSPACE}" \
    ISAAC_ROS_WS="${WORKSPACE}/scripts" \
        isaac-ros activate --use-cached-build-image

    rm -f "${_DETACH_ARGS}"

    # Stop the container when this script exits (Ctrl-C, error, or normal exit)
    trap "echo '[deploy] Stopping container...'; docker stop '${CONTAINER}' > /dev/null" EXIT
else
    echo "[deploy] Attaching to running container ${CONTAINER}..."
fi

# ── Run build + launch inside the container ─────────────────────────────────
docker exec -it "${CONTAINER}" /bin/bash -c "${STARTUP}"
