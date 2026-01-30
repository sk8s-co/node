.PHONY: up build run clean stop

IMAGE_NAME := sk8s-node
KUBE_APISERVER := https://t37c7hhjiezge45fnf2lpsikzy0enaic.lambda-url.us-east-1.on.aws/

build:
	@echo "Building Docker image '$(IMAGE_NAME)'..."
	@docker build --pull -t $(IMAGE_NAME) .

up: build
	@set -e
	@echo "Logging via OIDC..."
	@kubectl oidc-login get-token \
		--oidc-issuer-url=https://auth.sk8s.net/ \
		--oidc-client-id=CkbKDkUMWwmj4Ebi5GrO7X71LY57QRiU \
		--oidc-extra-scope=offline_access,system:authenticated,system:masters,system:nodes \
		--oidc-auth-request-extra-params="audience=$(KUBE_APISERVER)" > /dev/null
	@echo "Starting kubelet container..."
	@docker run --rm -it \
		--name kubelet \
		--hostname $$(hostname -s) \
		--privileged --network host --pid host --ipc host \
		-v /etc/machine-id:/etc/machine-id:ro \
		-v /var/run/kube:/var/run/kube \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v /var/lib/docker:/var/lib/docker \
		-v /sys/fs/cgroup:/sys/fs/cgroup \
		-v ${HOME}/.kube/cache:/root/.kube/cache \
		-e OIDC_AUD="$(KUBE_APISERVER)" \
		-e DEBUG=false \
		$(IMAGE_NAME)

clean: stop
	@docker rmi $(IMAGE_NAME) 2>/dev/null || true
