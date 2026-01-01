ARG GO_VERSION_KUBE=1.24 \
    KUBE_VERSION=v1.34 \
    CONCURRENTLY_VERSION=9.x \
    CRI_DOCKERD_VERSION=v0.3.21

FROM scaffoldly/concurrently:${CONCURRENTLY_VERSION} AS concurrently
FROM registry.k8s.io/kubectl:${KUBE_VERSION}.0 AS kubectl

FROM golang:1.24-alpine AS builder-cri-dockerd
ARG CRI_DOCKERD_VERSION
ENV CRI_DOCKERD_VERSION=${CRI_DOCKERD_VERSION}
RUN apk add --no-cache git build-base bash make
RUN --mount=type=cache,target=/go-cri-dockerd \
    git clone https://github.com/Mirantis/cri-dockerd.git -b ${CRI_DOCKERD_VERSION} --depth=1 /cri-dockerd && \
    cd /cri-dockerd && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o cri-dockerd .

FROM golang:${GO_VERSION_KUBE}-alpine AS builder-kubelet
ARG GO_VERSION_KUBE
ARG KUBE_VERSION
ENV GO_VERSION_KUBE=${GO_VERSION_KUBE}
ENV KUBE_VERSION=${KUBE_VERSION}

RUN apk add --no-cache git make bash
RUN --mount=type=cache,target=/go-${GO_VERSION_KUBE} \
    git clone https://github.com/kubernetes/kubernetes.git -b ${KUBE_VERSION}.0 --depth=1 /kubernetes && \
    cd /kubernetes && \
    CGO_ENABLED=0 make all WHAT=cmd/kubelet KUBE_STATIC_OVERRIDES=kubelet && \
    mv /kubernetes/_output/local/go/bin/kubelet ./kubelet

FROM scratch AS combined
WORKDIR /combined
COPY --from=concurrently /concurrently .
COPY --from=kubectl /bin/kubectl .
COPY --from=builder-cri-dockerd /cri-dockerd/cri-dockerd .
COPY --from=builder-kubelet /kubernetes/kubelet .
COPY ./config/dockerd.yml ./kubelet.yaml

RUN ["/combined/concurrently", "--version"]
RUN ["/combined/kubectl", "version", "--client"]
RUN ["/combined/cri-dockerd", "--version"]
RUN ["/combined/kubelet", "--version"]

FROM alpine:latest
ENV CONCURRENTLY_RESTART_TRIES=-1 \
    CONCURRENTLY_RESTART_AFTER=1000 \
    CONCURRENTLY_NAMES=cri-dockerd,kubelet
COPY --from=combined /combined/ /
COPY ./bin /bin
EXPOSE 10250 10255 10248 
ENTRYPOINT [ "/concurrently", "-P", "cri-dockerd", "kubelet {*}", "--" ]
