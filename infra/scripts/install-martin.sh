#!/usr/bin/env bash
# Download Martin tile server binary into infra/bin (gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_DIR="${ROOT}/infra/bin"
mkdir -p "${BIN_DIR}"

VERSION="${MARTIN_VERSION:-martin-v1.13.0}"
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64) ASSET="martin-x86_64-unknown-linux-gnu.tar.gz" ;;
  aarch64|arm64) ASSET="martin-aarch64-unknown-linux-gnu.tar.gz" ;;
  *)
    echo "Unsupported arch: ${ARCH}" >&2
    exit 1
    ;;
esac

URL="https://github.com/maplibre/martin/releases/download/${VERSION}/${ASSET}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "==> Downloading ${URL}"
curl -fsSL "${URL}" -o "${TMP}/martin.tgz"
tar -xzf "${TMP}/martin.tgz" -C "${TMP}"

# Archive may place binaries at top level
if [[ -f "${TMP}/martin" ]]; then
  install -m 0755 "${TMP}/martin" "${BIN_DIR}/martin"
  [[ -f "${TMP}/martin-cp" ]] && install -m 0755 "${TMP}/martin-cp" "${BIN_DIR}/martin-cp"
else
  echo "Unexpected archive layout" >&2
  find "${TMP}" -type f | head
  exit 1
fi

"${BIN_DIR}/martin" --version
echo "Installed to ${BIN_DIR}/martin"
