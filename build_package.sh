#!/usr/bin/env bash
set -euo pipefail

sudo apt update
rosdep update
rosdep install --from-paths src --ignore-src -r -y
colcon build --symlink-install --base-paths src/ --cmake-args=-DCMAKE_BUILD_TYPE=Release --parallel-workers $(nproc)
source install/local_setup.bash
