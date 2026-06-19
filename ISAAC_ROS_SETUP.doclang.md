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
| `cached_isaac_run_dev_image_local:latest` | The machine-global Docker image tag that `isaac-ros activate --use-cached-build-image` looks for. Written as late as possible (just before `exec`/`activate`) to minimise the race window when multiple projects start simultaneously. |
| `CACHED_LOCAL` | Project-specific tag: `cached_isaac_run_dev_image_local_${PROJECT_NAME}:latest`. Used for all image resolution and consistency checks; stamped to the global tag only at the last moment. |
| `DEV_IMAGE` | Registry image: `${REGISTRY}/${PROJECT_NAME}:dev`. |
| `CYCLONEDDS_PROFILE` | Optional host environment variable. If set, its value must be an absolute path to an external CycloneDDS XML config that will be mounted into the container. |
| `SIDECAR_NODE` | A composable node loaded into the same `ComposableNodeContainer` as the primary node to participate in NITROS zero-copy IPC. Not a separate process; not a separate container. |
| `TARGET_CONTAINER` | Fully-qualified ROS 2 name of the container a sidecar loads into: `/{namespace}/{container_name}`. Must match the container created by the primary launch file. |


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

## Docker args loading — CLI limitation and workaround

`/usr/lib/isaac-ros-cli/run_dev.py` collects docker run flags from these
sources (read in order, Docker uses the **last** occurrence of any `-e KEY`):

```
Position 1 — $DOCKER_ARGS_FILE                   (always read — reliable)
Position 2 — ~/.isaac_ros_dev-dockerargs          (user-level, optional)
Position 3 — $ISAAC_ROS_WS/scripts/.isaac_ros_dev-dockerargs  OR
             /etc/isaac-ros-cli/.isaac_ros_dev-dockerargs     (fallback)
```

**Known CLI bug:** two modules in the CLI interpret `ISAAC_ROS_WS` differently:

| Module | Expects `ISAAC_ROS_WS` to be | Constructs path |
|--------|------------------------------|-----------------|
| `run_dev.py` (dockerargs) | workspace root | `$ISAAC_ROS_WS/scripts/.isaac_ros_dev-dockerargs` |
| `isaac_ros_common_config_utils.py` (build config) | scripts dir | `$ISAAC_ROS_WS/../scripts/.build_image_layers.yaml` |

These expectations are mutually exclusive. We set `ISAAC_ROS_WS="${WORKSPACE}/scripts"`
to satisfy the build config loader. As a side effect, `run_dev.py` constructs
`${WORKSPACE}/scripts/scripts/.isaac_ros_dev-dockerargs` (double `scripts/`),
which does not exist, so it falls back to `/etc/isaac-ros-cli/.isaac_ros_dev-dockerargs`
(which only mounts user home directories — not our env vars).

**Workaround:** `run_dev_<SUFFIX>.sh` and `deploy_<SUFFIX>.sh` read
`scripts/.isaac_ros_dev-dockerargs` themselves (stripping comments/blanks with
`grep`) and write its content into the `$DOCKER_ARGS_FILE` temp file, which IS
always reliably read at position 1. `CYCLONEDDS_URI` is appended after.

```
DOCKER_ARGS_FILE temp file (position 1) contains:
  1. content of scripts/.isaac_ros_dev-dockerargs  (--privileged, -e RMW_IMPLEMENTATION, …)
  2. -e CYCLONEDDS_URI=…  (resolved from CYCLONEDDS_PROFILE or workspace XML)
  [deploy only: --detach prepended at the top]
```

## Multi-project cache — design

`cached_isaac_run_dev_image_local:latest` is a **machine-global** Docker tag.
Any `isaac-ros activate --build-local` on any project on the host overwrites it.
All containers in this setup share `ROS_DOMAIN_ID=1` by design — they are
intended to communicate with each other over ROS.

**Simultaneous-startup safety:** each script maintains a **project-specific**
tag `CACHED_LOCAL = cached_isaac_run_dev_image_local_${PROJECT_NAME}:latest` for
all image resolution and consistency checks. The global tag is only written in
the final line before `isaac-ros activate`, minimising the race window to a
single `docker tag` call. Running two projects back-to-back (even seconds apart)
is therefore safe; exact-same-instant startup has a negligible remaining window.

**Consistency guard:** compares `CACHED_LOCAL` to `DEV_IMAGE` by image ID. If
they differ (e.g. CI pushed a new image), the local tag is updated from
`DEV_IMAGE` — instant, no network. `deploy` additionally handles the case where
`CACHED_LOCAL` is missing entirely (no prior `run_dev`) by pulling `DEV_IMAGE`.

## CycloneDDS configuration

The container always uses CycloneDDS as RMW:
`RMW_IMPLEMENTATION=rmw_cyclonedds_cpp` (set in `scripts/.isaac_ros_dev-dockerargs`,
injected via `DOCKER_ARGS_FILE` by the run/deploy scripts).

`CYCLONEDDS_URI` resolution at container start:

```
if $CYCLONEDDS_PROFILE is set on the host:
    → mount that file as /cyclone_profile.xml (read-only) inside container
    → set CYCLONEDDS_URI=/cyclone_profile.xml
else:
    → set CYCLONEDDS_URI=/workspaces/isaac_ros-dev/cyclone_profile_<SUFFIX>.xml
       (the project's own XML file, visible via bind-mount)
```

This lets a single DDS config be shared across multiple projects by setting
`CYCLONEDDS_PROFILE` on the host.


# @operations

## Operation: start the dev container

```bash
./run_dev_<suffix>.sh
```

### What happens (in order)

1. Sources `project_<SUFFIX>.env` to get `REGISTRY` and `PROJECT_NAME`.
2. Builds a temp `$DOCKER_ARGS_FILE`:
   - Reads `scripts/.isaac_ros_dev-dockerargs` (strips comments/blanks) and appends all lines.
   - Appends `-e CYCLONEDDS_URI=...` (resolved from `CYCLONEDDS_PROFILE` or workspace XML).
3. Checks for `CACHED_LOCAL` (`cached_isaac_run_dev_image_local_${PROJECT_NAME}:latest`) locally.
   - If found → skip to step 4b.
   - If not found → attempt `docker pull ${REGISTRY}/${PROJECT_NAME}:dev`.
     - If pull succeeds → `docker tag` it as `CACHED_LOCAL` → skip to step 4b.
     - If pull fails → build locally (step 4 `--rebuild` path).
4. `--rebuild` flag or pull failure: runs
   `isaac-ros activate --build-local` with `ISAAC_DIR=WORKSPACE` and
   `ISAAC_ROS_WS=WORKSPACE/scripts`. Tags result as both `CACHED_LOCAL` and
   `DEV_IMAGE`. Then runs GC: removes all
   `nvcr.io/nvidia/isaac/ros[:/]*-dependency_*-amd64*` images whose ID no longer
   matches the freshly built cache (stale rebuilds).
4b. Consistency guard: compares `CACHED_LOCAL` to `DEV_IMAGE` by image ID. If
    they differ (e.g. CI pushed a newer image), repoints `CACHED_LOCAL` to
    `DEV_IMAGE` — instant, no network.
4c. Stamps the global tag: `docker tag "${CACHED_LOCAL}" "${CACHED}"` — this is
    the only moment the global tag is written, minimising the race window.
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
1. Consistency guard on `CACHED_LOCAL` (project-specific tag). Deploy can be
   invoked without run_dev, so it guards independently. If `CACHED_LOCAL` is
   missing entirely, it attempts to pull `DEV_IMAGE` first.
2. Stamps global tag: `docker tag "${CACHED_LOCAL}" "${CACHED}"`.
3. If the container is not running → build a `$DOCKER_ARGS_FILE` containing
   `--detach`, all lines from `scripts/.isaac_ros_dev-dockerargs`, and
   `CYCLONEDDS_URI`. Start the container, then register a `trap` to stop it on exit.
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

Rules:
- MUST NOT contain `-e CYCLONEDDS_URI` — injected dynamically by the run/deploy scripts.
- Comments (lines starting with `#`) and blank lines are stripped by `grep` before
  injection; they are safe to include for documentation.
- The CLI does **not** read this file directly (see the `ISAAC_ROS_WS` ambiguity in
  `@architecture`). The run/deploy scripts read it with `grep` and pipe it into
  `$DOCKER_ARGS_FILE` instead.

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
CACHED_LOCAL="cached_isaac_run_dev_image_local_${PROJECT_NAME}:latest"

# Build DOCKER_ARGS_FILE — the CLI reliably reads this (position 1).
# We self-read scripts/.isaac_ros_dev-dockerargs here because the CLI's native
# discovery of that file is broken by the ISAAC_ROS_WS ambiguity (see @architecture).
_DOCKER_ARGS=$(mktemp)
grep -v '^\s*#' "${WORKSPACE}/scripts/.isaac_ros_dev-dockerargs" | \
    grep -v '^\s*$' >> "${_DOCKER_ARGS}"
if [[ -n "${CYCLONEDDS_PROFILE:-}" ]]; then
    [[ -f "${CYCLONEDDS_PROFILE}" ]] || \
        { echo "[run_dev] ERROR: CYCLONEDDS_PROFILE not found: ${CYCLONEDDS_PROFILE}"; exit 1; }
    echo "-v ${CYCLONEDDS_PROFILE}:/cyclone_profile.xml:ro" >> "${_DOCKER_ARGS}"
    echo "-e CYCLONEDDS_URI=/cyclone_profile.xml" >> "${_DOCKER_ARGS}"
else
    echo "-e CYCLONEDDS_URI=/workspaces/isaac_ros-dev/cyclone_profile_<SUFFIX>.xml" >> "${_DOCKER_ARGS}"
fi
export DOCKER_ARGS_FILE="${_DOCKER_ARGS}"

if [[ "${1:-}" == "--rebuild" ]]; then
    shift
    ISAAC_DIR="${WORKSPACE}" ISAAC_ROS_WS="${WORKSPACE}/scripts" \
        isaac-ros activate --build-local "$@"
    docker tag "${CACHED}" "${CACHED_LOCAL}"
    docker tag "${CACHED}" "${DEV_IMAGE}"
    _new_id=$(docker inspect --format '{{.Id}}' "${CACHED}")
    while IFS=' ' read -r _tag _id; do
        [[ "${_id}" != "${_new_id}" ]] && docker rmi "${_tag}" 2>/dev/null || true
    done < <(docker images --no-trunc --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
        | grep -E 'nvcr\.io/nvidia/isaac/ros[:/].*-dependency_.*-amd64')
    unset _new_id _tag _id
elif ! docker image inspect "${CACHED_LOCAL}" &>/dev/null; then
    if docker pull "${DEV_IMAGE}"; then
        docker tag "${DEV_IMAGE}" "${CACHED_LOCAL}"
    else
        ISAAC_DIR="${WORKSPACE}" ISAAC_ROS_WS="${WORKSPACE}/scripts" \
            isaac-ros activate --build-local "$@"
        docker tag "${CACHED}" "${CACHED_LOCAL}"
        docker tag "${CACHED}" "${DEV_IMAGE}"
    fi
fi

_cached_id=$(docker inspect --format '{{.Id}}' "${CACHED_LOCAL}" 2>/dev/null || true)
_dev_id=$(docker inspect --format '{{.Id}}' "${DEV_IMAGE}" 2>/dev/null || true)
if [[ -n "${_dev_id}" && "${_cached_id}" != "${_dev_id}" ]]; then
    echo "[run_dev] Updating local cache from ${DEV_IMAGE}..."
    docker tag "${DEV_IMAGE}" "${CACHED_LOCAL}"
fi
unset _cached_id _dev_id

docker tag "${CACHED_LOCAL}" "${CACHED}"
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

DEV_IMAGE="${REGISTRY}/${PROJECT_NAME}:dev"
CACHED="cached_isaac_run_dev_image_local:latest"
CACHED_LOCAL="cached_isaac_run_dev_image_local_${PROJECT_NAME}:latest"

_cached_id=$(docker inspect --format '{{.Id}}' "${CACHED_LOCAL}" 2>/dev/null || true)
_dev_id=$(docker inspect --format '{{.Id}}' "${DEV_IMAGE}" 2>/dev/null || true)
if [[ -z "${_cached_id}" ]]; then
    docker pull "${DEV_IMAGE}" && docker tag "${DEV_IMAGE}" "${CACHED_LOCAL}" \
        || { echo "[deploy] ERROR: image not found. Run ./run_dev_<SUFFIX>.sh --rebuild"; exit 1; }
elif [[ -n "${_dev_id}" && "${_cached_id}" != "${_dev_id}" ]]; then
    echo "[deploy] Updating local cache from ${DEV_IMAGE}..."
    docker tag "${DEV_IMAGE}" "${CACHED_LOCAL}"
fi
unset _cached_id _dev_id
docker tag "${CACHED_LOCAL}" "${CACHED}"

if ! docker ps --quiet --filter "name=^/${CONTAINER}$" | grep -q .; then
    _DETACH_ARGS=$(mktemp)
    echo "--detach" > "${_DETACH_ARGS}"
    grep -v '^\s*#' "${WORKSPACE}/scripts/.isaac_ros_dev-dockerargs" | \
        grep -v '^\s*$' >> "${_DETACH_ARGS}"
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


# @patterns

## Pattern: optional sidecar composable node

Use this pattern to add a processing node (e.g. an H264 encoder, a depth
filter, a republisher) that must share a process with the primary node to
exploit NITROS zero-copy IPC. The sidecar is toggled by a flag in the project
config YAML; no launch file argument and no rebuild is needed to switch it on
or off.

### When to use

- The sidecar communicates with the primary node over NITROS types
  (`NitrosImage`, `NitrosTensor`, …).
- You want zero-copy transport without crossing a process boundary.
- The sidecar is optional: some deployments run it, others do not.

### Prerequisites

| Requirement | Why |
|-------------|-----|
| Primary node's `debug.disable_nitros` is `false` | NITROS negotiates zero-copy only when active |
| Both nodes are composable (`rclcpp_components`) | `LoadComposableNodes` requires this |
| The sidecar package is present in `src/` and built | It must be in the colcon workspace |
| The sidecar package's apt dependencies are in `Dockerfile.<IMAGE_KEY>` | Same image layer rule as any dependency |

If `disable_nitros: true` is set, both nodes will still run and communicate,
but over serialised DDS transport rather than zero-copy. There is no error.

### How NITROS zero-copy works

When two composable nodes share the same `ComposableNodeContainer` **and**
both use NITROS publisher/subscriber types, the NITROS framework negotiates a
zero-copy path at startup. This is independent of ROS 2's
`use_intra_process_comms` flag. Do **not** set `use_intra_process_comms: true`
on the sidecar — it is irrelevant for NITROS and can conflict with the primary
node's IPC policy (see `ipc_nitros_conflict_policy` in `@architecture`).

### Files to change

| File | Change |
|------|--------|
| `config_<SUFFIX>.yaml` | Add a top-level `<sidecar>:` section with `enabled`, topic names, and node parameters. |
| `src/<LAUNCH_PKG>/launch/orx_<SUFFIX>.launch.py` | Read `<sidecar>:` at launch time; conditionally call `LoadComposableNodes`. |
| `scripts/docker/Dockerfile.<IMAGE_KEY>` | Add the sidecar's apt packages. |

### Config YAML schema

Add a new top-level section (parallel to `launch:` and `ros_params:`):

```yaml
<sidecar>:
  enabled: false          # Toggle — no rebuild needed

  # Topic remappings (values are absolute ROS 2 topic paths).
  # Build input paths as /{namespace}/{node_name}/{topic_suffix}
  # to reach the primary node's private topics (published under ~/…).
  input_<stream>: "/<namespace>/<node_name>/<topic_suffix>"
  output_<stream>: "/<namespace>/<output_topic>"

  # Node-specific parameters (all passed via parameters=[{...}])
  <param_name>: <value>
```

**Rule:** `input_*` paths MUST use absolute topic names derived from the primary
node's private namespace (`~/` = `/{namespace}/{node_name}/`).

### Launch file changes

Inside `launch_setup()`, after the primary `IncludeLaunchDescription`, add:

```python
from launch_ros.actions import LoadComposableNodes
from launch_ros.descriptions import ComposableNode

if sidecar_cfg.get('enabled', False):
    # Resolve the container the primary node was loaded into.
    # zed_camera.launch.py creates 'zed_container' when container_name is empty.
    namespace       = launch_cfg.get('namespace', '') or launch_cfg.get('camera_name', 'zed')
    node_name       = launch_cfg.get('node_name', 'zed_node')
    container_name  = launch_cfg.get('container_name', '') or 'zed_container'
    target_container = f'/{namespace}/{container_name}'

    actions.append(LoadComposableNodes(
        composable_node_descriptions=[
            ComposableNode(
                package='<sidecar_package>',
                plugin='<vendor>::<SidecarNode>',
                name='<sidecar_node_name>',
                namespace=namespace,
                parameters=[{<param>: sidecar_cfg.get('<param>', <default>), ...}],
                remappings=[
                    ('input_topic',  f'/{namespace}/{node_name}/{input_suffix}'),
                    ('output_topic', f'/{namespace}/{output_suffix}'),
                ],
            )
        ],
        target_container=target_container,
    ))
```

**Do not** create a new `ComposableNodeContainer` for the sidecar. Loading into
`target_container` is what puts both nodes in the same process.

### Dockerfile change

A sidecar with heavy or NVIDIA-specific dependencies MUST get its own
`Dockerfile.<NEW_KEY>` rather than being appended to an existing layer.
Adding it to an existing Dockerfile would bust the cache for every package
already in that layer whenever the sidecar's deps change.

**Check whether the submodule already ships a Dockerfile:**

Many NVIDIA Isaac ROS submodules include `docker/Dockerfile.<KEY>` inside the
submodule directory. If one exists, use it as the starting point:

```
src/<submodule>/docker/Dockerfile.<KEY>   ← reference provided by the submodule
scripts/docker/Dockerfile.<KEY>           ← adapted copy consumed by the CLI
```

Always copy to `scripts/docker/` — the CLI searches `CONFIG_DOCKER_SEARCH_DIRS`
which resolves to `WORKSPACE/scripts/docker/` first. Then verify every
`COPY src/…` path: if the submodule is nested under `src/<submodule>/`, the
package.xml lives one level deeper than the submodule assumes, and the path
must be updated accordingly (see the concrete example below).

**1. Create `scripts/docker/Dockerfile.<NEW_KEY>`:**

```dockerfile
# syntax=docker/dockerfile:1
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    ros-jazzy-<sidecar-apt-package> \
    && rm -rf /var/lib/apt/lists/*

# Note: if the ROS package lives inside a submodule directory, the COPY path
# must reflect that nesting:
#   submodule at src/<submodule>/        → COPY src/<submodule>/<pkg>/package.xml
#   flat package at src/<pkg>/           → COPY src/<pkg>/package.xml
COPY src/<path-to>/package.xml /tmp/ros_deps/<pkg>/package.xml

RUN apt-get update \
    && rosdep update \
    && rosdep install --from-paths /tmp/ros_deps --ignore-src -r -y \
    && rm -rf /tmp/ros_deps /var/lib/apt/lists/*
```

**2. Register the new key in both CLI config files (C5 invariant):**

`scripts/.isaac-ros-cli/config.yaml` — append to `additional_image_keys`:
```yaml
additional_image_keys:
  - <existing_key>
  - <NEW_KEY>
```

`scripts/.build_image_layers.yaml` — append to `image_key_order` and add context override:
```yaml
image_key_order:
  - isaac_ros.<existing_keys>.<NEW_KEY>

context_overrides:
  <NEW_KEY>: ../..   # workspace root, enables COPY src/…
```

After editing both files, rebuild and push:
```bash
./run_dev_<SUFFIX>.sh --rebuild
docker push ${REGISTRY}/${PROJECT_NAME}:dev
```

### Concrete example: ZED + H264 encoder

The `isaac_ros_h264_encoder` submodule is the reference implementation of this
pattern in the ZED ROS 2 wrapper project.

| Symbol | Value |
|--------|-------|
| sidecar package | `isaac_ros_h264_encoder` |
| sidecar plugin | `nvidia::isaac_ros::h264_encoder::EncoderNode` |
| Docker layer key | `h264` → `scripts/docker/Dockerfile.h264` |
| config section | `encoder:` in `config_orx.yaml` |
| enabled toggle | `encoder.enabled: false` |
| target container | `/zed/zed_container` |
| input topics | `/{namespace}/{node_name}/left/color/rect/image` |
| output topics | `/{namespace}/left/image_compressed` |

Docker layer registration (C5 invariant — both files kept in sync):

```
scripts/.isaac-ros-cli/config.yaml   additional_image_keys: [zed, dependency, h264]
scripts/.build_image_layers.yaml     image_key_order: [isaac_ros.zed.dependency.h264]
                                     context_overrides: h264: ../..
```

**Dockerfile source — the submodule ships its own Dockerfile:**

```
src/isaac_ros_h264_encoder/docker/Dockerfile.h264   ← provided by the submodule
scripts/docker/Dockerfile.h264                       ← adapted copy used by the CLI
```

The submodule's Dockerfile is the reference, but it cannot be used directly because
its `COPY` path assumes the package sits at the submodule root:

```dockerfile
# submodule original — wrong for this project's layout:
COPY src/isaac_ros_h264_encoder/package.xml ...
```

When the submodule lives under `src/isaac_ros_h264_encoder/`, the ROS package is
nested one level deeper. The adapted copy in `scripts/docker/Dockerfile.h264`
corrects this:

```dockerfile
# scripts/docker/Dockerfile.h264 — correct for nested submodule:
COPY src/isaac_ros_h264_encoder/isaac_ros_h264_encoder/package.xml ...
```

**General rule:** when a submodule ships `<submodule>/docker/Dockerfile.<KEY>`,
copy it to `scripts/docker/Dockerfile.<KEY>` and verify every `COPY src/…`
path against the actual file tree. The CLI always uses the copy in
`scripts/docker/` (first in `CONFIG_DOCKER_SEARCH_DIRS`).

EncoderNode parameters declared in `encoder_node.cpp`:

| Parameter | Type | Default | Notes |
|-----------|------|---------|-------|
| `input_width` | int32 | 1920 | Must match ZED `grab_resolution` width |
| `input_height` | int32 | 1200 | Must match ZED `grab_resolution` height |
| `qp` | int32 | 20 | Quantization parameter [1-51]; lower = better quality |
| `hw_preset_type` | int32 | 0 | 0=default 1=hp 2=hq 3=ll 4=llhp 5=llhq 6=lossless |
| `profile` | int32 | 0 | 0=baseline 1=main 2=high |
| `iframe_interval` | int32 | 5 | Keyframe interval in frames |
| `config` | string | `"pframe_cqp"` | `"pframe_cqp"` \| `"iframe_cqp"` \| `"pframe_vbr"` |

ZED image topic naming — the ZED node uses `mTopicRoot = "~/"`, which
ROS 2 resolves to `/{namespace}/{node_name}/`. Image topics follow the pattern:

```
/{namespace}/{node_name}/{sensor}/{color_mode}/{rect_raw}/image

sensor     : left/ | right/ | rgb/ | stereo/
color_mode : color/ | gray/
rect_raw   : rect/ | raw/
```

Examples with defaults (`camera_name=zed`, `node_name=zed_node`):

| Topic | Description |
|-------|-------------|
| `/zed/zed_node/left/color/rect/image` | Left rectified colour — encoder input |
| `/zed/zed_node/right/color/rect/image` | Right rectified colour — encoder input |
| `/zed/zed_node/rgb/color/rect/image` | Combined RGB rectified colour |


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
| C10 | `ISAAC_ROS_WS` MUST be `WORKSPACE/scripts` for all `isaac-ros activate` calls (required by `isaac_ros_common_config_utils.py` for build config discovery). |
| C11 | `scripts/.isaac_ros_dev-dockerargs` MUST be read by the run/deploy scripts via `grep` and injected into `$DOCKER_ARGS_FILE` — never rely on the CLI to find it automatically. |
| C12 | run/deploy scripts MUST use a project-specific `CACHED_LOCAL` tag for all image resolution. The global `cached_isaac_run_dev_image_local:latest` MUST only be written in the single `docker tag` call immediately before `isaac-ros activate --use-cached-build-image`. |
| C13 | A sidecar node MUST be loaded via `LoadComposableNodes` into the existing `TARGET_CONTAINER` — never into a new `ComposableNodeContainer`. Creating a new container defeats zero-copy IPC. |
| C14 | Sidecar input topic remappings MUST use absolute paths derived from `/{namespace}/{node_name}/…`. Relative paths resolve against the sidecar's own namespace and will not reach the primary node's private topics. |
| C15 | `use_intra_process_comms` MUST NOT be set on a NITROS sidecar node. NITROS manages zero-copy transport internally; setting this flag introduces a volatile-durability conflict with the primary node. |


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

# 4b. Constraint C11 — run/deploy scripts self-read dockerargs via grep
grep -q "grep.*isaac_ros_dev-dockerargs" run_dev_<SUFFIX>.sh \
    || echo "VIOLATION C11: run_dev script does not self-read dockerargs"
grep -q "grep.*isaac_ros_dev-dockerargs" deploy_<SUFFIX>.sh \
    || echo "VIOLATION C11: deploy script does not self-read dockerargs"

# 4c. Constraint C12 — project-specific CACHED_LOCAL used in both scripts
grep -q 'CACHED_LOCAL=.*PROJECT_NAME' run_dev_<SUFFIX>.sh \
    || echo "VIOLATION C12: CACHED_LOCAL not defined in run_dev script"
grep -q 'CACHED_LOCAL=.*PROJECT_NAME' deploy_<SUFFIX>.sh \
    || echo "VIOLATION C12: CACHED_LOCAL not defined in deploy script"
# Global CACHED stamped just before activate (last docker tag before exec/activate)
grep -q 'docker tag.*CACHED_LOCAL.*CACHED[^_]' run_dev_<SUFFIX>.sh \
    || echo "VIOLATION C12: global tag stamp missing from run_dev script"
grep -q 'docker tag.*CACHED_LOCAL.*CACHED[^_]' deploy_<SUFFIX>.sh \
    || echo "VIOLATION C12: global tag stamp missing from deploy script"

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
