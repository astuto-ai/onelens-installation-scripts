# Build kubectl and helm from their upstream release tags instead of downloading
# the published binaries. Every published kubectl and helm v3 release still bundles
# golang.org/x/net < v0.62.0, which customer image scanners report as HIGH. The
# only change from upstream is the module bump below; drop this stage once
# upstream releases ship it. Runs on the build host and cross-compiles, so the
# arm64 image does not compile under QEMU.
FROM --platform=$BUILDPLATFORM golang:1.26.11-alpine3.24 AS tools
RUN apk add --no-cache git make bash
ARG KUBECTL_VERSION=v1.35.10
ARG HELM_VERSION=v3.22.1
ARG GO_MOD_BUMPS="golang.org/x/net@v0.62.0"
ENV GOTOOLCHAIN=local CGO_ENABLED=0

RUN git clone -q --depth 1 --branch ${KUBECTL_VERSION} https://github.com/kubernetes/kubernetes.git /src/kubernetes && \
    cd /src/kubernetes && GOWORK=off go get ${GO_MOD_BUMPS}
RUN git clone -q --depth 1 --branch ${HELM_VERSION} https://github.com/helm/helm.git /src/helm && \
    cd /src/helm && go get ${GO_MOD_BUMPS}

ARG TARGETOS TARGETARCH
# Same version ldflags as kubernetes' hack/lib/version.sh, so `kubectl version`
# and image scanners still identify the binary as the upstream release.
RUN cd /src/kubernetes && \
    MINOR=$(echo ${KUBECTL_VERSION} | cut -d. -f2) && \
    LDFLAGS="-s -w" && \
    for p in k8s.io/client-go/pkg/version k8s.io/component-base/version; do \
      LDFLAGS="$LDFLAGS -X $p.gitVersion=${KUBECTL_VERSION} -X $p.gitMajor=1 -X $p.gitMinor=${MINOR}"; \
      LDFLAGS="$LDFLAGS -X $p.gitCommit=$(git rev-parse HEAD) -X $p.gitTreeState=dirty -X $p.buildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
    done && \
    GOWORK=off GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -mod=mod -trimpath -ldflags "$LDFLAGS" -o /out/kubectl ./cmd/kubectl
RUN cd /src/helm && \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} make build VERSION=${HELM_VERSION} BINDIR=/out

FROM alpine:3.22

# Install dependencies (this layer is cached across builds).
# apk upgrade pulls security fixes for packages the base image
# already ships (e.g. OpenSSL); apk add alone leaves them as-is.
RUN apk update && apk upgrade --no-cache && apk add --no-cache \
    curl \
    tar \
    gzip \
    bash \
    git \
    unzip \
    wget \
    jq \
    python3 \
    py3-pip \
    aws-cli && \
    echo "Dependencies installed successfully"

# kubectl for healthcheck mode (entrypoint.sh needs it before patching.sh runs), and
# Helm. Both are also available at runtime so install.sh skips the download in
# airgapped environments.
COPY --from=tools /out/kubectl /out/helm /usr/local/bin/
RUN kubectl version --client && helm version

# Bundle the onelens-agent Helm chart for airgapped environments.
# In airgapped mode, install.sh and patching.sh use this local chart
# instead of pulling from a Helm repo or OCI registry.
# Packaged from local source (charts/onelens-agent/) — no network dependency.
COPY charts/onelens-agent /tmp/onelens-agent-src
RUN mkdir -p /charts && \
    helm package /tmp/onelens-agent-src -d /charts/ && \
    rm -rf /tmp/onelens-agent-src

# CACHE_BUST changes on every CI build (set to git SHA), ensuring
# install.sh and other scripts are never served from stale Docker cache.
ARG CACHE_BUST=unknown
RUN echo "Build: $CACHE_BUST"

COPY install.sh /install.sh
COPY lib/ /lib/
COPY globalvalues.yaml /globalvalues.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]


