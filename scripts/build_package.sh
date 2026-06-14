#!/usr/bin/env bash
set -euo pipefail

# rosdep install is not needed here — all workspace dependencies are
# pre-installed in the Docker image via Dockerfile.dependency.
colcon build --symlink-install --base-paths src/ --cmake-args=-DCMAKE_BUILD_TYPE=Release --parallel-workers $(nproc)
