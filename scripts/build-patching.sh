#!/bin/bash
# scripts/build-patching.sh — Embed lib/resource-sizing.sh into patching.sh
#
# Reads src/patching.sh (the source file you edit during development).
# Replaces the source line between BEGIN_EMBED/END_EMBED markers
# with the actual content of lib/resource-sizing.sh.
# Output: patching.sh at repo root (self-contained, ready for GitHub tag).
#
# Development workflow:
#   - Always edit src/patching.sh (has source line, clean library calls)
#   - Run this script to produce the root patching.sh (build artifact)
#   - CI runs this before tagging a release
#   - Backend fetches root patching.sh from GitHub — works standalone
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LIB_FILE="$ROOT/lib/resource-sizing.sh"
SRC_FILE="$ROOT/src/patching.sh"
OUT_FILE="$ROOT/patching.sh"

# Validate inputs
if [ ! -f "$LIB_FILE" ]; then
    echo "ERROR: $LIB_FILE not found"
    exit 1
fi
if [ ! -f "$SRC_FILE" ]; then
    echo "ERROR: $SRC_FILE not found"
    exit 1
fi

# Read the library content (skip the shebang if present)
LIB_CONTENT=$(sed '1{/^#!/d;}' "$LIB_FILE")

# Process the source file: replace everything between BEGIN_EMBED and END_EMBED
# with the library content
IN_EMBED=false
{
    while IFS= read -r line || [ -n "$line" ]; do
        if echo "$line" | grep -q 'BEGIN_EMBED'; then
            echo "$line"
            echo "# --- Embedded from lib/resource-sizing.sh ---"
            echo "$LIB_CONTENT"
            echo "# --- End embedded content ---"
            IN_EMBED=true
            continue
        fi
        if echo "$line" | grep -q 'END_EMBED'; then
            echo "$line"
            IN_EMBED=false
            continue
        fi
        if [ "$IN_EMBED" = false ]; then
            echo "$line"
        fi
    done
} < "$SRC_FILE" > "$OUT_FILE"

chmod +x "$OUT_FILE"

# Validate output
if ! bash -n "$OUT_FILE" 2>/dev/null; then
    echo "ERROR: Generated $OUT_FILE has syntax errors"
    bash -n "$OUT_FILE"
    exit 1
fi

# Verify no source line remains between markers
if grep -q 'source.*resource-sizing' "$OUT_FILE" 2>/dev/null; then
    # Check if it's between the markers (embedded) — that's OK since it's commented context
    # But if it's an actual source command outside markers, that's a problem
    source_lines=$(grep -n 'source.*resource-sizing' "$OUT_FILE" | grep -v '#' || true)
    if [ -n "$source_lines" ]; then
        echo "WARNING: source line for resource-sizing.sh still present in output:"
        echo "$source_lines"
    fi
fi

echo "Built: $OUT_FILE"
echo "Size: $(wc -c < "$OUT_FILE") bytes, $(wc -l < "$OUT_FILE") lines"
