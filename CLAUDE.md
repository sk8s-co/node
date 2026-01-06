# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This project implements a kubelet that runs inside Docker using a Docker-out-of-Docker (DooD) architecture. The kubelet container shares the host's Docker socket and manages containers on the host Docker daemon rather than running its own nested Docker environment.

## Architecture

### Core Components

1. **Kubelet**: Built from Kubernetes source (configurable version, default 1.34.0) with a critical patch applied
   - Patched to disable `/etc/hosts` management to avoid overlayfs conflicts in DooD environments
   - Patch location: `patches/kubelet-disable-etc-hosts.patch`
   - Configuration: `standalone.yaml` (KubeletConfiguration)

2. **CRI-Dockerd**: Container Runtime Interface adapter for Docker (v0.3.21)
   - Bridges kubelet to Docker daemon via `/var/run/cri-dockerd.sock`
   - Configured with `--network-plugin=` (disabled)

3. **CNI Plugins**: Container Network Interface plugins (v1.7.1)
   - Bridge plugin configured with subnet `10.244.0.0/16`
   - Configuration: `cni/10-bridge.conf`

### Process Management

Uses `concurrently` to run both `cri-dockerd` and `kubelet` processes simultaneously with automatic restart on failure (infinite retries with 1000ms delay).

### Docker-out-of-Docker (DooD) Setup

Key architectural decisions:
- Container runs in privileged mode
- Mounts host's `/var/run/docker.sock` and `/var/lib/docker`
- Kubelet patch disables `/etc/hosts` management (critical for DooD)
- Static pod path: `/etc/kubernetes/manifests/`

### Kubelet Configuration Highlights

(`standalone.yaml`)
- **Container Runtime**: Unix socket at `/var/run/cri-dockerd.sock`
- **Authentication**: Anonymous enabled, webhook disabled
- **Authorization**: AlwaysAllow (permissive standalone mode)
- **Resource Enforcement**: Disabled (`cgroupsPerQOS: false`, `enforceNodeAllocatable: []`)
- **Swap**: Allowed (`failSwapOn: false`)

## Build Commands

### Build the Docker Image
```bash
docker compose build kubelet
```

### Build with Custom Versions
```bash
docker build \
  --build-arg KUBE_VERSION=1.34 \
  --build-arg KUBE_VERSION_GO=1.24 \
  --build-arg KUBE_VERSION_PATCH=0 \
  --build-arg CRI_DOCKERD_VERSION=0.3.21 \
  --build-arg CNI_VERSION=1.7.1 \
  -t kubelet .
```

## Running

### Using Docker Compose
```bash
docker compose up kubelet
```

### Manual Docker Run
```bash
docker run --privileged \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/lib/docker:/var/lib/docker \
  kubelet
```

## Multi-Stage Build Structure

The Dockerfile uses a complex multi-stage build:

1. **builder**: Base Alpine Go image, clones Kubernetes source
2. **kubelet**: Applies DooD patch, builds kubelet binary with caching
3. **cri-dockerd**: Builds CRI-Dockerd from source
4. **cni**: Builds CNI plugins from source
5. **reduced**: Scratch image collecting all binaries
6. **Final**: Alpine with runtime dependencies (bash, ca-certificates, iptables, conntrack-tools)

All Go builds use `CGO_ENABLED=0` for static binaries and leverage Docker layer caching via `--mount=type=cache`.

## Static Pods

Pods defined in `/etc/kubernetes/manifests/` are automatically started by kubelet.

Example static pod: `manifests/hello-world.yaml` (nginx with hostNetwork)

## Critical Patch Details

The `kubelet-disable-etc-hosts.patch` modifies `pkg/kubelet/kubelet_pods.go` to force `shouldMountHostsFile()` to always return `false`. This prevents kubelet from attempting to manage `/etc/hosts` in containers, which causes overlayfs conflicts when running in a DooD environment where the kubelet itself is containerized.

## CI/CD

GitHub Actions workflow (`.github/workflows/main.yml`) builds multi-architecture images (amd64/arm64) and pushes to GitHub Container Registry on main branch:
- Uses matrix strategy for version combinations
- References `Dockerfile.kicbase` (not present in current directory listing)
- Tags: `<kube-version>` (main branch only) and `<kube-version>-<sha>`
