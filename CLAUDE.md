# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**IMPORTANT**: Keep this CLAUDE.md file up to date as the codebase evolves. When you add new features, change architecture, introduce new commands, or make other significant changes, update this file accordingly.

## Project Overview

This repository builds a containerized Kubelet with Docker runtime support via cri-dockerd. The system runs both kubelet and cri-dockerd together using concurrently, enabling standalone Kubernetes node functionality with Docker as the container runtime.

## Quick Start

```bash
docker compose up --build
```

This will:
1. Build kubelet v1.34.0 and cri-dockerd v0.3.21
2. Start both processes with concurrently
3. Connect kubelet to Docker on the host via cri-dockerd

## Build Arguments

The Dockerfile accepts these build arguments:

- `GO_VERSION_KUBE`: Go version for building Kubelet (default: 1.24)
- `KUBE_VERSION`: Kubernetes version to build (default: v1.34)
- `CONCURRENTLY_VERSION`: Concurrently version (default: 9.x)
- `CRI_DOCKERD_VERSION`: cri-dockerd version (default: v0.3.21)

Example with custom versions:

```bash
docker build --build-arg KUBE_VERSION=v1.35 --build-arg CRI_DOCKERD_VERSION=v0.3.22 -t kubelet .
```

## Architecture

### Multi-Stage Docker Build

The build uses multiple stages to compile all components:

1. **concurrently**: Pulls pre-built concurrently binary for process management
2. **kubectl**: Pulls official kubectl binary (same version as kubelet)
3. **builder-cri-dockerd**: Compiles cri-dockerd from source with `CGO_ENABLED=0`
4. **builder-kubelet**: Compiles kubelet from Kubernetes source with `CGO_ENABLED=0`
5. **combined**: Validation stage that tests all binaries
6. **Final Stage**: Alpine-based runtime with all binaries and wrapper scripts
   - ENTRYPOINT: `/concurrently -P cri-dockerd "kubelet {*}" --`
   - Supports passthrough arguments to kubelet via `{*}` placeholder
   - The `--` separator is in ENTRYPOINT, so CMD args go directly to kubelet

### Runtime Architecture

```
┌─────────────────────────────────────────────┐
│         Container (privileged)              │
│                                             │
│  ┌──────────────┐      ┌────────────────┐  │
│  │ concurrently │      │                │  │
│  └──────┬───────┘      │                │  │
│         │              │                │  │
│    ┌────┴────┐         │                │  │
│    │         │         │                │  │
│ ┌──▼──┐  ┌──▼──────┐  │  Docker Daemon │  │
│ │ cri │  │ kubelet │  │  (on host)     │  │
│ │dockerd◄─┤         │  │                │  │
│ └──┬──┘  └─────────┘  │                │  │
│    │                  │                │  │
│    └──────────────────┼───────────────►│  │
│   /var/run/docker.sock│                │  │
└────────────────────────┼────────────────┘  │
                         │                   │
                         └───────────────────┘
```

**Process Flow:**
1. `concurrently` starts both `cri-dockerd` and `kubelet` wrapper scripts
2. `cri-dockerd` connects to host Docker socket (`/var/run/docker.sock`)
3. `cri-dockerd` creates CRI socket at `/var/run/cri-dockerd.sock`
4. `kubelet` connects to cri-dockerd via the CRI socket
5. Pods are created as Docker containers on the host

### Docker Compose Configuration

The container requires elevated privileges to manage pods and cgroups:

- **privileged: true** - Required for cgroup management and container operations
- **network_mode: host** - Kubelet needs host network access
- **pid: host** - Required for proper process visibility

**Critical Volume Mounts:**
- `/var/run/docker.sock` - Host Docker socket (cri-dockerd connects here)
- `/var/lib/docker` - Docker data directory (required for container management)
- `/sys/fs/cgroup:rw` - Host cgroup filesystem (enables QoS cgroup management)
- `kubelet-data:/var/lib/kubelet` - Persistent kubelet state
- `static-pods:/etc/kubernetes/manifests` - Static pod manifests directory

## cri-dockerd Setup

Since Kubernetes v1.24 removed the built-in dockershim, cri-dockerd serves as an adapter between kubelet and Docker.

### Configuration

The cri-dockerd wrapper script (`/bin/cri-dockerd`) configures:

```bash
/cri-dockerd \
    --container-runtime-endpoint unix:///var/run/cri-dockerd.sock \
    --network-plugin=cni \
    --pod-infra-container-image=registry.k8s.io/pause:3.9
```

**Key Settings:**
- `--container-runtime-endpoint`: Where cri-dockerd creates its CRI socket
- `--network-plugin=cni`: Use CNI for pod networking
- `--pod-infra-container-image`: Pause container image for pod infrastructure

**Note:** cri-dockerd automatically connects to Docker via `/var/run/docker.sock` mounted from the host.

## Kubelet Configuration

The kubelet is configured via `/kubelet.yaml` (built from `config/dockerd.yml`).

### Configuration File: config/dockerd.yml

Uses `kubelet.config.k8s.io/v1beta1` API. The configuration contains only non-default settings for clarity.

**Container Runtime:**
```yaml
containerRuntimeEndpoint: unix:///var/run/cri-dockerd.sock
```

**Standalone Mode:**
- No API server connection
- Static pod support enabled (`/etc/kubernetes/manifests`)
- Anonymous authentication enabled
- AlwaysAllow authorization

**Non-Default Settings:**
- `failSwapOn: false` - Allows kubelet to run with swap enabled (default: true)
- `logging.verbosity: 2` - Increased log detail (default: 0)

**Default Settings (not in config):**
- Server ports: `10250` (API), `10255` (read-only), `10248` (health)
- Health endpoint: `127.0.0.1:10248` (localhost only)
- QoS cgroups: enabled by default
- cgroupDriver: `cgroupfs` (default)
- maxPods: `110` (default)
- Eviction thresholds: `memory.available=100Mi`, `nodefs.available=10%`, `nodefs.inodesFree=5%`, `imagefs.available=15%`

**Full config reference:** https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/

### Configuration Precedence

When multiple configuration sources are used:

1. Feature gates via command line (lowest)
2. KubeletConfiguration from `--config` file
3. Drop-in configs from `--config-dir` (sorted)
4. Command line arguments (highest)

**Key behavior**: Command line flags override config file values, allowing selective overrides while maintaining a base configuration.

### Wrapper Scripts

Located in `/bin/`:

- **kubelet**: Executes `/kubelet --config=/kubelet.yaml "$@"`
  - Accepts additional arguments via `"$@"` for runtime customization
- **cri-dockerd**: Executes `/cri-dockerd` with fixed runtime arguments
  - Does not accept passthrough arguments

These are managed by concurrently for automatic restart on failure.

### Passing Custom Arguments

The Dockerfile uses concurrently's passthrough arguments feature (`-P` flag) to allow kubelet-specific arguments.

**In docker-compose.yml:**
```yaml
services:
  kubelet:
    build: .
    command: ["--v=5", "--hostname-override=mynode"]
```

**How it works:**
1. ENTRYPOINT includes `--` separator: `/concurrently -P cri-dockerd "kubelet {*}" --`
2. Arguments in `command:` are passed only to kubelet via the `{*}` placeholder
3. The kubelet wrapper script receives these via `"$@"` and passes them to the kubelet binary

**Examples:**
- Increase verbosity: `command: ["--v=5"]`
- Set hostname: `command: ["--hostname-override=custom-node"]`
- Multiple flags: `command: ["--v=4", "--max-pods=200"]`

**Note:** cri-dockerd does not receive passthrough arguments since it has no `{*}` placeholder.
