FROM alpine:3.18

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
RUN ARCH=$(uname -m | sed 's/aarch64/arm64/' | sed 's/x86_64/amd64/') && \
    curl -sL "https://dl.k8s.io/release/v1.28.2/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

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


