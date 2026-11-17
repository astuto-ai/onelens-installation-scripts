# VictoriaMetrics single-node built from its upstream release tag with patched Go modules,
# Go toolchain and Alpine packages, because the published image fails HIGH/CRITICAL image
# scans. The only change from upstream is go-mod-bump.sh. Same binary path, port and
# entrypoint as victoriametrics/victoria-metrics.
#
# Kept at the version clusters already run: v1.133.0 and later change the on-disk index
# (series written by them are not visible to older versions after a rollback).
#
# Built like upstream's linux/amd64 and linux/arm64 releases: CGO with musl, so zstd uses
# the bundled C library (upstream reports pure-Go builds can fail to read data blocks).
# There is no --platform=$BUILDPLATFORM: the C toolchain must match the target, so arm64
# compiles under emulation.
FROM golang:1.26.11-alpine3.24 AS build
RUN apk add --no-cache git coreutils gcc musl-dev
ENV GOTOOLCHAIN=local CGO_ENABLED=1
ARG VERSION
RUN test -n "${VERSION}" && \
    git clone -q --depth 1 --branch v${VERSION} https://github.com/VictoriaMetrics/VictoriaMetrics.git /src
WORKDIR /src
COPY go-mod-bump.sh /usr/local/bin/go-mod-bump.sh
RUN sh /usr/local/bin/go-mod-bump.sh
# Same build flags and version string as upstream's deployment/docker/Makefile (app-via-docker).
RUN BUILDINFO="victoria-metrics-$(date -u +%Y%m%d-%H%M%S)-$(git describe --long --all | tr '/' '-')" && \
    go build -mod=mod -trimpath -buildvcs=false \
      -ldflags "-extldflags '-static' -X 'github.com/VictoriaMetrics/VictoriaMetrics/lib/buildinfo.Version=${BUILDINFO}'" \
      -tags 'netgo osusergo musl' \
      -o /out/victoria-metrics-prod ./app/victoria-metrics

FROM alpine:3.24
LABEL org.opencontainers.image.source="https://github.com/astuto-ai/onelens-installation-scripts"
# REFRESH changes on every CI build, so Alpine fixes published since the last build
# are picked up instead of this layer being served from the build cache.
ARG REFRESH=unknown
RUN apk upgrade --no-cache && apk add --no-cache ca-certificates
COPY --from=build /out/victoria-metrics-prod /victoria-metrics-prod
EXPOSE 8428
ENTRYPOINT ["/victoria-metrics-prod"]
