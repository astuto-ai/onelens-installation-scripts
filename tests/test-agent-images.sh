#!/bin/bash
# Third-party images that OneLens publishes itself (images/<name>) so they pass
# customers' HIGH/CRITICAL image scans: rebuilt from upstream source (Dockerfile) or
# copied unchanged (MIRROR). globalvalues.yaml must pull exactly the published tags, and
# the air-gapped migration script must mirror the same images.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
set_test_file "test-agent-images.sh"
ROOT=$(repo_root)
GV="$ROOT/globalvalues.yaml"
MIGRATE="$ROOT/scripts/airgapped/airgapped_migrate_images.sh"

# Tag on the line after "repository: <repo>" in a values file.
_tag_after() {
    grep -A1 "repository: $2\$" "$1" | grep 'tag:' | head -1 | awk '{print $2}' | tr -d '"'
}

###############################################################################
# Test 1: globalvalues.yaml pins every OneLens-published image at its published tag
###############################################################################
for dir in "$ROOT"/images/*/; do
    name=$(basename "$dir")
    tag=$(tr -d '[:space:]' < "$dir/TAG")
    assert_ne "$tag" "" "images/$name/TAG is set"
    gv_tag=$(_tag_after "$GV" "\(public.ecr.aws/\)\{0,1\}w7k6q5m9/onelens-$name")
    assert_eq "$gv_tag" "$tag" "globalvalues.yaml pulls onelens-$name:$tag"
    if [ -f "$dir/MIRROR" ]; then
        mirror=$(tr -d '[:space:]' < "$dir/MIRROR")
        assert_eq "${mirror##*:}" "$tag" "images/$name copies upstream $mirror under the same tag"
    else
        assert_gt "$(grep -c 'go-mod-bump.sh' "$dir/Dockerfile" || true)" "0" "images/$name/Dockerfile raises flagged Go modules"
    fi
done

###############################################################################
# Test 2: no image is pulled from the upstream registries these replace
###############################################################################
for upstream in quay.io/prometheus/prometheus quay.io/prometheus/pushgateway opencost/opencost kube-state-metrics/kube-state-metrics \
        victoriametrics/victoria-metrics quay.io/prometheus-operator/prometheus-config-reloader busybox; do
    assert_eq "$(grep -c "repository: $upstream\$" "$GV" || true)" "0" "globalvalues.yaml no longer pulls $upstream"
done

###############################################################################
# Test 3: go-mod-bump.sh raises a module, never lowers one, and skips unused ones
###############################################################################
# A module graph with x/net below its fix, x/crypto above it, and nothing else.
_fake_go() {
    case "$*" in
        "list -mod=mod -m -f {{.Version}} golang.org/x/net") echo v0.55.0 ;;
        "list -mod=mod -m -f {{.Version}} golang.org/x/crypto") echo v0.60.0 ;;
        "list -mod=mod -m -f {{.Version}} "*) return 1 ;;
        "get "*) echo "GET $2" ;;
    esac
}
_run_bump() {
    go() { _fake_go "$@"; }
    . "$ROOT/images/go-mod-bump.sh"
}
bump_out=$(_run_bump)
assert_contains "$bump_out" "GET golang.org/x/net@v0.62.0" "older module raised to its fixed version"
assert_eq "$(echo "$bump_out" | grep -c 'GET golang.org/x/crypto' || true)" "0" "newer module left alone"
assert_eq "$(echo "$bump_out" | grep -c 'GET google.golang.org/grpc' || true)" "0" "unused module not added"

###############################################################################
# Test 4: air-gapped migration mirrors the same images for new and old versions
###############################################################################
# The image-list section of the migration script, from IMAGES="" up to dcgm-exporter.
list_block=$(sed -n '/^IMAGES=""$/,/^# dcgm-exporter/p' "$MIGRATE" | sed '$d')
assert_ne "$list_block" "" "migration script has the image list section"

# _migrate_list <globalvalues.yaml> -> "<source> <target>" lines
_migrate_list() {
    local dir
    dir=$(mktemp -d)
    cp "$1" "$dir/values.yaml"
    ( TMPDIR="$dir"; VERSION=0.0.0; eval "$list_block" >/dev/null; echo "$IMAGES" | sed '/^$/d' )
    rm -rf "$dir"
}

current=$(_migrate_list "$GV")
for name in prometheus pushgateway opencost kube-state-metrics node-exporter victoria-metrics prometheus-config-reloader; do
    tag=$(tr -d '[:space:]' < "$ROOT/images/$name/TAG")
    assert_contains "$current" "public.ecr.aws/w7k6q5m9/onelens-$name:$tag $name:$tag" "mirrors OneLens-published $name"
done

# globalvalues.yaml as released before 2.1.128 still names the upstream registries.
old_gv=$(mktemp)
sed -e 's#public.ecr.aws/w7k6q5m9/onelens-prometheus$#quay.io/prometheus/prometheus#' \
    -e 's#public.ecr.aws/w7k6q5m9/onelens-pushgateway$#quay.io/prometheus/pushgateway#' \
    -e 's#w7k6q5m9/onelens-opencost$#opencost/opencost#' \
    -e 's#w7k6q5m9/onelens-kube-state-metrics$#kube-state-metrics/kube-state-metrics#' \
    -e 's#public.ecr.aws/w7k6q5m9/onelens-victoria-metrics$#victoriametrics/victoria-metrics#' \
    -e 's#public.ecr.aws/w7k6q5m9/onelens-prometheus-config-reloader$#quay.io/prometheus-operator/prometheus-config-reloader#' \
    "$GV" > "$old_gv"
old=$(_migrate_list "$old_gv")
rm -f "$old_gv"
assert_contains "$old" "quay.io/prometheus/prometheus:" "older version: prometheus from quay.io"
assert_contains "$old" "quay.io/prometheus/pushgateway:" "older version: pushgateway from quay.io"
assert_contains "$old" "ghcr.io/opencost/opencost:" "older version: opencost from ghcr.io"
assert_contains "$old" "registry.k8s.io/kube-state-metrics/kube-state-metrics:" "older version: kube-state-metrics from registry.k8s.io"
assert_contains "$old" "quay.io/victoriametrics/victoria-metrics:" "older version: victoria-metrics from quay.io"
assert_contains "$old" "quay.io/prometheus-operator/prometheus-config-reloader:" "older version: config-reloader from quay.io"

test_summary
