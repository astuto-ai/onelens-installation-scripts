# Pushgateway built from its upstream release tag with patched Go modules and Go
# toolchain, because the published image fails HIGH/CRITICAL image scans. The only
# change from upstream is go-mod-bump.sh. Same binary, paths, user and entrypoint
# as quay.io/prometheus/pushgateway.
FROM --platform=$BUILDPLATFORM golang:1.26.11-alpine3.24 AS build
RUN apk add --no-cache git coreutils
ENV GOTOOLCHAIN=local CGO_ENABLED=0
ARG VERSION
RUN test -n "${VERSION}" && \
    git clone -q --depth 1 --branch v${VERSION} https://github.com/prometheus/pushgateway.git /src
WORKDIR /src
COPY go-mod-bump.sh /usr/local/bin/go-mod-bump.sh
RUN sh /usr/local/bin/go-mod-bump.sh
ARG TARGETOS TARGETARCH
# Same version ldflags as upstream's .promu.yml.
RUN P=github.com/prometheus/common/version && \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -mod=mod -trimpath -tags netgo \
      -ldflags "-X $P.Version=${VERSION} -X $P.Revision=$(git rev-parse HEAD) -X $P.Branch=HEAD -X $P.BuildUser=onelens -X $P.BuildDate=$(date -u +%Y%m%d-%H:%M:%S)" \
      -o /out/pushgateway .

FROM quay.io/prometheus/busybox:latest
LABEL org.opencontainers.image.source="https://github.com/astuto-ai/onelens-installation-scripts"
COPY --from=build --chown=nobody:nobody /out/pushgateway /bin/pushgateway
EXPOSE 9091
WORKDIR /pushgateway
RUN chown nobody:nobody /pushgateway && chmod g+w /pushgateway
USER 65534
ENTRYPOINT [ "/bin/pushgateway" ]
