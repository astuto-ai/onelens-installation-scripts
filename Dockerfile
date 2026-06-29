FROM alpine:3.22

# Install dependencies (this layer is cached across builds)
RUN apk update && apk add --no-cache \
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

# Install kubectl for healthcheck mode (entrypoint.sh needs it before patching.sh runs)
# Also available at runtime so install.sh skips the download in airgapped environments.
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/' | sed 's/x86_64/amd64/') && \
    curl -sL "https://dl.k8s.io/release/v1.28.2/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

# Install Helm so install.sh skips the download in airgapped environments.
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/' | sed 's/x86_64/amd64/') && \
    curl -fsSL "https://get.helm.sh/helm-v3.13.2-linux-${ARCH}.tar.gz" -o /tmp/helm.tar.gz && \
    tar -xzvf /tmp/helm.tar.gz -C /tmp && \
    mv /tmp/linux-${ARCH}/helm /usr/local/bin/helm && \
    rm -rf /tmp/linux-${ARCH} /tmp/helm.tar.gz

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


