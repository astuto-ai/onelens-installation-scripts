# Prometheus built from its upstream release tag with patched Go modules and Go
# toolchain, because the published image fails HIGH/CRITICAL image scans. The only
# change from upstream is go-mod-bump.sh. Same binaries, paths, user and entrypoint
# as quay.io/prometheus/prometheus.
FROM --platform=$BUILDPLATFORM golang:1.26.11-alpine3.24 AS build
RUN apk add --no-cache git make bash coreutils curl tar gzip findutils
# GOWORK=off: the repo's go.work pulls in tool modules the binaries do not need.
ENV GOTOOLCHAIN=local CGO_ENABLED=0 GOWORK=off
ARG VERSION
# Prometheus 3.x tags its Go module as v0.3MM.P (3.13.5 -> v0.313.5). Fetching that
# tag lets the Go toolchain stamp the module version, so scanners match CVEs against
# the real release instead of a pseudo-version.
RUN test -n "${VERSION}" && \
    git clone -q --depth 1 --branch v${VERSION} https://github.com/prometheus/prometheus.git /src && \
    MAJOR=$(echo ${VERSION} | cut -d. -f1) MINOR=$(echo ${VERSION} | cut -d. -f2) PATCH=$(echo ${VERSION} | cut -d. -f3) && \
    cd /src && git fetch -q --depth 1 origin tag v0.$((MAJOR * 100 + MINOR)).${PATCH}
WORKDIR /src
COPY go-mod-bump.sh /usr/local/bin/go-mod-bump.sh
RUN sh /usr/local/bin/go-mod-bump.sh
# Use the web UI that upstream publishes with each release instead of building it with npm.
RUN curl -sSfL https://github.com/prometheus/prometheus/releases/download/v${VERSION}/prometheus-web-ui-${VERSION}.tar.gz | tar -xz -C web/ui && \
    PREBUILT_ASSETS_STATIC_DIR=web/ui/static scripts/compress_assets.sh
ARG TARGETOS TARGETARCH
# Same build tags and version ldflags as upstream's .promu.yml.
RUN P=github.com/prometheus/common/version && \
    LDFLAGS="-X $P.Version=${VERSION} -X $P.Revision=$(git rev-parse HEAD) -X $P.Branch=HEAD -X $P.BuildUser=onelens -X $P.BuildDate=$(date -u +%Y%m%d-%H:%M:%S)" && \
    for b in prometheus promtool; do \
      GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -mod=mod -trimpath -tags netgo,builtinassets -ldflags "$LDFLAGS" -o /out/$b ./cmd/$b; \
    done

FROM quay.io/prometheus/busybox:latest
LABEL org.opencontainers.image.source="https://github.com/astuto-ai/onelens-installation-scripts"
COPY --from=build /out/prometheus /bin/prometheus
COPY --from=build /out/promtool /bin/promtool
COPY --from=build /src/documentation/examples/prometheus.yml /etc/prometheus/prometheus.yml
COPY --from=build /src/LICENSE /LICENSE
COPY --from=build /src/NOTICE /NOTICE
WORKDIR /prometheus
RUN chown -R nobody:nobody /etc/prometheus /prometheus && chmod g+w /prometheus
USER       nobody
EXPOSE     9090
VOLUME     [ "/prometheus" ]
ENTRYPOINT [ "/bin/prometheus" ]
CMD        [ "--config.file=/etc/prometheus/prometheus.yml", \
             "--storage.tsdb.path=/prometheus" ]
