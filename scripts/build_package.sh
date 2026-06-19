#!/usr/bin/env bash
source /opt/ros/${ROS_DISTRO:-jazzy}/setup.bash 2>/dev/null || true
source /opt/ros_ws/install/setup.bash 2>/dev/null || true

set -euo pipefail

# rosdep install is not needed here — all workspace dependencies are
# pre-installed in the Docker image via Dockerfile.dependency.
colcon build --symlink-install --base-paths src/ --cmake-args=-DCMAKE_BUILD_TYPE=Release --parallel-workers $(nproc)
