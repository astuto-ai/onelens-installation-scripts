# OpenCost built from its upstream release tag with patched Go modules and Go
# toolchain, because the published image fails HIGH/CRITICAL image scans. The only
# change from upstream is go-mod-bump.sh. Same binary, config files, user and
# entrypoint as ghcr.io/opencost/opencost (upstream's Dockerfile.cross).
FROM --platform=$BUILDPLATFORM golang:1.26.11-alpine3.24 AS build
RUN apk add --no-cache git coreutils
ENV GOTOOLCHAIN=local CGO_ENABLED=0
ARG VERSION
RUN test -n "${VERSION}" && \
    git clone -q --depth 1 --branch v${VERSION} https://github.com/opencost/opencost.git /src
WORKDIR /src
COPY go-mod-bump.sh /usr/local/bin/go-mod-bump.sh
RUN sh /usr/local/bin/go-mod-bump.sh
ARG TARGETOS TARGETARCH
# Same version ldflags as upstream's justfile.
RUN P=github.com/opencost/opencost/core/pkg/version && cd cmd/costmodel && \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -mod=mod -trimpath \
      -ldflags "-X $P.Version=${VERSION} -X $P.GitCommit=$(git rev-parse --short HEAD)" -o /out/app .

FROM alpine:3.24
LABEL org.opencontainers.image.source="https://github.com/astuto-ai/onelens-installation-scripts"
# REFRESH changes on every CI build, so Alpine fixes published since the last build
# are picked up instead of this layer being served from the build cache.
ARG REFRESH=unknown
RUN apk upgrade --no-cache && apk add --no-cache ca-certificates
COPY --from=build --chmod=400 /src/THIRD_PARTY_LICENSES.txt /THIRD_PARTY_LICENSES.txt
COPY --from=build --chmod=500 /src/configs/default.json /src/configs/azure.json /src/configs/aws.json /src/configs/gcp.json \
     /src/configs/alibaba.json /src/configs/oracle.json /src/configs/otc.json /src/configs/stackit.json /models/
RUN chown -R 1001:1001 /models
COPY --from=build /out/app /go/bin/app
USER 1001
ENTRYPOINT ["/go/bin/app"]
