.PHONY: up build run clean stop

IMAGE_NAME := sk8s-node

build:
	docker build -t $(IMAGE_NAME) .

run:
	@echo "Starting container (Ctrl+C to stop)..."
	@trap 'CID=$$(docker ps -q --filter name=kubelet); [ -n "$$CID" ] && docker stop $$CID 2>/dev/null || true' INT TERM; \
	docker run --rm -it \
		--name kubelet \
		--hostname $$(hostname) \
		--privileged --network host --pid host --ipc host \
		-v /etc/machine-id:/etc/machine-id:ro \
		-v /var/run/kube:/var/run/kube \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v /var/lib/docker:/var/lib/docker \
		-v /sys/fs/cgroup:/sys/fs/cgroup \
		-e DEBUG=true \
		$(IMAGE_NAME); \
	CID=$$(docker ps -q --filter name=kubelet); [ -n "$$CID" ] && docker stop $$CID 2>/dev/null || true

up: build run

stop:
	@CID=$$(docker ps -q --filter name=kubelet); [ -n "$$CID" ] && docker stop $$CID 2>/dev/null || true

clean: stop
	@docker rmi $(IMAGE_NAME) 2>/dev/null || true
