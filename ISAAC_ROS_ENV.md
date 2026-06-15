# Isaac ROS Development Environment

A reproducible Docker-based workflow for ROS 2 development on top of the [Isaac ROS CLI](https://nvidia-isaac-ros.github.io/getting_started/dev_env_setup.html). The same scripts and file layout work for any project — only the files listed in [Adapting to a new project](#adapting-to-a-new-project) need to change.

---

## File layout

```
run_dev_orx.sh          — start (or rebuild) the dev container
deploy_orx.sh           — build the ROS 2 package and run a launch file inside the container
build_package_orx.sh — thin wrapper that delegates to scripts/build_package.sh
project_orx.env         — single source of truth for project identity (registry, package, launch file)
cyclone_profile_orx.xml — CycloneDDS network config (network interface, multicast, buffers)

scripts/
  build_package.sh               — colcon build (no rosdep, no network)
  docker/
    Dockerfile.dependency        — custom layer: apt packages + rosdep pre-install
  .build_image_layers.yaml       — build-time config (layer order, build context)
  .isaac-ros-cli/config.yaml     — runtime config (container name, image keys)
  .isaac_ros_dev-dockerargs      — extra docker run flags (privileges, env vars)
```

---

## Daily workflow

### 1. Start the dev container

```bash
./run_dev_orx.sh
```

What it does, in order:

1. Checks for a locally cached image (`cached_isaac_run_dev_image_local:latest`).
2. If none exists, pulls the pre-built image from the registry defined in `project_orx.env`.
3. If the pull fails, builds the image locally from `Dockerfile.dependency`.
4. Injects CycloneDDS configuration (see [CycloneDDS](#cyclonedds)).
5. Starts the container via `isaac-ros activate` and drops you into a shell at `/workspaces/isaac_ros-dev`.

The workspace root is bind-mounted at `/workspaces/isaac_ros-dev` — edits on the host are immediately visible inside the container.

### 2. Build the ROS 2 package

```bash
# From inside the container:
bash scripts/build_package.sh

# Or from the host (delegates to the same script):
bash build_package_orx.sh
```

This runs `colcon build --symlink-install`. With `--symlink-install`, Python and launch files are symlinked so you do not need to rebuild after editing them — only C++ changes require a rebuild.

### 3. Run a launch file

```bash
# From inside the container:
source install/setup.bash
ros2 launch <LAUNCH_PKG> <LAUNCH_FILE>
```

Or from the host in one command (builds if needed, then launches):

```bash
./deploy_orx.sh
```

The default package and launch file come from `project_orx.env`. Pass a different launch file as the first argument:

```bash
./deploy_orx.sh other_launch.launch.py [launch_args...]
```

---

## Rebuilding the Docker image

Rebuild when you modify `scripts/docker/Dockerfile.dependency` (new apt packages, changed `package.xml` dependencies):

```bash
./run_dev_orx.sh --rebuild
```

This calls `isaac-ros activate --build-local`, builds all layers in the order defined in `scripts/.build_image_layers.yaml`, then:
- Tags the result as `cached_isaac_run_dev_image_local:latest` (used locally).
- Tags it as `<REGISTRY>/<PROJECT_NAME>:dev` so it can be pushed to the registry.

To publish to the registry after a local build:

```bash
docker push <REGISTRY>/<PROJECT_NAME>:dev
```

---

## Configuration files

### `project_orx.env` — project identity

Single source of truth sourced by both `run_dev_orx.sh` and `deploy_orx.sh`. The only file that changes between projects (aside from the Docker and CLI configs):

```bash
PROJECT_NAME="my-project"               # used to name the registry image
REGISTRY="registry.example.com/my-org" # container registry prefix
LAUNCH_PKG="my_package"                 # ROS 2 package containing the default launch file
LAUNCH_FILE="my_node.launch.py"         # default launch file
```

The dev image is derived as `${REGISTRY}/${PROJECT_NAME}:dev`.

### `scripts/.isaac-ros-cli/config.yaml` — runtime CLI config

Controls the container name and which Docker image layers are active at runtime:

```yaml
docker:
  run:
    container_name: my_dev_container
  image:
    additional_image_keys:
      - dependency   # matches the key in Dockerfile.dependency filename
```

Add one entry per custom layer. The order here does **not** control the build sequence — see `image_key_order` below.

> When adding or removing a layer, update **both** this file and `scripts/.build_image_layers.yaml` — they are read by two separate CLI loaders.

### `scripts/.build_image_layers.yaml` — build-time config

Controls layer build order and Docker build contexts:

```yaml
image_key_order:
  - isaac_ros.dependency    # adjust to match your image keys

context_overrides:
  isaac_ros: ..
  noble: ..
  dependency: ../..         # workspace root → enables COPY src/<pkg>/package.xml

cache_to_registry_names: []
cache_from_registry_names:
  - nvcr.io/nvidia/isaac/ros
remote_builder: {}
```

The `context_overrides` entry for `dependency` must point to the workspace root (relative to the directory where the Dockerfile was found) whenever your Dockerfile copies files from `src/`.

### `scripts/.isaac_ros_dev-dockerargs` — docker run flags

Extra flags appended to every `docker run` call:

```
--privileged
--volume /run/udev:/run/udev:ro
-e RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
-e ROS_DOMAIN_ID=1
```

`CYCLONEDDS_URI` is intentionally absent here — it is injected dynamically by `run_dev_orx.sh` and `deploy_orx.sh` (see [CycloneDDS](#cyclonedds)).

### `scripts/docker/Dockerfile.dependency` — custom image layer

The only Docker layer you maintain. It runs on top of the Isaac ROS base image and:

1. Installs apt packages needed at runtime.
2. Copies only `package.xml` files (not source code) and runs `rosdep install` — this layer is Docker-cached until a `package.xml` changes, so `colcon build` inside the container never needs a network call.

```dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    ros-jazzy-my-dep \
    ros-jazzy-rmw-cyclonedds-cpp \
    && rm -rf /var/lib/apt/lists/*

COPY src/my_package/package.xml /tmp/ros_deps/my_package/package.xml
# add one COPY line per package in src/

RUN apt-get update \
    && rosdep update \
    && rosdep install --from-paths /tmp/ros_deps --ignore-src -r -y \
    && rm -rf /tmp/ros_deps /var/lib/apt/lists/*
```

---

## CycloneDDS

The container uses CycloneDDS as the ROS 2 middleware (`RMW_IMPLEMENTATION=rmw_cyclonedds_cpp`). The network interface, multicast, and socket buffer settings are in `cyclone_profile_orx.xml` at the workspace root.

**Default** — the workspace profile is used automatically; no action needed:

```bash
./run_dev_orx.sh
```

**External profile** — to share a single DDS config across multiple projects, set `CYCLONEDDS_PROFILE` on the host before running. The file is bind-mounted read-only into the container:

```bash
export CYCLONEDDS_PROFILE=/shared/configs/robot_dds.xml
./run_dev_orx.sh
# or
CYCLONEDDS_PROFILE=/shared/configs/robot_dds.xml ./deploy_orx.sh
```

**Socket buffer size warning** — if you see `failed to increase socket receive buffer size`, run on the host:

```bash
sudo sysctl -w net.core.rmem_max=10485760
sudo sysctl -w net.core.rmem_default=10485760
```

To make this persistent, add those two lines to `/etc/sysctl.d/99-cyclonedds.conf`.

**Changing the network interface** — edit `cyclone_profile_orx.xml`:

```xml
<NetworkInterface name="eth0" multicast="true" />
```

Use `ip link` on the host to find the correct interface name.

---

## Docker image layer architecture

| Layer | Dockerfile location | Purpose |
|-------|-------------------|---------|
| `isaac_ros` | `/etc/isaac-ros-cli/docker/Dockerfile.isaac_ros` | NVIDIA base (CUDA, cuDNN, Isaac ROS) |
| `noble` | `/etc/isaac-ros-cli/docker/Dockerfile.noble` | Ubuntu Noble base tweaks |
| `dependency` | `scripts/docker/Dockerfile.dependency` | Project ROS packages and rosdep deps |

Additional layers (e.g. a ZED SDK layer) can be inserted by listing them in `additional_image_keys` and `image_key_order`.

---

## Docker args loading order

When `isaac-ros activate` starts the container it collects docker run flags from three sources:

```
1. $DOCKER_ARGS_FILE              loaded FIRST  (set by run_dev_orx.sh / deploy_orx.sh)
2. ~/.isaac_ros_dev-dockerargs    user-level
3. scripts/.isaac_ros_dev-dockerargs  loaded LAST (workspace defaults)
```

Docker uses the **last** occurrence of `-e KEY=value`. Because `CYCLONEDDS_URI` is absent from source 3, the value written by `run_dev_orx.sh` / `deploy_orx.sh` into source 1 is the only occurrence and therefore takes effect — enabling the `CYCLONEDDS_PROFILE` override mechanism.

---

## Adapting to a new project

Copy this repository structure and change the following files:

| File | What to change |
|------|---------------|
| `project_orx.env` | `PROJECT_NAME`, `REGISTRY`, `LAUNCH_PKG`, `LAUNCH_FILE` |
| `scripts/.isaac-ros-cli/config.yaml` | `container_name`, `additional_image_keys` |
| `scripts/.build_image_layers.yaml` | `image_key_order` (must mirror `additional_image_keys`) |
| `scripts/docker/Dockerfile.dependency` | apt packages, `COPY src/<pkg>/package.xml` lines |
| `cyclone_profile_orx.xml` | `NetworkInterface name` (match your host NIC) |

The scripts `run_dev_orx.sh`, `deploy_orx.sh`, `build_package_orx.sh`, and `scripts/build_package.sh` are fully generic and require no changes.

---

## Quick reference

| Task | Command |
|------|---------|
| Start dev container | `./run_dev_orx.sh` |
| Rebuild Docker image | `./run_dev_orx.sh --rebuild` |
| Build ROS 2 package | `bash scripts/build_package.sh` |
| Run default launch file | `./deploy_orx.sh` |
| Run a different launch file | `./deploy_orx.sh other.launch.py [args]` |
| Use an external DDS profile | `CYCLONEDDS_PROFILE=/path/to/dds.xml ./run_dev_orx.sh` |
| Push dev image to registry | `docker push <REGISTRY>/<PROJECT_NAME>:dev` |
