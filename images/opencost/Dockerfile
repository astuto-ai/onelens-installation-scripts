# OpenCost built from the same source as the official ghcr.io/opencost/opencost image,
# with patched Go modules and Go toolchain, because the published image fails
# HIGH/CRITICAL image scans. The only change from upstream is go-mod-bump.sh. Same binary,
# version flags, config files, user and entrypoint as the official image.
#
# The official 1.120.4 image was not built from the v1.120.4 tag: its binary records
# vcs.revision 85c87a3 (`go version -m`), which is the v1.120.3 tag, 18 commits earlier.
# Those commits change pricing (Azure Windows nodes, custom-provider GPU defaults), so
# build the v1.120.3 source the official image contains, and check the tag still points
# at that commit. With the tag present, Go stamps the module as v1.120.3, as upstream does.
FROM --platform=$BUILDPLATFORM golang:1.26.11-alpine3.24 AS build
RUN apk add --no-cache git coreutils
ENV GOTOOLCHAIN=local CGO_ENABLED=0
ARG VERSION
ARG SOURCE_TAG=v1.120.3
ARG SOURCE_COMMIT=85c87a3f3fcc242efad69b5f3bcd42a3ae0205da
RUN test -n "${VERSION}" && \
    git clone -q --depth 1 --branch ${SOURCE_TAG} https://github.com/opencost/opencost.git /src && \
    test "$(git -C /src rev-parse HEAD)" = "${SOURCE_COMMIT}"
WORKDIR /src
COPY go-mod-bump.sh /usr/local/bin/go-mod-bump.sh
RUN sh /usr/local/bin/go-mod-bump.sh
ARG TARGETOS TARGETARCH
# Same version ldflags as the official image (Version=<release>, GitCommit=<short commit>).
RUN P=github.com/opencost/opencost/core/pkg/version && cd cmd/costmodel && \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -mod=mod -trimpath \
      -ldflags "-X $P.Version=${VERSION} -X $P.GitCommit=$(git rev-parse --short=7 HEAD)" -o /out/app .

FROM alpine:3.24
LABEL org.opencontainers.image.source="https://github.com/astuto-ai/onelens-installation-scripts"
# REFRESH changes on every CI build, so Alpine fixes published since the last build
# are picked up instead of this layer being served from the build cache.
ARG REFRESH=unknown
RUN apk upgrade --no-cache && apk add --no-cache ca-certificates
COPY --from=build --chmod=400 /src/THIRD_PARTY_LICENSES.txt /THIRD_PARTY_LICENSES.txt
# The pricing files the official 1.120.4 image ships in /models.
COPY --from=build --chmod=500 /src/configs/default.json /src/configs/azure.json /src/configs/aws.json /src/configs/gcp.json \
     /src/configs/alibaba.json /src/configs/oracle.json /src/configs/otc.json /models/
RUN chown -R 1001:1001 /models
COPY --from=build /out/app /go/bin/app
USER 1001
ENTRYPOINT ["/go/bin/app"]
