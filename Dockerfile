FROM alpine:3.18
# v2.1.1 - force cache bust for install.sh fix
# Install dependencies
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
    echo "Dependencies installed successful"


COPY install.sh /install.sh
COPY globalvalues.yaml /globalvalues.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]


