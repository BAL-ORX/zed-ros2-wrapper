#!/usr/bin/env bash
# deploy.sh — build (if needed) and run zed_wrapper in the Isaac ROS container.
#
# If the dev container (from run_dev.sh) is already running, exec-s into it.
# Otherwise uses `isaac-ros activate` to start it — no docker flags duplicated.
#
# Usage:
#   ./deploy.sh [LAUNCH_FILE [LAUNCH_ARGS...]]
#
# Examples:
#   ./deploy.sh
#   ./deploy.sh zed_wrapper.launch.py

set -euo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LAUNCH_PKG="zed_wrapper"
LAUNCH_FILE="${1:-zed_camera.launch.py}"
shift 2>/dev/null || true
LAUNCH_ARGS="${*:-}"

# Must match .isaac-ros-cli/config.yaml → docker.run.container_name
CONTAINER="zed_dev_container"

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
    bash "\${WS}/build_package.sh"
fi

source "\${WS}/install/setup.bash"
exec ros2 launch ${LAUNCH_PKG} ${LAUNCH_FILE}${LAUNCH_ARGS:+ ${LAUNCH_ARGS}}
HEREDOC

# ── Ensure a container is running ───────────────────────────────────────────
if ! docker ps --quiet --filter "name=^/${CONTAINER}$" | grep -q .; then
    echo "[deploy] Starting container..."

    # Inject --detach into the docker run command that run_dev.py builds.
    # This makes isaac-ros activate start the container in the background
    # and return immediately instead of opening an interactive bash session.
    # The regular scripts/.isaac_ros_dev-dockerargs (CycloneDDS vars) is still
    # auto-discovered and loaded alongside this file.
    _DETACH_ARGS=$(mktemp)
    echo "--detach" > "${_DETACH_ARGS}"

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
