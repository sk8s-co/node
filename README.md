# node

A containerized Kubelet based on minikube's kicbase image, with systemd-managed services and self-contained Docker runtime.

## Quick Start

```bash
docker compose up --build
```

This starts a standalone kubelet (v1.34.0) with cri-dockerd inside a systemd-managed container.

## What's Included

- **kicbase v0.0.47** - Minikube's base image with Docker and systemd pre-configured
- **Kubelet v1.34.0** - Compiled from Kubernetes source
- **cri-dockerd v0.3.21** - Docker CRI adapter (replaces removed dockershim)
- **systemd** - Service manager for kubelet and cri-dockerd

## Architecture

The container uses minikube's kicbase image as the foundation, providing a complete systemd environment with Docker runtime. Both kubelet and cri-dockerd run as systemd services managed by the init system.

```
┌─────────────────────────────────────┐
│    kicbase Container (systemd)      │
│                                     │
│  ┌──────────┐      ┌──────────┐    │
│  │ kubelet  │─────▶│cri-dockerd│   │
│  │ (service)│      │ (service) │   │
│  └──────────┘      └─────┬─────┘   │
│                          │         │
│                    ┌─────▼─────┐   │
│                    │  dockerd  │   │
│                    │(built-in) │   │
│                    └───────────┘   │
└─────────────────────────────────────┘
```

See [CLAUDE.md](./CLAUDE.md) for detailed architecture documentation.

## Configuration

- **Kubelet config**: `kubelet.yaml/kicbase.yml` (mounted as `/kubelet.yaml`)
- **API Endpoints**:
  - `10250` - Kubelet API (read/write)
  - `10255` - Read-only API
  - `10248` - Health endpoint (localhost only)
- **Static Pods**: Place manifests in `/etc/kubernetes/manifests` (see `manifests/hello-world.yaml` for example)

## Requirements

- Docker with systemd support
- Privileged container mode (required for systemd and cgroup management)

## Documentation

See [CLAUDE.md](./CLAUDE.md) for:
- Detailed architecture and build process
- Systemd service configuration
- cri-dockerd setup details
- Kubelet configuration reference
- Build arguments and customization
