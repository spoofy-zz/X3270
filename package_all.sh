#!/usr/bin/env bash
# package_all.sh — Build both Apple Silicon and Intel DMGs in one deployment step.
#
# Usage:
#   ./package_all.sh               # uses BUILD_NUMBER=1 (default)
#   BUILD_NUMBER=42 ./package_all.sh
#
# Output (both in dist/):
#   DX3270-<version>-build<BUILD_NUMBER>.dmg          ← Apple Silicon
#   DX3270-<version>-build<BUILD_NUMBER>-Intel.dmg    ← Intel / older Macs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export BUILD_NUMBER="${BUILD_NUMBER:-1}"

echo "======================================================"
echo "  DX3270 — Full Deployment Build (build ${BUILD_NUMBER})"
echo "======================================================"
echo ""

# Track DMGs produced so we can print a clean summary at the end.
# Each sub-script prints its own detailed output; we just record results.
BEFORE_DMGS=()
if [ -d "${SCRIPT_DIR}/dist" ]; then
    while IFS= read -r -d '' f; do
        BEFORE_DMGS+=("$f")
    done < <(find "${SCRIPT_DIR}/dist" -name "*.dmg" -print0 2>/dev/null)
fi

# ── [1/2] Apple Silicon (arm64) ───────────────────────────────────────────────
echo "------------------------------------------------------"
echo "  [1/2] Apple Silicon (arm64)"
echo "------------------------------------------------------"
"${SCRIPT_DIR}/package.sh"
echo ""

# ── [2/2] Intel (x86_64) ──────────────────────────────────────────────────────
echo "------------------------------------------------------"
echo "  [2/2] Intel (x86_64)"
echo "------------------------------------------------------"
"${SCRIPT_DIR}/package_intel.sh"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "======================================================"
echo "  Deliverables"
echo "======================================================"

# List only newly created DMGs (created/modified during this run)
NEW_DMGS=()
while IFS= read -r -d '' f; do
    # Include if it wasn't in the list before
    already_existed=false
    for existing in "${BEFORE_DMGS[@]+"${BEFORE_DMGS[@]}"}"; do
        if [ "${existing}" = "${f}" ]; then
            already_existed=true
            break
        fi
    done
    if ! "${already_existed}"; then
        NEW_DMGS+=("$f")
    fi
done < <(find "${SCRIPT_DIR}/dist" -name "*.dmg" -print0 2>/dev/null)

if [ "${#NEW_DMGS[@]}" -eq 0 ]; then
    # Fallback: list everything in dist/
    while IFS= read -r -d '' f; do
        NEW_DMGS+=("$f")
    done < <(find "${SCRIPT_DIR}/dist" -name "*.dmg" -print0 2>/dev/null)
fi

for dmg in $(printf '%s\n' "${NEW_DMGS[@]}" | sort); do
    SIZE=$(du -sh "${dmg}" | cut -f1)
    printf "  %s  %s\n" "${SIZE}" "$(basename "${dmg}")"
done

echo ""
echo "Both DMGs are ready for distribution."
echo "  • Apple Silicon DMG → users on M-series Macs (2020+)"
echo "  • Intel DMG         → users on Intel Macs (older Macs)"
