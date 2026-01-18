ARG COMPONENT=dockerd-kubelet
ARG KUBE_VERSION=1.34
ARG KUBE_VERSION_GO=1.24
ARG KUBE_VERSION_PATCH=0
ARG CRI_DOCKERD_VERSION=0.3.21
ARG CRI_DOCKERD_VERSION_GO=1.24
ARG CRITOOLS_VERSION=1.33.0
ARG CRITOOLS_VERSION_GO=1.25
ARG CNI_VERSION=1.7.1
ARG CNI_VERSION_GO=1.23
ARG KUBELOGIN_VERSION=1.35.2
ARG KUBELOGIN_VERSION_GO=1.25

FROM ghcr.io/scaffoldly/concurrently:9.x AS concurrently
FROM ghcr.io/sk8s-co/kubernetes:${KUBE_VERSION} AS kubernetes

FROM golang:${CRI_DOCKERD_VERSION_GO}-alpine AS cri-dockerd
ARG CRI_DOCKERD_VERSION
ENV CRI_DOCKERD_VERSION=${CRI_DOCKERD_VERSION}

RUN apk add --no-cache git build-base bash make
RUN --mount=type=cache,id=cri-${CRI_DOCKERD_VERSION},target=/go \
    # git clone https://github.com/Mirantis/cri-dockerd.git -b v${CRI_DOCKERD_VERSION} --depth=1 /cri && \
    git clone https://github.com/cnuss/cri-dockerd.git -b issues/532 --depth=1 /cri && \
    cd /cri && \
    # Override "podsandbox" constant to avoid Docker Desktop API filtering \
    # Docker Desktop filters containers with io.kubernetes.docker.type="podsandbox" \
    # Using "sandboxpod" makes pause containers visible in docker ps and crictl pods \
    sed -i 's/containerTypeLabelSandbox[[:space:]]*=[[:space:]]*"podsandbox"/containerTypeLabelSandbox = "sandboxpod"/' core/docker_service.go && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /usr/local/bin/cri-dockerd .

FROM golang:${CRITOOLS_VERSION_GO}-alpine AS cri-tools
ARG CRITOOLS_VERSION
RUN apk add --no-cache git make gcc musl-dev gpgme-dev pkgconfig bash btrfs-progs-dev
RUN --mount=type=cache,id=cri-tools-${CRITOOLS_VERSION},target=/go \
    git clone https://github.com/kubernetes-sigs/cri-tools.git -b v${CRITOOLS_VERSION} --depth=1 /cri-tools && \
    cd /cri-tools && \
    CGO_ENABLED=0 make binaries BUILD_PATH=/cri-tools GOOS="" GOARCH=""

FROM golang:${CNI_VERSION_GO}-alpine AS cni
ARG CNI_VERSION
RUN apk add --no-cache git make
RUN --mount=type=cache,id=cni-${CNI_VERSION},target=/go \
    git clone https://github.com/containernetworking/plugins.git -b v${CNI_VERSION} --depth=1 /cni && \
    cd /cni && \
    CGO_ENABLED=0 ./build_linux.sh -ldflags '-extldflags -static -X github.com/containernetworking/plugins/pkg/utils/buildversion.BuildVersion=${CNI_VERSION}'

FROM golang:${KUBELOGIN_VERSION_GO}-alpine AS kubelogin
ARG KUBELOGIN_VERSION
RUN apk add --no-cache git make
RUN --mount=type=cache,id=kube-login-${KUBELOGIN_VERSION},target=/go \
    git clone https://github.com/int128/kubelogin.git -b v${KUBELOGIN_VERSION} --depth=1 /kubelogin && \
    cd /kubelogin && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /kubelogin/kubelogin .

FROM golang:1.25-alpine AS kash
COPY go.mod go.sum /kash/
COPY cmd/kash/ /kash/cmd/kash/
RUN apk add --no-cache git
RUN --mount=type=cache,id=kash-mod-cache,target=/go/pkg/mod \
    cd /kash && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /kash/kash ./cmd/kash

FROM scratch AS reduced
COPY --from=kubernetes /kubelet /srv/kubelet
COPY --from=kubernetes /kubectl /usr/local/bin/kubectl
COPY --from=cri-dockerd /usr/local/bin/cri-dockerd /srv/cri-dockerd
COPY --from=concurrently /concurrently /srv/concurrently
COPY --from=cri-tools /cri-tools/bin/crictl /bin/crictl
COPY --from=cni /cni/bin/* /opt/cni/bin/
COPY --from=kubelogin /kubelogin/kubelogin /usr/local/bin/kubectl-oidc_login
COPY --from=kash /kash/kash /usr/local/bin/kash
COPY bin/* /bin/
COPY manifests/* /etc/kubernetes/manifests/
COPY cni/* /etc/cni/net.d/
COPY cri/crictl.yaml /etc/crictl.yaml
COPY kubelet/* /etc/kubernetes/kubelet/

FROM alpine
ARG COMPONENT \
    KUBE_VERSION \
    CRI_DOCKERD_VERSION \
    CRITOOLS_VERSION \
    CNI_VERSION \
    KUBELOGIN_VERSION \
    TARGETARCH \
    TARGETOS=linux

RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    docker-cli \
    conntrack-tools \
    iptables \
    jq

ENV USER_AGENT="${COMPONENT}/${KUBE_VERSION} (cri-dockerd/${CRI_DOCKERD_VERSION}; crictl/${CRITOOLS_VERSION}; cni/${CNI_VERSION}; kubelogin/${KUBELOGIN_VERSION}; alpine; ${TARGETOS}/${TARGETARCH})" \
    OIDC_ISS=https://auth.sk8s.net/ \
    OIDC_AUD=https://sk8s-co.us.auth0.com/userinfo \
    OIDC_AZP=CkbKDkUMWwmj4Ebi5GrO7X71LY57QRiU \
    OIDC_SCP=offline_access

COPY --from=reduced / /
ENTRYPOINT [ "start" ]
