# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This project implements a kubelet that runs inside Docker using a Docker-out-of-Docker (DooD) architecture. The kubelet container shares the host's Docker socket and manages containers on the host Docker daemon rather than running its own nested Docker environment.

## Architecture

### Core Components

1. **Kubelet**: Built from Kubernetes source (configurable version, default 1.34.0)
   - Configuration: `standalone.yaml` (KubeletConfiguration)
   - Runs with full host permissions as a system daemon

2. **CRI-Dockerd**: Container Runtime Interface adapter for Docker (v0.3.21)
   - Bridges kubelet to Docker daemon via `/var/run/cri-dockerd.sock`
   - Configured with `--network-plugin=` (disabled, uses host networking)
   - Root directory: `/var/run/cri-dockerd` (stores pod sandbox checkpoints)

### Process Management

Uses `concurrently` to run both `cri-dockerd` and `kubelet` processes simultaneously with automatic restart on failure (infinite retries with 1000ms delay).

### Docker-out-of-Docker (DooD) Setup

Key architectural decisions:
- Container runs with **full host-level permissions** (root-like daemon mode):
  - `privileged: true` - All Linux capabilities + device access
  - `network_mode: host` - Shares host network namespace
  - `pid: host` - Shares host PID namespace (can see all host processes)
  - `ipc: host` - Shares host IPC namespace (shared memory, semaphores)
  - `uts: host` - Shares host UTS namespace (hostname)
- Mounts host's `/var/run/docker.sock` and `/var/lib/docker`
- Mounts host's `/sys/fs/cgroup` (read-write) for creating cgroup hierarchies and setting resource limits
- All kubelet/cri-dockerd ephemeral data stored in `/var/run` (durable between restarts via volume mounts)
- Static pod path: `/etc/kubernetes/manifests/`

### Kubelet Configuration Highlights

(`standalone.yaml`)
- **Container Runtime**: Unix socket at `/var/run/cri-dockerd.sock`
- **Root Directory**: `/var/run/kubelet` (ephemeral data, durable via volume mount)
- **Certificate Directory**: `/var/run/kubelet/pki` (TLS certs)
- **Authentication**: Anonymous enabled, webhook disabled
- **Authorization**: AlwaysAllow (permissive standalone mode)
- **Resource Enforcement**: Disabled (`cgroupsPerQOS: false`, `enforceNodeAllocatable: []`, `localStorageCapacityIsolation: false`)
- **Eviction**: Disabled (`evictionHard: {}`, prevents filesystem inspection errors in containerized environment)
- **Image GC**: Disabled (`imageGCHighThresholdPercent: 100`)
- **Swap**: Allowed (`failSwapOn: false`)

## Build Commands

### Build with Default Versions
```bash
make up  # Builds automatically
# or
docker compose build
```

### Build with Custom Versions
```bash
docker build \
  --build-arg KUBE_VERSION=1.34 \
  --build-arg KUBE_VERSION_GO=1.24 \
  --build-arg KUBE_VERSION_PATCH=0 \
  --build-arg CRI_DOCKERD_VERSION=0.3.21 \
  -t kubelet .
```

## Running

### Using Makefile
```bash
make up    # Build and start kubelet container
make clean # Stop kubelet container
```

### Using Docker Compose
```bash
docker compose up --build
```

### Manual Docker Run
```bash
docker run --privileged \
  --network host \
  --pid host \
  --ipc host \
  --uts host \
  -v /var/run/kubelet:/var/run/kubelet \
  -v /var/run/cri-dockerd:/var/run/cri-dockerd \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/lib/docker:/var/lib/docker \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  kubelet
```

## Multi-Stage Build Structure

The Dockerfile uses a multi-stage build:

1. **builder**: Base Alpine Go image, clones Kubernetes source
2. **kubelet**: Builds kubelet binary with caching
3. **cri-dockerd**: Builds CRI-Dockerd from source
4. **reduced**: Scratch image collecting all binaries
5. **Final**: Alpine with runtime dependencies (bash, ca-certificates, iptables, conntrack-tools)

All Go builds use `CGO_ENABLED=0` for static binaries and leverage Docker layer caching via `--mount=type=cache`.

## Data Persistence

All ephemeral kubelet/cri-dockerd data is stored in `/var/run` on the Docker VM host:
- `/var/run/kubelet` - Kubelet state, pod logs, TLS certificates
- `/var/run/cri-dockerd` - Pod sandbox checkpoints

These directories persist across container restarts via volume mounts but are ephemeral at the VM level (cleared on Docker Desktop VM restart).

## Static Pods

Pods defined in `/etc/kubernetes/manifests/` are automatically started by kubelet.

Example static pod: `manifests/hello-world.yaml` (nginx with hostNetwork)

## CI/CD

GitHub Actions workflow (`.github/workflows/main.yml`) builds multi-architecture images (amd64/arm64) and pushes to GitHub Container Registry on main branch:
- Uses matrix strategy for version combinations
- References `Dockerfile.kicbase` (not present in current directory listing)
- Tags: `<kube-version>` (main branch only) and `<kube-version>-<sha>`
