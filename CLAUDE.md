# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**IMPORTANT**: Keep this CLAUDE.md file up to date as the codebase evolves. When you add new features, change architecture, introduce new commands, or make other significant changes, update this file accordingly.

## Project Overview

This repository builds a containerized Kubelet using minikube's kicbase image as the foundation. The system uses systemd to manage both kubelet and cri-dockerd services, with a self-contained Docker daemon for running pods. This provides a simpler, more maintainable architecture compared to custom Alpine-based builds.

## Quick Start

```bash
docker compose up --build
```

This will:
1. Build kubelet v1.34.0 and cri-dockerd v0.3.21
2. Layer them onto kicbase v0.0.47
3. Start the container with systemd managing all services
4. Automatically start kubelet and cri-dockerd services

## Build Arguments

The Dockerfile accepts these build arguments:

- `KICBASE_VERSION`: kicbase image version (default: v0.0.47)
- `KUBE_VERSION_GO`: Go version for building Kubelet (default: 1.24)
- `KUBE_VERSION`: Kubernetes version to build (default: v1.34)
- `CRI_DOCKERD_VERSION`: cri-dockerd version (default: v0.3.21)
- `CRI_DOCKERD_VERSION_GO`: Go version for building cri-dockerd (default: 1.24)

Example with custom versions:

```bash
docker build \
  --build-arg KUBE_VERSION=v1.35 \
  --build-arg CRI_DOCKERD_VERSION=v0.3.22 \
  --build-arg KICBASE_VERSION=v0.0.48 \
  -f Dockerfile.kicbase \
  -t kubelet-kicbase .
```

## Architecture

### Why kicbase?

The switch to kicbase simplifies the architecture significantly:

1. **Pre-configured systemd environment** - No need to set up init system from scratch
2. **Built-in Docker daemon** - Self-contained, no host Docker socket dependencies
3. **Minikube compatibility** - Uses the same base as minikube nodes
4. **Less custom configuration** - Leverages kicbase's existing setup for networking, storage, etc.

### Multi-Stage Docker Build

The build uses a simplified multi-stage approach:

1. **cri-dockerd builder**: Compiles cri-dockerd from source with `CGO_ENABLED=0`
   - Uses golang:${CRI_DOCKERD_VERSION_GO}-alpine
   - Clones Mirantis/cri-dockerd repository
   - Builds static binary with trimpath and stripped symbols

2. **kubelet builder**: Compiles kubelet from Kubernetes source with `CGO_ENABLED=0`
   - Uses golang:${KUBE_VERSION_GO}-alpine
   - Clones kubernetes/kubernetes repository
   - Builds only kubelet component (not entire k8s)
   - Uses `KUBE_STATIC_OVERRIDES=kubelet` for static linking

3. **Final stage**: Based on `gcr.io/k8s-minikube/kicbase:${KICBASE_VERSION}`
   - Copies compiled binaries from builder stages
   - Installs kubelet configuration
   - Installs systemd service files
   - Creates systemd service symlinks for auto-start
   - Sets entrypoint to systemd init

### Runtime Architecture

```
┌──────────────────────────────────────────────────────┐
│         kicbase Container (privileged)               │
│                                                      │
│  ┌────────────────────────────────────────────┐     │
│  │            systemd (PID 1)                 │     │
│  └─┬──────────────────────────────────────────┘     │
│    │                                                │
│    ├─▶ cri-docker.socket                            │
│    │   └─▶ cri-docker.service                       │
│    │       └─▶ /usr/bin/cri-dockerd                 │
│    │           (CRI socket: /run/cri-dockerd.sock)  │
│    │                    │                           │
│    │                    ▼                           │
│    │           ┌─────────────────┐                  │
│    │           │  dockerd        │                  │
│    │           │  (built-in)     │                  │
│    │           └─────────────────┘                  │
│    │                    ▲                           │
│    │                    │                           │
│    └─▶ kubelet.service  │                           │
│        └─▶ /bin/kubelet │                           │
│            (config: /kubelet.yaml)                  │
│            └───────────────                         │
│                                                      │
│  Volumes:                                           │
│  - /var (persistent)                                │
│  - /run (tmpfs)                                     │
│  - /tmp (tmpfs)                                     │
│  - /lib/modules (ro, from host)                     │
└──────────────────────────────────────────────────────┘
```

**Process Flow:**
1. Container starts with `/usr/local/bin/entrypoint /sbin/init`
2. systemd (PID 1) starts enabled services
3. `cri-docker.socket` creates socket at `/run/cri-dockerd.sock`
4. `cri-docker.service` starts when socket is accessed
5. `kubelet.service` starts and connects to CRI socket
6. Pods are created via cri-dockerd → dockerd chain

### Docker Compose Configuration

The container requires specific configuration for systemd and kicbase:

```yaml
services:
  kicbase:
    build:
      context: .
      dockerfile: ./Dockerfile.kicbase
    privileged: true                    # Required for systemd and cgroup management
    security_opt:
      - seccomp:unconfined              # Required for systemd
      - apparmor:unconfined             # Required for systemd
      - label:disable                   # Disable SELinux labeling
    volumes:
      - /lib/modules:/lib/modules:ro    # Kernel modules for networking
      - kicbase:/var                    # Persistent storage for Docker and kubelet
    tmpfs:
      - /run                            # systemd runtime directory (tmpfs required)
      - /tmp                            # Temporary files
    tty: true                           # Keep container running
```

**Critical Configuration:**
- **privileged: true** - Required for systemd to manage cgroups and for container operations
- **security_opt** - Disables security restrictions that would prevent systemd from functioning
- **tmpfs mounts** - systemd requires /run and /tmp on tmpfs
- **tty: true** - Keeps the container running (systemd needs this)

**Volume Mounts:**
- `/lib/modules` - Host kernel modules (read-only) for CNI plugins and networking features
- `kicbase:/var` - Single persistent volume containing all Docker and kubelet state
  - `/var/lib/docker` - Docker images and containers
  - `/var/lib/kubelet` - Kubelet state and pod data
  - All other service state under /var

## systemd Services

The container uses three systemd units to manage services:

### cri-docker.socket

Socket activation for cri-dockerd (preferred over always-running service):

```ini
[Socket]
ListenStream=%t/cri-dockerd.sock    # %t = /run
SocketMode=0660
SocketUser=root
SocketGroup=docker
```

Creates `/run/cri-dockerd.sock` on demand. When kubelet connects, systemd automatically starts cri-docker.service.

### cri-docker.service

Manages the cri-dockerd process:

```ini
[Service]
Type=notify
ExecStart=/usr/bin/cri-dockerd --container-runtime-endpoint fd://
Requires=cri-docker.socket
```

**Key settings:**
- `Type=notify` - Service sends readiness notification to systemd
- `--container-runtime-endpoint fd://` - Receives socket from systemd socket activation
- `Requires=cri-docker.socket` - Cannot run without the socket

**Note:** cri-dockerd automatically connects to Docker via the dockerd socket that kicbase provides.

### kubelet.service

Manages the kubelet process:

```ini
[Service]
ExecStart=kubelet --config=/kubelet.yaml --hostname-override=%H
Restart=always
RestartSec=600ms
```

**Key settings:**
- `--config=/kubelet.yaml` - Uses configuration file (see below)
- `--hostname-override=%H` - Sets node name to container hostname
- `RestartSec=600ms` - Fast restart on failure (tuned for local dev)

### Service Installation

The Dockerfile creates systemd symlinks to enable services on boot:

```dockerfile
RUN ln -sf /etc/systemd/system/cri-docker.service /etc/systemd/system/multi-user.target.wants/cri-docker.service && \
    ln -sf /etc/systemd/system/cri-docker.socket /etc/systemd/system/sockets.target.wants/cri-docker.socket && \
    ln -sf /etc/systemd/system/kubelet.service /etc/systemd/system/multi-user.target.wants/kubelet.service
```

This ensures all services start automatically when the container boots.

## Kubelet Configuration

The kubelet is configured via `/kubelet.yaml` (built from `kubelet.yaml/kicbase.yml`).

### Configuration File: kubelet.yaml/kicbase.yml

Uses `kubelet.config.k8s.io/v1beta1` API. The configuration is comprehensive and includes both custom and default values.

**Container Runtime:**
```yaml
containerRuntimeEndpoint: unix:///var/run/cri-dockerd.sock
```
Note: The socket path `/var/run/cri-dockerd.sock` is a symlink to `/run/cri-dockerd.sock` (standard Linux convention).

**Standalone Mode:**
- No API server connection (no cluster join)
- Static pod support enabled via `staticPodPath: /etc/kubernetes/manifests`
- Anonymous authentication enabled for local API access
- `authorization.mode: AlwaysAllow` - No authorization checks

**Key Settings:**
- `failSwapOn: false` - Allows kubelet to run with swap enabled
- `cgroupDriver: cgroupfs` - Uses cgroupfs (kicbase default)
- `hairpinMode: hairpin-veth` - Enables hairpin NAT for service IPs
- `clusterDNS: [10.96.0.10]` - Default cluster DNS IP
- `clusterDomain: cluster.local` - Default cluster domain

**API Endpoints:**
- Main API: `10250` (default, not in config)
- Read-only API: `10255` (default, not in config)
- Health endpoint: `127.0.0.1:10248` (via `healthzBindAddress` and `healthzPort`)

**Full config reference:** https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/

### Configuration Precedence

When multiple configuration sources are used:

1. Feature gates via command line (lowest)
2. KubeletConfiguration from `--config` file
3. Drop-in configs from `--config-dir` (sorted)
4. Command line arguments (highest)

**Key behavior**: Command line flags in kubelet.service override config file values.

## Static Pods

Static pods are defined in `/etc/kubernetes/manifests/`. The kubelet watches this directory and automatically creates/updates/deletes pods based on manifest files.

**Example:** `manifests/hello-world.yaml` defines a simple nginx pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hello-world
  namespace: default
spec:
  restartPolicy: Never
  containers:
    - name: nginx
      image: nginx
```

This pod will be automatically created when the kubelet starts. Add more YAML files to this directory to run additional static pods.

## Debugging and Management

Since the system uses systemd, standard systemd tools work for service management:

**Check service status:**
```bash
docker compose exec kicbase systemctl status kubelet
docker compose exec kicbase systemctl status cri-docker
```

**View service logs:**
```bash
docker compose exec kicbase journalctl -u kubelet -f
docker compose exec kicbase journalctl -u cri-docker -f
```

**Restart services:**
```bash
docker compose exec kicbase systemctl restart kubelet
docker compose exec kicbase systemctl restart cri-docker
```

**Check kubelet API:**
```bash
docker compose exec kicbase curl http://localhost:10248/healthz
```

## kicbase Details

kicbase is minikube's base image, providing:

- **OS**: Ubuntu-based (optimized for containers)
- **init system**: systemd
- **Container runtime**: dockerd (pre-installed and configured)
- **Networking**: CNI plugins pre-installed
- **Storage**: Multiple storage drivers supported
- **Kernel modules**: Common modules for container networking

The image is maintained by the minikube project and regularly updated for security and compatibility.

**Official repository:** https://github.com/kubernetes/minikube/tree/master/deploy/kicbase
