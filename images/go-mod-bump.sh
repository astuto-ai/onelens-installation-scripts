#!/bin/sh
# Raise Go modules in the current module to at least the versions below, never
# lowering one, and leave modules the project does not use alone.
#
# These are the lowest versions that fix every HIGH/CRITICAL finding Trivy reports
# for the images built from images/. When a scan reports a newer fix, raise the
# version here (or add the module), then publish a rebuild: move each affected TAG
# file to a newer upstream release, or add or raise its -olN suffix.
set -e

MIN_VERSIONS="
golang.org/x/net@v0.62.0
golang.org/x/crypto@v0.55.0
golang.org/x/text@v0.41.0
golang.org/x/oauth2@v0.27.0
google.golang.org/grpc@v1.83.2
github.com/klauspost/compress@v1.18.7
github.com/go-jose/go-jose/v4@v4.1.6
go.opentelemetry.io/otel/sdk@v1.43.0
github.com/opencontainers/selinux@v1.13.0
"

for spec in $MIN_VERSIONS; do
  mod=${spec%@*}
  want=${spec#*@}
  cur=$(go list -mod=mod -m -f '{{.Version}}' "$mod" 2>/dev/null || true)
  if [ -z "$cur" ]; then
    continue
  fi
  if [ "$(printf '%s\n%s\n' "$cur" "$want" | sort -V | tail -1)" = "$cur" ]; then
    echo "go-mod-bump: $mod $cur (already >= $want)"
    continue
  fi
  echo "go-mod-bump: $mod $cur -> $want"
  go get "$mod@$want"
done
