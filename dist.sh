#!/usr/bin/env bash
set -euo pipefail

# Genera tarball de distribución css_diag_agent-VERSION.tar.gz
VERSION="${1:-$(date +%Y%m%d)}"
NAME="css_diag_agent-${VERSION}"
OUTDIR="dist"
TMPDIR_DIST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DIST"' EXIT

mkdir -p "$OUTDIR" "${TMPDIR_DIST}/${NAME}"

# Copiar solo los ficheros necesarios
cp install.sh diagnet.conf LICENSE README.md "${TMPDIR_DIST}/${NAME}/"
cp -R diagnet/ "${TMPDIR_DIST}/${NAME}/diagnet"
cp -R vmwatch/ "${TMPDIR_DIST}/${NAME}/vmwatch"
cp -R alerts/  "${TMPDIR_DIST}/${NAME}/alerts"

tar czf "${OUTDIR}/${NAME}.tar.gz" -C "$TMPDIR_DIST" "$NAME"

echo "${OUTDIR}/${NAME}.tar.gz"
