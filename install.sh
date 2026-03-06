#!/usr/bin/env bash
set -euo pipefail

REPO_SLUG="${1:-${GITHUB_REPO:-}}"
RAW_BASE=""

if [[ -n "${REPO_SLUG}" ]]; then
  RAW_BASE="https://raw.githubusercontent.com/${REPO_SLUG}/main"
fi

if [[ -w /opt || ! -e /opt ]]; then
  INSTALL_DIR="${INSTALL_DIR:-/opt/xray-oneclick}"
else
  INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/xray-oneclick}"
fi

if [[ -w /usr/local/bin || ! -e /usr/local/bin ]]; then
  BIN_DIR="${BIN_DIR:-/usr/local/bin}"
else
  BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
fi

mkdir -p "${INSTALL_DIR}" "${BIN_DIR}"

download_file() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${out}"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "${out}" "${url}"
    return 0
  fi
  echo "ERROR: curl/wget not found" >&2
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/start_xray_oneclick.sh" && -f "${SCRIPT_DIR}/generate_xray_1to1.py" ]]; then
  cp "${SCRIPT_DIR}/start_xray_oneclick.sh" "${INSTALL_DIR}/start_xray_oneclick.sh"
  cp "${SCRIPT_DIR}/generate_xray_1to1.py" "${INSTALL_DIR}/generate_xray_1to1.py"
elif [[ -n "${RAW_BASE}" ]]; then
  download_file "${RAW_BASE}/start_xray_oneclick.sh" "${INSTALL_DIR}/start_xray_oneclick.sh"
  download_file "${RAW_BASE}/generate_xray_1to1.py" "${INSTALL_DIR}/generate_xray_1to1.py"
else
  echo "ERROR: cannot locate scripts locally, and REPO_SLUG is empty." >&2
  echo "Usage: install.sh <github_user/repo>" >&2
  exit 1
fi

chmod +x "${INSTALL_DIR}/start_xray_oneclick.sh" "${INSTALL_DIR}/generate_xray_1to1.py"

cat > "${BIN_DIR}/xray-oneclick" <<EOF
#!/usr/bin/env bash
exec "${INSTALL_DIR}/start_xray_oneclick.sh" "\$@"
EOF
chmod +x "${BIN_DIR}/xray-oneclick"

echo "Installed:"
echo "  ${INSTALL_DIR}/start_xray_oneclick.sh"
echo "  ${INSTALL_DIR}/generate_xray_1to1.py"
echo "Command:"
echo "  ${BIN_DIR}/xray-oneclick"

if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
  echo "NOTE: ${BIN_DIR} is not in PATH, run with full path:"
  echo "  ${BIN_DIR}/xray-oneclick"
fi
