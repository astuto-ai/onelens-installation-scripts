# kube-state-metrics built from its upstream release tag with patched Go modules and
# Go toolchain, because the published image fails HIGH/CRITICAL image scans. The only
# change from upstream is go-mod-bump.sh. Same binary, user and entrypoint as
# registry.k8s.io/kube-state-metrics/kube-state-metrics.
FROM --platform=$BUILDPLATFORM golang:1.26.11-alpine3.24 AS build
RUN apk add --no-cache git make bash coreutils
ENV GOTOOLCHAIN=local CGO_ENABLED=0
ARG VERSION
RUN test -n "${VERSION}" && \
    git clone -q --depth 1 --branch v${VERSION} https://github.com/kubernetes/kube-state-metrics.git /src
WORKDIR /src
COPY go-mod-bump.sh /usr/local/bin/go-mod-bump.sh
RUN sh /usr/local/bin/go-mod-bump.sh
ARG TARGETOS TARGETARCH
# Upstream's own build target, so the version ldflags match the published binary.
RUN GOFLAGS=-mod=mod make build-local OS=${TARGETOS} ARCH=${TARGETARCH} && \
    mkdir -p /out && mv kube-state-metrics /out/

FROM gcr.io/distroless/static-debian13:latest
LABEL org.opencontainers.image.source="https://github.com/astuto-ai/onelens-installation-scripts"
COPY --from=build /out/kube-state-metrics /
USER nobody
ENTRYPOINT ["/kube-state-metrics", "--port=8080", "--telemetry-port=8081"]
EXPOSE 8080 8081
