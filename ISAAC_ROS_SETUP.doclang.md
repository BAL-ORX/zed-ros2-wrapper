---
doclang: "1.0"
id: isaac-ros-dev-environment
title: Isaac ROS Development Environment — Setup Guide
purpose: >
  Enable an AI agent to understand, operate, and replicate this Isaac ROS
  containerised development environment for any ROS 2 package.
audience: AI agent
scope: >
  Covers how the environment works (conceptual model), how to use it day-to-day,
  and how to wire up a new ROS 2 package from scratch.
---


# @context

## What this environment is

This is a Docker-based development environment built on the **Isaac ROS CLI**
(`isaac-ros activate`). It provides a reproducible container with CUDA, ROS 2
Jazzy, and project-specific dependencies pre-installed.

The key property is that the **workspace root on the host is bind-mounted** at
`/workspaces/isaac_ros-dev` inside the container. Every file the agent creates
or edits on the host is instantly visible inside the container without
rebuilding the image.

## Mental model: three layers

```
Host filesystem  ←→  bind-mount  ←→  Container (/workspaces/isaac_ros-dev)
      ↑
  Docker image (read-only at runtime)
      = Base Isaac ROS image
      + scripts/docker/Dockerfile.dependency  (apt packages, rosdep pre-install)
      + optional vendor layers (e.g. ZED SDK)
```

Separating the image (slow to build, rarely changes) from the workspace
(fast to edit, changes constantly) is the core design principle.

## Runtime identity of this specific project

The following values are specific to the ZED ROS 2 wrapper project. When
adapting to a new project, all of these change.

| Variable | Current value |
|----------|--------------|
| PROJECT_NAME | `zed-ros2-wrapper` |
| REGISTRY | `cr.gitlab.uzh.ch/bal-orx` |
| LAUNCH_PKG | `zed_wrapper` |
| LAUNCH_FILE | `orx_zed_camera.launch.py` |
| container_name | `zed_dev_container` |
| IMAGE_KEY | `dependency` |


# @vocabulary

| Term | Definition |
|------|-----------|
| `WORKSPACE` | Absolute path of the repository root on the host machine. |
| `IMAGE_KEY` | Short string that identifies a Docker layer. Must match the suffix of `Dockerfile.<IMAGE_KEY>`. Example: `dependency`. |
| `PROJECT_NAME` | Kebab-case name used for the Docker registry image tag. Example: `my-robot-driver`. |
| `REGISTRY` | Container registry prefix. Example: `registry.example.com/my-org`. |
| `LAUNCH_PKG` | ROS 2 package name that contains the default launch file. |
| `LAUNCH_FILE` | Default `.launch.py` file inside `LAUNCH_PKG`. |
| `CONTAINER_NAME` | Docker container name; must be unique per project on the same host. |
| `NIC` | Host network interface name (e.g. `eth0`, `enp10s0`). Find with `ip link`. |
| `cached_isaac_run_dev_image_local:latest` | The local Docker image tag that `isaac-ros activate --use-cached-build-image` looks for. |
| `DEV_IMAGE` | Registry image: `${REGISTRY}/${PROJECT_NAME}:dev`. |
| `CYCLONEDDS_PROFILE` | Optional host environment variable. If set, its value must be an absolute path to an external CycloneDDS XML config that will be mounted into the container. |


# @architecture

## File layout

```
WORKSPACE/
├── <project>.env              — project identity: PROJECT_NAME, REGISTRY, LAUNCH_PKG, LAUNCH_FILE
├── run_dev_<suffix>.sh        — start or rebuild the dev container
├── deploy_<suffix>.sh         — build ROS 2 package and run a launch file in the container
├── build_package_<suffix>.sh  — root wrapper, delegates to scripts/build_package.sh
├── cyclone_profile_<suffix>.xml — CycloneDDS network config for this project
│
└── scripts/
    ├── build_package.sh               ← GENERIC, never edit
    ├── .isaac_ros_common-config       — tells CLI where to find Dockerfiles
    ├── .isaac_ros_dev-dockerargs      — extra docker run flags (privileges, DDS middleware)
    ├── .isaac-ros-cli/
    │   └── config.yaml                — container name + active image keys (RUNTIME)
    ├── .build_image_layers.yaml       — layer build order + build contexts (BUILD-TIME)
    └── docker/
        └── Dockerfile.<IMAGE_KEY>     — custom layer: apt packages + rosdep pre-install
```

## Two separate CLI config systems

The Isaac ROS CLI has two loaders that read different files for different
purposes. An agent MUST keep them in sync.

| File | Loader | Purpose | Key field |
|------|--------|---------|-----------|
| `scripts/.isaac-ros-cli/config.yaml` | `config_loader.py` | Runtime: which keys to include in image name | `additional_image_keys` |
| `scripts/.build_image_layers.yaml` | `build_image_layers.py` | Build-time: layer build sequence | `image_key_order` |

**Invariant:** Every key in `additional_image_keys` MUST appear (with the
`isaac_ros.` prefix stripped) somewhere in `image_key_order`, and vice versa.

## Docker args loading order

When `isaac-ros activate` starts the container it merges docker run flags from
three sources in this order:

```
Position 1 — $DOCKER_ARGS_FILE          (set by run_dev / deploy scripts — loaded FIRST)
Position 2 — ~/.isaac_ros_dev-dockerargs (user-level)
Position 3 — scripts/.isaac_ros_dev-dockerargs  (workspace — loaded LAST)
```

Docker uses the **last** occurrence of any `-e KEY=value` flag. This means
position 3 (workspace file) normally wins over position 1.

**CycloneDDS exception:** `CYCLONEDDS_URI` is intentionally absent from
position 3. The scripts write it only to position 1 (via a temp file in
`$DOCKER_ARGS_FILE`). Because no later source overrides it, the value from
position 1 is used. This enables the `CYCLONEDDS_PROFILE` override mechanism
without touching the workspace dockerargs file.

## CycloneDDS configuration

The container always uses CycloneDDS as RMW:
`RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` (set in `scripts/.isaac_ros_dev-dockerargs`).

`CYCLONEDDS_URI` resolution at container start:

```
if $CYCLONEDDS_PROFILE is set on the host:
    → mount that file as /cyclone_profile.xml (read-only) inside container
    → set CYCLONEDDS_URI=/cyclone_profile.xml
else:
    → set CYCLONEDDS_URI=/workspaces/isaac_ros-dev/<cyclone_profile_file>
       (the project's own cyclone_profile_<suffix>.xml, visible via bind-mount)
```

This lets a single DDS config be shared across multiple projects by setting
`CYCLONEDDS_PROFILE` on the host.


# @operations

## Operation: start the dev container

```bash
./run_dev_<suffix>.sh
```

### What happens (in order)

1. Sources `<project>.env` to get `REGISTRY` and `PROJECT_NAME`.
2. Builds a temp `$DOCKER_ARGS_FILE` with `-e CYCLONEDDS_URI=...` (resolved
   using `CYCLONEDDS_PROFILE` if set, else workspace XML).
3. Checks for `cached_isaac_run_dev_image_local:latest` locally.
   - If found → skip to step 5.
   - If not found → attempt `docker pull ${REGISTRY}/${PROJECT_NAME}:dev`.
     - If pull succeeds → `docker tag` it as the local cache name → skip to step 5.
     - If pull fails → build locally (step 4).
4. `--rebuild` flag or pull failure: runs
   `isaac-ros activate --build-local` with `ISAAC_DIR=WORKSPACE` and
   `ISAAC_ROS_WS=WORKSPACE/scripts`. Tags result as both local cache and `DEV_IMAGE`.
5. Runs `isaac-ros activate --use-cached-build-image` with
   `DOCKER_ARGS_FILE` set → drops user into container shell at
   `/workspaces/isaac_ros-dev`.

## Operation: build the ROS 2 package

```bash
# From inside the container:
bash scripts/build_package.sh

# From the host:
bash build_package_<suffix>.sh   # delegates to scripts/build_package.sh
```

Runs:
```bash
colcon build --symlink-install --base-paths src/ \
    --cmake-args=-DCMAKE_BUILD_TYPE=Release \
    --parallel-workers $(nproc)
```

`--symlink-install` means Python and launch files are symlinked — no rebuild
needed after editing them. C++ changes require a rebuild.

`rosdep install` is NEVER called here. All dependencies are pre-installed in
the Docker image via `Dockerfile.<IMAGE_KEY>`.

## Operation: run a launch file

```bash
# From the host (builds if needed, then launches):
./deploy_<suffix>.sh [LAUNCH_FILE [LAUNCH_ARGS...]]

# From inside the container:
source install/setup.bash
ros2 launch $LAUNCH_PKG $LAUNCH_FILE
```

`deploy_<suffix>.sh` behaviour:
1. If the container is not running → start it in `--detach` mode (combined
   with CycloneDDS args in a single `$DOCKER_ARGS_FILE`), register a
   `trap` to stop it on exit.
2. Check inside the container whether a colcon build exists
   (`install/$LAUNCH_PKG/share/$LAUNCH_PKG/package.xml`). If not → build first.
3. `docker exec` the launch command.

## Operation: rebuild the Docker image

```bash
./run_dev_<suffix>.sh --rebuild
```

When to use: after changing `scripts/docker/Dockerfile.<IMAGE_KEY>` (new apt
packages, changed `package.xml` dependencies).

After rebuilding, push to registry so teammates can pull without rebuilding:
```bash
docker push ${REGISTRY}/${PROJECT_NAME}:dev
```


# @setup — wiring a new ROS 2 package

Follow these steps in order. Do NOT skip or reorder.

## Step 1 — Collect required information

Before creating any file, resolve these values. If any cannot be inferred,
ask the user.

| Symbol | How to resolve |
|--------|---------------|
| `PROJECT_NAME` | Kebab-case repository name. Infer from directory name or ask. |
| `REGISTRY` | Container registry prefix. Ask the user. |
| `LAUNCH_PKG` | ROS 2 package name. Infer from `src/*/package.xml` where `<exec_depend>` suggests a node. |
| `LAUNCH_FILE` | Default launch file. Infer from `src/*/launch/*.launch.py`, or ask. |
| `CONTAINER_NAME` | Derive as `${PROJECT_NAME//-/_}_dev_container` or ask. |
| `IMAGE_KEY` | Use `dependency` unless the project adds a vendor layer. |
| `NIC` | Run `ip link show` and ask user to confirm which interface to use. |
| `SUFFIX` | Naming suffix for project files (e.g. `orx`). Ask the user. |

## Step 2 — Validate prerequisites

```bash
which isaac-ros          # must succeed
ls src/*/package.xml     # must find at least one package
```

If either fails, report and stop.

## Step 3 — Create `<project>.env`

Filename pattern: `project_<SUFFIX>.env`

```bash
PROJECT_NAME="<PROJECT_NAME>"
REGISTRY="<REGISTRY>"
LAUNCH_PKG="<LAUNCH_PKG>"
LAUNCH_FILE="<LAUNCH_FILE>"
```

## Step 4 — Create `scripts/` structure

```
scripts/
scripts/docker/
scripts/.isaac-ros-cli/
```

## Step 5 — Create `scripts/.isaac-ros-cli/config.yaml`

```yaml
docker:
  run:
    container_name: <CONTAINER_NAME>
  image:
    additional_image_keys:
      - <IMAGE_KEY>
```

## Step 6 — Create `scripts/.build_image_layers.yaml`

```yaml
image_key_order:
  - isaac_ros.<IMAGE_KEY>

context_overrides:
  isaac_ros: ..
  noble: ..
  <IMAGE_KEY>: ../..

cache_to_registry_names: []
cache_from_registry_names:
  - nvcr.io/nvidia/isaac/ros
remote_builder: {}
```

`<IMAGE_KEY>: ../..` sets the Docker build context to the workspace root so
that `COPY src/<pkg>/package.xml` works inside the Dockerfile.

## Step 7 — Create `scripts/docker/Dockerfile.<IMAGE_KEY>`

1. Scan `src/*/package.xml` for `<depend>`, `<build_depend>`, `<exec_depend>`.
2. Map each to a `ros-jazzy-*` apt package where available.
3. `ros-jazzy-rmw-cyclonedds-cpp` MUST always be present.

```dockerfile
# syntax=docker/dockerfile:1
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    ros-jazzy-rmw-cyclonedds-cpp \
<#  one line per additional dep: ros-jazzy-<dep> \ >
    && rm -rf /var/lib/apt/lists/*

<# One COPY line per package under src/: >
COPY src/<PKG>/package.xml /tmp/ros_deps/<PKG>/package.xml

RUN apt-get update \
    && rosdep update \
    && rosdep install --from-paths /tmp/ros_deps --ignore-src -r -y \
    && rm -rf /tmp/ros_deps /var/lib/apt/lists/*
```

## Step 8 — Create `scripts/.isaac_ros_common-config`

```bash
CONFIG_DOCKER_SEARCH_DIRS=(/etc/isaac-ros-cli/docker docker)
```

## Step 9 — Create `scripts/.isaac_ros_dev-dockerargs`

```
--privileged
--volume /run/udev:/run/udev:ro
-e RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
-e ROS_DOMAIN_ID=1
```

MUST NOT contain `-e CYCLONEDDS_URI`. It is injected dynamically by the
run/deploy scripts.

## Step 10 — Create `cyclone_profile_<SUFFIX>.xml`

```xml
<CycloneDDS xmlns="https://cdds.io/config"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
            xsi:schemaLocation="https://cdds.io/config https://raw.githubusercontent.com/eclipse-cyclonedds/cyclonedds/master/etc/cyclonedds.xsd">
    <Domain id="any">
        <General>
            <Interfaces>
                <NetworkInterface name="<NIC>" multicast="true" />
            </Interfaces>
            <AllowMulticast>true</AllowMulticast>
            <EnableMulticastLoopback>true</EnableMulticastLoopback>
            <MaxMessageSize>65500B</MaxMessageSize>
        </General>
        <Internal>
            <SocketReceiveBufferSize min="10MB"/>
            <Watermarks>
                <WhcHigh>500kB</WhcHigh>
            </Watermarks>
        </Internal>
        <Discovery>
            <ParticipantIndex>auto</ParticipantIndex>
            <MaxAutoParticipantIndex>100</MaxAutoParticipantIndex>
        </Discovery>
    </Domain>
</CycloneDDS>
```

## Step 11 — Create `.dockerignore` at workspace root

```
build/
install/
log/
.git/
```

Required because the workspace root is the Docker build context for the
`<IMAGE_KEY>` layer. Without this, colcon artifacts (~GB) are sent to the
Docker daemon on every build.

## Step 12 — Create `scripts/build_package.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

colcon build \
    --symlink-install \
    --base-paths src/ \
    --cmake-args=-DCMAKE_BUILD_TYPE=Release \
    --parallel-workers $(nproc)
```

`chmod +x scripts/build_package.sh`

## Step 13 — Create `build_package_<SUFFIX>.sh` (root wrapper)

```bash
#!/usr/bin/env bash
exec "$(dirname "${BASH_SOURCE[0]}")/scripts/build_package.sh" "$@"
```

`chmod +x build_package_<SUFFIX>.sh`

## Step 14 — Create `run_dev_<SUFFIX>.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${WORKSPACE}/project_<SUFFIX>.env"

DEV_IMAGE="${REGISTRY}/${PROJECT_NAME}:dev"
CACHED="cached_isaac_run_dev_image_local:latest"

_CYCLONE_ARGS=$(mktemp)
if [[ -n "${CYCLONEDDS_PROFILE:-}" ]]; then
    [[ -f "${CYCLONEDDS_PROFILE}" ]] || \
        { echo "[run_dev] ERROR: CYCLONEDDS_PROFILE not found: ${CYCLONEDDS_PROFILE}"; exit 1; }
    echo "-v ${CYCLONEDDS_PROFILE}:/cyclone_profile.xml:ro" >> "${_CYCLONE_ARGS}"
    echo "-e CYCLONEDDS_URI=/cyclone_profile.xml" >> "${_CYCLONE_ARGS}"
else
    echo "-e CYCLONEDDS_URI=/workspaces/isaac_ros-dev/cyclone_profile_<SUFFIX>.xml" >> "${_CYCLONE_ARGS}"
fi
export DOCKER_ARGS_FILE="${_CYCLONE_ARGS}"

if [[ "${1:-}" == "--rebuild" ]]; then
    shift
    ISAAC_DIR="${WORKSPACE}" ISAAC_ROS_WS="${WORKSPACE}/scripts" \
        isaac-ros activate --build-local "$@"
    docker tag "${CACHED}" "${DEV_IMAGE}"
elif ! docker image inspect "${CACHED}" &>/dev/null; then
    if docker pull "${DEV_IMAGE}"; then
        docker tag "${DEV_IMAGE}" "${CACHED}"
    else
        ISAAC_DIR="${WORKSPACE}" ISAAC_ROS_WS="${WORKSPACE}/scripts" \
            isaac-ros activate --build-local "$@"
        docker tag "${CACHED}" "${DEV_IMAGE}"
    fi
fi

export ISAAC_DIR="${WORKSPACE}"
export ISAAC_ROS_WS="${WORKSPACE}/scripts"
exec isaac-ros activate --use-cached-build-image "$@"
```

`chmod +x run_dev_<SUFFIX>.sh`

## Step 15 — Create `deploy_<SUFFIX>.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${WORKSPACE}/project_<SUFFIX>.env"

LAUNCH_FILE="${1:-${LAUNCH_FILE}}"
shift 2>/dev/null || true
LAUNCH_ARGS="${*:-}"

CONTAINER=$(grep -m1 'container_name:' \
    "${WORKSPACE}/scripts/.isaac-ros-cli/config.yaml" | awk '{print $2}')

read -r -d '' STARTUP <<HEREDOC || true
set -e
WS=/workspaces/isaac_ros-dev
source "/opt/ros/\${ROS_DISTRO:-jazzy}/setup.bash" 2>/dev/null || true
source "/opt/ros_ws/install/setup.bash" 2>/dev/null || true
if [ ! -f "\${WS}/install/${LAUNCH_PKG}/share/${LAUNCH_PKG}/package.xml" ]; then
    echo "[deploy] No colcon build found — building..."
    cd "\${WS}"
    bash "\${WS}/scripts/build_package.sh"
fi
source "\${WS}/install/setup.bash"
exec ros2 launch ${LAUNCH_PKG} ${LAUNCH_FILE}${LAUNCH_ARGS:+ ${LAUNCH_ARGS}}
HEREDOC

if ! docker ps --quiet --filter "name=^/${CONTAINER}$" | grep -q .; then
    _DETACH_ARGS=$(mktemp)
    echo "--detach" > "${_DETACH_ARGS}"
    if [[ -n "${CYCLONEDDS_PROFILE:-}" ]]; then
        [[ -f "${CYCLONEDDS_PROFILE}" ]] || \
            { echo "[deploy] ERROR: CYCLONEDDS_PROFILE not found: ${CYCLONEDDS_PROFILE}"; exit 1; }
        echo "-v ${CYCLONEDDS_PROFILE}:/cyclone_profile.xml:ro" >> "${_DETACH_ARGS}"
        echo "-e CYCLONEDDS_URI=/cyclone_profile.xml" >> "${_DETACH_ARGS}"
    else
        echo "-e CYCLONEDDS_URI=/workspaces/isaac_ros-dev/cyclone_profile_<SUFFIX>.xml" >> "${_DETACH_ARGS}"
    fi
    DOCKER_ARGS_FILE="${_DETACH_ARGS}" \
    ISAAC_DIR="${WORKSPACE}" \
    ISAAC_ROS_WS="${WORKSPACE}/scripts" \
        isaac-ros activate --use-cached-build-image
    rm -f "${_DETACH_ARGS}"
    trap "docker stop '${CONTAINER}' > /dev/null" EXIT
fi

docker exec -it "${CONTAINER}" /bin/bash -c "${STARTUP}"
```

`chmod +x deploy_<SUFFIX>.sh`


# @constraints

These MUST hold at all times. Any agent modifying this environment MUST verify
each constraint after making changes.

| ID | Constraint |
|----|-----------|
| C1 | `CYCLONEDDS_URI` MUST NOT appear in `scripts/.isaac_ros_dev-dockerargs`. |
| C2 | `ros-jazzy-rmw-cyclonedds-cpp` MUST be installed in `Dockerfile.<IMAGE_KEY>`. |
| C3 | `rosdep install` MUST NOT be called outside of `Dockerfile.<IMAGE_KEY>`. |
| C4 | `colcon build` MUST NOT be called inside any Dockerfile. |
| C5 | `additional_image_keys` (config.yaml) and `image_key_order` (build_image_layers.yaml) MUST reference the same set of custom keys. |
| C6 | The `context_overrides` entry for `<IMAGE_KEY>` MUST resolve to the workspace root. |
| C7 | `.dockerignore` MUST exclude `build/`, `install/`, `log/`, `.git/`. |
| C8 | Only `package.xml` files are COPY-ed in the Dockerfile — never source files. |
| C9 | `scripts/build_package.sh` is generic and MUST NOT be edited per project. |
| C10 | `ISAAC_ROS_WS` MUST point to `WORKSPACE/scripts` when calling `isaac-ros activate`. |


# @validation

Run after completing setup or after any modification.

```bash
# 1. File existence
for f in \
    project_<SUFFIX>.env \
    run_dev_<SUFFIX>.sh \
    deploy_<SUFFIX>.sh \
    build_package_<SUFFIX>.sh \
    .dockerignore \
    cyclone_profile_<SUFFIX>.xml \
    scripts/build_package.sh \
    scripts/.isaac_ros_common-config \
    scripts/.isaac_ros_dev-dockerargs \
    scripts/.isaac-ros-cli/config.yaml \
    scripts/.build_image_layers.yaml \
    "scripts/docker/Dockerfile.<IMAGE_KEY>"; do
    test -f "$f" || echo "MISSING: $f"
done

# 2. Executable bits
for f in run_dev_<SUFFIX>.sh deploy_<SUFFIX>.sh \
          build_package_<SUFFIX>.sh scripts/build_package.sh; do
    test -x "$f" || echo "NOT EXECUTABLE: $f"
done

# 3. Bash syntax
bash -n run_dev_<SUFFIX>.sh
bash -n deploy_<SUFFIX>.sh
bash -n build_package_<SUFFIX>.sh
bash -n scripts/build_package.sh

# 4. Constraint C1 — CYCLONEDDS_URI absent from workspace dockerargs
grep -q 'CYCLONEDDS_URI' scripts/.isaac_ros_dev-dockerargs \
    && echo "VIOLATION C1: CYCLONEDDS_URI found in dockerargs"

# 5. Constraint C5 — key sync between the two YAML files
echo "additional_image_keys:"; \
    grep -A5 'additional_image_keys' scripts/.isaac-ros-cli/config.yaml
echo "image_key_order:"; \
    grep -A5 'image_key_order' scripts/.build_image_layers.yaml

# 6. No old filenames remain in functional code
grep -rn 'project\.env\b' \
    --include='*.sh' --include='*.py' --include='*.yaml' . | grep -v '\.md'
```

All checks must produce no output (no missing files, no violations, no stale
references).
