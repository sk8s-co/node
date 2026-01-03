#!/bin/bash
set -e

# Runtime filesystem setup - runs AFTER volume mounts are in place
echo "Setting up kubelet filesystem..."

# Create kubelet directory inside Docker's data directory
mkdir -p /var/lib/docker/kubelet

# Create symlink for compatibility if needed (optional)
if [ ! -L /var/lib/kubelet ]; then
    ln -sf /var/lib/docker/kubelet /var/lib/kubelet
fi

echo "Filesystem setup complete. Starting kicbase..."

# Execute the original kicbase entrypoint with all original arguments
exec /usr/local/bin/entrypoint "$@"
