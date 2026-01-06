ARG KUBE_VERSION=1.34
ARG KUBE_VERSION_GO=1.24
ARG KUBE_VERSION_PATCH=0
ARG CRI_DOCKERD_VERSION=0.3.21
ARG CRI_DOCKERD_VERSION_GO=1.24
ARG CRITOOLS_VERSION=1.33.0
ARG CRITOOLS_VERSION_GO=1.25
ARG CNI_VERSION=1.7.1
ARG CNI_VERSION_GO=1.23

# FROM ghcr.io/sk8s-co/kubernetes:${KUBE_VERSION} AS kubernetes
FROM ghcr.io/scaffoldly/concurrently:9.x AS concurrently

FROM golang:${KUBE_VERSION_GO}-alpine AS builder
ARG KUBE_VERSION \
    KUBE_VERSION_PATCH
ENV KUBE_VERSION=${KUBE_VERSION} \
    KUBE_VERSION_PATCH=${KUBE_VERSION_PATCH}
RUN apk add --no-cache git make bash
RUN git clone https://github.com/kubernetes/kubernetes.git -b v${KUBE_VERSION}.${KUBE_VERSION_PATCH} --depth=1 /kubernetes
WORKDIR /kubernetes

FROM builder AS kubelet
ARG KUBE_VERSION
ENV KUBE_VERSION=${KUBE_VERSION}

# Patch kubelet for DooD compatibility
# COPY patches /patches
# RUN cd /kubernetes && git apply /patches/kubelet-disable-etc-hosts.patch

RUN --mount=type=cache,id=kubelet-${KUBE_VERSION},target=/go \
    CGO_ENABLED=0 make all WHAT=cmd/kubelet KUBE_STATIC_OVERRIDES=kubelet && \
    mv /kubernetes/_output/local/go/bin/kubelet /usr/local/bin/kubelet

FROM golang:${CRI_DOCKERD_VERSION_GO}-alpine AS cri-dockerd
ARG CRI_DOCKERD_VERSION
ENV CRI_DOCKERD_VERSION=${CRI_DOCKERD_VERSION}

RUN apk add --no-cache git build-base bash make
RUN --mount=type=cache,id=cri-${CRI_DOCKERD_VERSION},target=/go \
    git clone https://github.com/Mirantis/cri-dockerd.git -b v${CRI_DOCKERD_VERSION} --depth=1 /cri && \
    cd /cri && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /usr/local/bin/cri-dockerd .

FROM golang:${CRITOOLS_VERSION_GO}-alpine AS cri-tools
ARG CRITOOLS_VERSION
RUN apk add --no-cache git make gcc musl-dev gpgme-dev pkgconfig bash btrfs-progs-dev
RUN --mount=type=cache,id=cri-tools-${CRITOOLS_VERSION},target=/go \
    git clone https://github.com/kubernetes-sigs/cri-tools.git -b v${CRITOOLS_VERSION} --depth=1 /cri-tools && \
    cd /cri-tools && \
    CGO_ENABLED=0 make binaries BUILD_PATH=/cri-tools GOOS="" GOARCH=""

FROM golang:${CNI_VERSION_GO}-alpine AS builder-cni
ARG CNI_VERSION
RUN apk add --no-cache git make
RUN --mount=type=cache,id=cni-${CNI_VERSION},target=/go \
    git clone https://github.com/containernetworking/plugins.git -b v${CNI_VERSION} --depth=1 /cni && \
    cd /cni && \
    CGO_ENABLED=0 ./build_linux.sh -ldflags '-extldflags -static -X github.com/containernetworking/plugins/pkg/utils/buildversion.BuildVersion=${CNI_VERSION}'

FROM scratch AS reduced

# COPY --from=kubernetes /kubelet /srv/kubelet
COPY --from=kubelet /usr/local/bin/kubelet /srv/kubelet
COPY --from=cri-dockerd /usr/local/bin/cri-dockerd /srv/cri-dockerd
COPY --from=cri-tools /cri-tools/bin/crictl /bin/crictl
COPY --from=builder-cni /cni/bin/ /opt/cni/bin/
COPY --from=concurrently /concurrently /bin/concurrently
COPY bin/* /bin/
COPY manifests /etc/kubernetes/manifests
COPY standalone.yaml /etc/kubernetes/kubelet.yaml
COPY cni /etc/cni/net.d
COPY cri/crictl.yaml /etc/crictl.yaml

FROM alpine
RUN apk add --no-cache bash ca-certificates iptables conntrack-tools
COPY --from=reduced / /
ENV CONCURRENTLY_NAMES=cri-dockerd \
    CONCURRENTLY_KILL_OTHERS=true \
    CONCURRENTLY_KILL_SIGNAL=SIGINT

# ENTRYPOINT ["concurrently", "-P", "kubelet {*}", "cri-dockerd"]
ENTRYPOINT ["concurrently", "-P", "cri-dockerd"]
