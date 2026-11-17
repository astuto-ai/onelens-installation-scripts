# node-exporter built from its upstream release tag with patched Go modules and Go
# toolchain, because the published image fails HIGH/CRITICAL image scans. The only
# change from upstream is go-mod-bump.sh. Same binary, user and entrypoint as
# quay.io/prometheus/node-exporter.
FROM --platform=$BUILDPLATFORM golang:1.26.11-alpine3.24 AS build
RUN apk add --no-cache git coreutils
ENV GOTOOLCHAIN=local CGO_ENABLED=0
ARG VERSION
RUN test -n "${VERSION}" && \
    git clone -q --depth 1 --branch v${VERSION} https://github.com/prometheus/node_exporter.git /src
WORKDIR /src
COPY go-mod-bump.sh /usr/local/bin/go-mod-bump.sh
RUN sh /usr/local/bin/go-mod-bump.sh
ARG TARGETOS TARGETARCH
# Same version ldflags as upstream's .promu.yml.
RUN P=github.com/prometheus/common/version && \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -mod=mod -trimpath \
      -ldflags "-X $P.Version=${VERSION} -X $P.Revision=$(git rev-parse HEAD) -X $P.Branch=HEAD -X $P.BuildUser=onelens -X $P.BuildDate=$(date -u +%Y%m%d-%H:%M:%S)" \
      -o /out/node_exporter .

FROM quay.io/prometheus/busybox:latest
LABEL org.opencontainers.image.source="https://github.com/astuto-ai/onelens-installation-scripts"
COPY --from=build /out/node_exporter /bin/node_exporter
EXPOSE      9100
USER        nobody
ENTRYPOINT  [ "/bin/node_exporter" ]
