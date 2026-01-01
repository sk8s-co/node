# node

A containerized Kubelet with Docker runtime support via cri-dockerd, designed for Serverless Kubernetes environments.

## Quick Start

```bash
docker compose up --build
```

This starts a standalone kubelet (v1.34.0) that connects to Docker on the host via cri-dockerd.

## What's Included

- **Kubelet v1.34.0** - Compiled from Kubernetes source
- **cri-dockerd v0.3.21** - Docker CRI adapter (replaces removed dockershim)
- **kubectl v1.34.0** - Kubernetes CLI (same version as kubelet)
- **concurrently** - Process manager for running kubelet + cri-dockerd together

## Architecture

The container runs both kubelet and cri-dockerd using concurrently. The cri-dockerd process connects to the host's Docker daemon and provides a CRI interface for kubelet to communicate with.

```
kubelet → cri-dockerd → /var/run/docker.sock → Docker (host)
```

See [CLAUDE.md](./CLAUDE.md) for detailed architecture documentation.

## Configuration

- **Kubelet config**: `config/dockerd.yml` (mounted as `/kubelet.yaml`)
  - Only contains non-default settings for clarity
- **API Endpoints**:
  - `10250` - Kubelet API (read/write)
  - `10255` - Read-only API
  - `10248` - Health endpoint
- **Static Pods**: Place manifests in the `static-pods` volume (mounted at `/etc/kubernetes/manifests`)

### Passing Custom Arguments

You can pass additional arguments to kubelet via docker-compose:

```yaml
services:
  kubelet:
    build: .
    command: ["--v=5", "--hostname-override=mynode"]
```

Arguments in `command` are passed only to kubelet (not cri-dockerd).

## Requirements

- Docker with cgroup v2 support
- Host must have `/sys/fs/cgroup` available for QoS management

## Documentation

See [CLAUDE.md](./CLAUDE.md) for:
- Detailed architecture diagrams
- Build configuration options
- cri-dockerd setup details
- Kubelet configuration reference
- Volume mount explanations
