.PHONY: up build run clean stop

IMAGE_NAME := sk8s-node
KUBE_APISERVER := https://7hukphd2sf3qyr7a6zkthmuiry0cxkcd.lambda-url.us-east-1.on.aws/

build:
	@echo "Building Docker image '$(IMAGE_NAME)'..."
	@docker build -t $(IMAGE_NAME) .

# run:
# 	@echo "Retrieving OIDC token and starting container (Ctrl+C to stop)..."
# 	@MACHINE_TOKEN=$$(kubectl oidc-login get-token \
# 		--oidc-use-access-token \
# 		--oidc-issuer-url=https://auth.sk8s.net/ \
# 		--oidc-client-id=CkbKDkUMWwmj4Ebi5GrO7X71LY57QRiU \
# 		--oidc-extra-scope=offline_access,system:masters \
# 		--oidc-auth-request-extra-params="audience=$(KUBE_APISERVER)" | jq -r '.status.token') && \
# 	trap 'CID=$$(docker ps -q --filter name=kubelet); [ -n "$$CID" ] && docker stop $$CID 2>/dev/null || true' INT TERM && \
# 	docker run --rm -it \
# 		--name kubelet \
# 		--hostname $$(hostname) \
# 		--privileged --network host --pid host --ipc host \
# 		-v /etc/machine-id:/etc/machine-id:ro \
# 		-v /var/run/kube:/var/run/kube \
# 		-v /var/run/docker.sock:/var/run/docker.sock \
# 		-v /var/lib/docker:/var/lib/docker \
# 		-v /sys/fs/cgroup:/sys/fs/cgroup \
# 		-e DEBUG=false \
# 		-e MACHINE_TOKEN="$$MACHINE_TOKEN" \
# 		$(IMAGE_NAME); \
# 	CID=$$(docker ps -q --filter name=kubelet); [ -n "$$CID" ] && docker stop $$CID 2>/dev/null || true

up: build
	@echo "Starting container (Ctrl+C to stop)..."
	@docker run --rm -it \
		--name kubelet \
		--hostname $$(hostname -s) \
		--privileged --network host --pid host --ipc host \
		-v /etc/machine-id:/etc/machine-id:ro \
		-v /var/run/kube:/var/run/kube \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v /var/lib/docker:/var/lib/docker \
		-v /sys/fs/cgroup:/sys/fs/cgroup \
		-v ${HOME}/.kube/cache/oidc-login:/root/.kube/cache/oidc-login:ro \
		-e MACHINE_TOKEN="$$(kubectl oidc-login get-token \
			--oidc-use-access-token \
			--oidc-issuer-url=https://auth.sk8s.net/ \
			--oidc-client-id=CkbKDkUMWwmj4Ebi5GrO7X71LY57QRiU \
			--oidc-extra-scope=offline_access,system:authenticated,system:masters,system:nodes \
			--oidc-auth-request-extra-params="audience=$(KUBE_APISERVER)" | jq -r '.status.token')" \
		-e DEBUG=false \
		$(IMAGE_NAME)

clean: stop
	@docker rmi $(IMAGE_NAME) 2>/dev/null || true
