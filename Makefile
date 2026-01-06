.PHONY: up clean

up:
	docker compose up --build

clean:
	docker compose down -v
	docker system prune -af --volumes
	docker builder prune -af
	sudo rm -rf /var/run/kubelet /var/run/cri-dockerd
	sudo ip link delete kubelet0 2>/dev/null || true
