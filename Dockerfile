ARG COMPONENT=kubelet-dockerd
ARG KUBE_VERSION=1.35
ARG KUBE_VERSION_GO=1.25
ARG KUBE_VERSION_PATCH=0
ARG CRI_DOCKERD_VERSION=0.3.21
ARG CRI_DOCKERD_VERSION_GO=1.24
ARG CRITOOLS_VERSION=1.33.0
ARG CRITOOLS_VERSION_GO=1.25
ARG CNI_VERSION=1.7.1
ARG CNI_VERSION_GO=1.23
ARG CLOUDFLARED_VERSION=2026.1.2
ARG CLOUDFLARED_VERSION_GO=1.24
ARG KUBELOGIN_VERSION=1.35.2
ARG KUBELOGIN_VERSION_GO=1.25

FROM installable/sh AS installable
FROM ghcr.io/scaffoldly/concurrently:9.x AS concurrently
FROM ghcr.io/sk8s-co/kubernetes:${KUBE_VERSION} AS kubernetes

FROM golang:${CRI_DOCKERD_VERSION_GO}-alpine AS cri-dockerd
ARG CRI_DOCKERD_VERSION
ENV CRI_DOCKERD_VERSION=${CRI_DOCKERD_VERSION}

RUN apk add --no-cache git build-base bash make
RUN --mount=type=cache,id=cri-${CRI_DOCKERD_VERSION},target=/go \
    # git clone https://github.com/Mirantis/cri-dockerd.git -b v${CRI_DOCKERD_VERSION} --depth=1 /cri && \
    git clone https://github.com/Mirantis/cri-dockerd.git -b master --depth=1 /cri && \
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

FROM golang:${CLOUDFLARED_VERSION_GO}-alpine AS cloudflared
ARG CLOUDFLARED_VERSION
RUN apk add --no-cache git make
RUN --mount=type=cache,id=cloudflared-${CLOUDFLARED_VERSION},target=/go \
    git clone https://github.com/cloudflare/cloudflared.git -b ${CLOUDFLARED_VERSION} --depth=1 /cloudflared
RUN cd /cloudflared && \
    CGO_ENABLED=0 make cloudflared

FROM golang:${KUBELOGIN_VERSION_GO}-alpine AS kubelogin
ARG KUBELOGIN_VERSION
RUN apk add --no-cache git make
RUN --mount=type=cache,id=kube-login-${KUBELOGIN_VERSION},target=/go \
    git clone https://github.com/int128/kubelogin.git -b v${KUBELOGIN_VERSION} --depth=1 /kubelogin && \
    cd /kubelogin && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /kubelogin/kubelogin .

FROM scratch AS scratched
COPY --from=installable / /
COPY --from=kubernetes /kubelet /usr/local/bin/kubelet
COPY --from=kubernetes /kube-controller-manager /usr/local/bin/kube-controller-manager
COPY --from=kubernetes /kube-scheduler /usr/local/bin/kube-scheduler
COPY --from=kubernetes /kubectl /usr/local/bin/kubectl
COPY --from=cri-dockerd /usr/local/bin/cri-dockerd /usr/local/bin/cri-dockerd
COPY --from=concurrently /concurrently /usr/local/bin/concurrently
COPY --from=cri-tools /cri-tools/bin/crictl /usr/local/bin/crictl
COPY --from=cni /cni/bin/* /opt/cni/bin/
COPY --from=cloudflared /cloudflared/cloudflared /usr/local/bin/cloudflared
COPY --from=kubelogin /kubelogin/kubelogin /usr/local/bin/kubectl-oidc_login
COPY manifests/* /etc/kubernetes/manifests/
COPY cni/* /etc/cni/net.d/
COPY cri/crictl.yaml /etc/crictl.yaml
COPY kubelet/* /etc/kubernetes/kubelet/

FROM alpine AS aplined
RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    docker-cli \
    conntrack-tools \
    iptables \
    jq
COPY --from=scratched / /

FROM alpine
ARG COMPONENT \
    KUBE_VERSION \
    CRI_DOCKERD_VERSION \
    CRITOOLS_VERSION \
    CNI_VERSION \
    KUBELOGIN_VERSION \
    CLOUDFLARED_VERSION \
    TARGETARCH \
    TARGETOS=linux

ENV USER_AGENT="${COMPONENT}/${KUBE_VERSION} (cri-dockerd/${CRI_DOCKERD_VERSION}; crictl/${CRITOOLS_VERSION}; cni/${CNI_VERSION}; kubelogin/${KUBELOGIN_VERSION}; cloudflared/${CLOUDFLARED_VERSION} alpine; ${TARGETOS}/${TARGETARCH})"
COPY --from=aplined / /
STOPSIGNAL SIGINT
ENTRYPOINT [ "RUN", "+env", "https://bootstrap.sk8s.net/kubelet.sh" ]
