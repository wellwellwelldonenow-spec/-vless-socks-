#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN_SCRIPT="${BASE_DIR}/generate_xray_1to1.py"

if [[ ! -f "${GEN_SCRIPT}" ]]; then
  echo "ERROR: ${GEN_SCRIPT} not found" >&2
  exit 1
fi

INPUT_FILE=""
INPUT_TMP=""
XRAY_BIN="${XRAY_BIN:-xray}"
DEPLOY_TARGET="${DEPLOY_TARGET:-/usr/local/etc/xray/config.json}"
OUTPUT_CONFIG="${OUTPUT_CONFIG:-$(mktemp /tmp/xray_config.XXXXXX.json)}"
OUTPUT_MAPPING="${OUTPUT_MAPPING:-$(mktemp /tmp/xray_mapping.XXXXXX.csv)}"
RELOAD_CMD="${RELOAD_CMD:-systemctl reload xray}"
START_PORT_DEFAULT=20000
START_PORT="${START_PORT:-${START_PORT_DEFAULT}}"
LISTEN="${LISTEN:-0.0.0.0}"
SERVER_NAME="${SERVER_NAME:-www.cloudflare.com}"
DEST="${DEST:-www.cloudflare.com:443}"
FLOW="${FLOW:-xtls-rprx-vision}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
REMARK_PREFIX="${REMARK_PREFIX:-node}"
FINGERPRINT="${FINGERPRINT:-chrome}"
SPX="${SPX:-/}"
QR_SIZE="${QR_SIZE:-300}"
PER_INBOUND_KEY="${PER_INBOUND_KEY:-0}"
KEEP_ARTIFACTS="${KEEP_ARTIFACTS:-0}"
AUTO_INSTALL_XRAY="${AUTO_INSTALL_XRAY:-1}"
XRAY_INSTALL_PATH="${XRAY_INSTALL_PATH:-/root/xray}"
XRAY_LOCAL_ZIP="${XRAY_LOCAL_ZIP:-/root/Xray-linux-64.zip}"
XRAY_DOWNLOAD_URL="${XRAY_DOWNLOAD_URL:-https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip}"
ALLOW_PORT_CONFLICT="${ALLOW_PORT_CONFLICT:-0}"
AUTO_RUN_STANDALONE="${AUTO_RUN_STANDALONE:-1}"
STANDALONE_PID_FILE="${STANDALONE_PID_FILE:-/tmp/xray-oneclick.pid}"
STANDALONE_LOG_FILE="${STANDALONE_LOG_FILE:-/tmp/xray-oneclick.log}"
AUTO_FIX_SERVICE="${AUTO_FIX_SERVICE:-1}"
SERVICE_NAME="${SERVICE_NAME:-xray-oneclick.service}"
NO_SERVICE_MODE=0

usage() {
  cat <<'EOF'
Usage:
  1) stdin mode (recommended):
     cat socks.txt | ./start_xray_oneclick.sh

  2) file mode:
     ./start_xray_oneclick.sh -i socks.txt

  3) interactive paste mode:
     ./start_xray_oneclick.sh
     (paste lines, then input end/END/结束, or press Enter twice, or Ctrl+D)

Input format (one line each):
  host:port:username:password

Key env vars:
  PUBLIC_HOST       Server public IP/domain for share links (optional, auto-detect if empty)
  XRAY_BIN          xray binary path (default: xray)
  DEPLOY_TARGET     target config path (default: /usr/local/etc/xray/config.json)
  RELOAD_CMD        service apply cmd (default: auto-detect, usually systemctl restart <service>)
  START_PORT        inbound start port (default: 20000)
  SERVER_NAME       reality sni (default: www.cloudflare.com)
  DEST              reality dest (default: www.cloudflare.com:443)
  QR_SIZE           QR image size (default: 300)
  KEEP_ARTIFACTS    keep generated temp files (1 to keep, default: 0)
  AUTO_INSTALL_XRAY auto-install xray if missing (1/0, default: 1)
  XRAY_INSTALL_PATH install target path when auto-installing (default: /root/xray)
  XRAY_LOCAL_ZIP    local xray zip path (default: /root/Xray-linux-64.zip)
  ALLOW_PORT_CONFLICT ignore listening port conflicts (1/0, default: 0)
  AUTO_RUN_STANDALONE auto-run xray process when no systemd service exists (1/0, default: 1)
  AUTO_FIX_SERVICE  auto-create and enable systemd service if missing (1/0, default: 1)
  SERVICE_NAME      managed systemd unit name (default: xray-oneclick.service)
EOF
}

collect_interactive_input() {
  INPUT_TMP="$(mktemp /tmp/xray_socks.XXXXXX.txt)"
  local line=""
  local normalized=""
  local blank_count=0
  local data_count=0
  echo "Paste socks lines (host:port:user:pass), one per line."
  echo "Finish by: typing end/END/结束, or pressing Enter twice, or Ctrl+D."
  while IFS= read -r line || [[ -n "${line}" ]]; do
    normalized="$(echo "${line}" | tr -d '[:space:]')"
    if [[ "${normalized}" == "end" || "${normalized}" == "END" || "${normalized}" == "结束" ]]; then
      break
    fi
    if [[ -z "${normalized}" ]]; then
      if (( data_count > 0 )); then
        ((blank_count += 1))
        if (( blank_count >= 2 )); then
          break
        fi
      fi
      continue
    fi
    blank_count=0
    ((data_count += 1))
    echo "${line}" >> "${INPUT_TMP}"
  done
  if (( data_count == 0 )); then
    echo "ERROR: no socks lines received" >&2
    exit 1
  fi
  INPUT_FILE="${INPUT_TMP}"
}

collect_stdin_input() {
  INPUT_TMP="$(mktemp /tmp/xray_socks.XXXXXX.txt)"
  cat > "${INPUT_TMP}"
  INPUT_FILE="${INPUT_TMP}"
}

prompt_start_port() {
  local input=""
  while true; do
    read -r -p "Inbound start port [${START_PORT}]: " input || true
    input="$(echo "${input}" | tr -d '[:space:]')"
    if [[ -z "${input}" ]]; then
      break
    fi
    if [[ "${input}" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
      START_PORT="${input}"
      break
    fi
    echo "Invalid port. Please enter 1-65535."
  done
  echo "using START_PORT=${START_PORT}"
}

is_ipv4() {
  local ip="$1"
  if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi
  local IFS='.'
  # shellcheck disable=SC2206
  local octets=(${ip})
  for o in "${octets[@]}"; do
    if (( o < 0 || o > 255 )); then
      return 1
    fi
  done
  return 0
}

detect_public_host() {
  local candidate=""
  local url

  if command -v curl >/dev/null 2>&1; then
    for url in \
      "https://api64.ipify.org" \
      "https://ifconfig.me/ip" \
      "https://icanhazip.com" \
      "https://ipinfo.io/ip"; do
      candidate="$(curl -4fsS --max-time 5 "${url}" 2>/dev/null | tr -d '\r\n[:space:]' || true)"
      if is_ipv4 "${candidate}"; then
        echo "${candidate}"
        return 0
      fi
    done
  fi

  if command -v wget >/dev/null 2>&1; then
    for url in \
      "https://api64.ipify.org" \
      "https://ifconfig.me/ip" \
      "https://icanhazip.com" \
      "https://ipinfo.io/ip"; do
      candidate="$(wget -4 -qO- --timeout=5 "${url}" 2>/dev/null | tr -d '\r\n[:space:]' || true)"
      if is_ipv4 "${candidate}"; then
        echo "${candidate}"
        return 0
      fi
    done
  fi

  if command -v python3 >/dev/null 2>&1; then
    candidate="$(
      python3 - <<'PY'
import sys
import urllib.request
endpoints = [
    "https://api64.ipify.org",
    "https://ifconfig.me/ip",
    "https://icanhazip.com",
    "https://ipinfo.io/ip",
]
for url in endpoints:
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            text = r.read().decode("utf-8", "ignore").strip()
        parts = text.split(".")
        if len(parts) == 4 and all(p.isdigit() and 0 <= int(p) <= 255 for p in parts):
            print(text)
            sys.exit(0)
    except Exception:
        continue
sys.exit(1)
PY
    )" || true
    candidate="$(echo "${candidate}" | tr -d '\r\n[:space:]')"
    if is_ipv4 "${candidate}"; then
      echo "${candidate}"
      return 0
    fi
  fi

  return 1
}

detect_xray_bin() {
  local candidate=""
  if command -v "${XRAY_BIN}" >/dev/null 2>&1; then
    command -v "${XRAY_BIN}"
    return 0
  fi
  for candidate in /usr/local/bin/xray /usr/bin/xray /root/xray; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

detect_reload_cmd() {
  local unit=""
  local listed_units=""
  local active_units=""

  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  listed_units="$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}')"
  for unit in "${SERVICE_NAME}" xray.service v2ray.service xrayr.service sing-box.service; do
    if echo "${listed_units}" | grep -Fxq "${unit}"; then
      echo "systemctl restart ${unit}"
      return 0
    fi
  done

  active_units="$(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}')"
  unit="$(echo "${active_units}" | grep -E '^(xray|v2ray)@.+\.service$' | head -n1 || true)"
  if [[ -n "${unit}" ]]; then
    echo "systemctl restart ${unit}"
    return 0
  fi

  return 1
}

ensure_managed_service() {
  local service_path="/etc/systemd/system/${SERVICE_NAME}"
  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi
  cat > "${service_path}" <<EOF
[Unit]
Description=Xray OneClick Managed Service
After=network.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${DEPLOY_TARGET}
Restart=always
RestartSec=2
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
  systemctl is-active --quiet "${SERVICE_NAME}"
  echo "service ready: ${SERVICE_NAME}"
  return 0
}

extract_xray_from_zip() {
  local zip_path="$1"
  local target_path="$2"
  local target_dir=""
  local target_name=""
  target_dir="$(dirname "${target_path}")"
  target_name="$(basename "${target_path}")"
  mkdir -p "${target_dir}"

  if ! command -v unzip >/dev/null 2>&1; then
    echo "ERROR: unzip command not found, cannot extract ${zip_path}" >&2
    return 1
  fi

  unzip -o -j "${zip_path}" xray -d "${target_dir}" >/dev/null
  if [[ "${target_name}" != "xray" ]]; then
    mv -f "${target_dir}/xray" "${target_path}"
  fi
  chmod +x "${target_path}"
  return 0
}

install_xray_if_missing() {
  local target_path=""
  local tmp_zip=""
  if [[ "${XRAY_BIN}" == */* ]]; then
    target_path="${XRAY_BIN}"
  else
    target_path="${XRAY_INSTALL_PATH}"
  fi

  if [[ -f "${XRAY_LOCAL_ZIP}" ]]; then
    echo "xray not found, installing from local zip: ${XRAY_LOCAL_ZIP}"
    extract_xray_from_zip "${XRAY_LOCAL_ZIP}" "${target_path}"
    return $?
  fi

  echo "xray not found, trying online install from: ${XRAY_DOWNLOAD_URL}"
  tmp_zip="$(mktemp /tmp/xray_download.XXXXXX.zip)"
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fL --connect-timeout 8 --max-time 60 -o "${tmp_zip}" "${XRAY_DOWNLOAD_URL}"; then
      rm -f "${tmp_zip}"
      return 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -O "${tmp_zip}" "${XRAY_DOWNLOAD_URL}" --timeout=60; then
      rm -f "${tmp_zip}"
      return 1
    fi
  else
    echo "ERROR: neither curl nor wget found for online xray install" >&2
    rm -f "${tmp_zip}"
    return 1
  fi

  if ! extract_xray_from_zip "${tmp_zip}" "${target_path}"; then
    rm -f "${tmp_zip}"
    return 1
  fi
  rm -f "${tmp_zip}"
  return 0
}

count_input_lines() {
  local f="$1"
  awk '
    /^[[:space:]]*$/ {next}
    /^[[:space:]]*#/ {next}
    {count++}
    END{print count+0}
  ' "${f}"
}

collect_used_ports() {
  ss -lnt 2>/dev/null | awk 'NR>1 {split($4,a,":"); p=a[length(a)]; if (p ~ /^[0-9]+$/) print p}' | sort -n | uniq
}

check_port_conflicts() {
  local start_port="$1"
  local count="$2"
  local end_port=0
  local used=""
  local p=0
  local conflicts=""
  if [[ "${ALLOW_PORT_CONFLICT}" == "1" ]]; then
    return 0
  fi
  end_port=$((start_port + count - 1))
  used="$(collect_used_ports)"
  for ((p=start_port; p<=end_port; p++)); do
    if echo "${used}" | grep -Fxq "${p}"; then
      conflicts="${conflicts} ${p}"
    fi
  done
  if [[ -n "${conflicts}" ]]; then
    echo "ERROR: inbound port conflict:${conflicts}" >&2
    echo "Hint: change START_PORT, stop old service/process, or set ALLOW_PORT_CONFLICT=1" >&2
    return 1
  fi
  return 0
}

start_standalone_xray() {
  local old_pid=""
  mkdir -p "$(dirname "${STANDALONE_PID_FILE}")" "$(dirname "${STANDALONE_LOG_FILE}")"

  if [[ -f "${STANDALONE_PID_FILE}" ]]; then
    old_pid="$(cat "${STANDALONE_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
      kill "${old_pid}" 2>/dev/null || true
      sleep 0.5
    fi
  fi

  nohup "${XRAY_BIN}" run -c "${DEPLOY_TARGET}" >> "${STANDALONE_LOG_FILE}" 2>&1 &
  echo $! > "${STANDALONE_PID_FILE}"
  sleep 0.8

  if ! kill -0 "$(cat "${STANDALONE_PID_FILE}")" 2>/dev/null; then
    echo "ERROR: standalone xray failed to start, check log: ${STANDALONE_LOG_FILE}" >&2
    tail -n 30 "${STANDALONE_LOG_FILE}" 2>/dev/null || true
    return 1
  fi
  echo "standalone xray started: pid=$(cat "${STANDALONE_PID_FILE}") log=${STANDALONE_LOG_FILE}"
  return 0
}

while getopts ":hi:" opt; do
  case "${opt}" in
    h)
      usage
      exit 0
      ;;
    i)
      INPUT_FILE="${OPTARG}"
      ;;
    \?)
      echo "ERROR: invalid option -${OPTARG}" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -n "${INPUT_FILE}" && ! -f "${INPUT_FILE}" ]]; then
  echo "ERROR: input file not found: ${INPUT_FILE}" >&2
  exit 1
fi

if [[ -t 0 ]]; then
  prompt_start_port
fi

if [[ -z "${PUBLIC_HOST}" ]]; then
  PUBLIC_HOST="$(detect_public_host || true)"
  if [[ -z "${PUBLIC_HOST}" ]]; then
    echo "ERROR: failed to auto-detect public IP, set PUBLIC_HOST manually" >&2
    exit 1
  fi
  echo "auto-detected PUBLIC_HOST=${PUBLIC_HOST}"
fi

XRAY_BIN_DETECTED="$(detect_xray_bin || true)"
if [[ -z "${XRAY_BIN_DETECTED}" ]]; then
  if [[ "${AUTO_INSTALL_XRAY}" == "1" ]]; then
    if install_xray_if_missing; then
      XRAY_BIN_DETECTED="$(detect_xray_bin || true)"
    fi
  fi
  if [[ -z "${XRAY_BIN_DETECTED}" ]]; then
    echo "ERROR: xray binary not found and auto-install failed." >&2
    echo "Set XRAY_BIN=/path/to/xray or provide local zip at ${XRAY_LOCAL_ZIP}" >&2
    exit 1
  fi
fi
XRAY_BIN="${XRAY_BIN_DETECTED}"
echo "using XRAY_BIN=${XRAY_BIN}"

if [[ "${RELOAD_CMD}" == "systemctl reload xray" ]]; then
  RELOAD_CMD_DETECTED="$(detect_reload_cmd || true)"
  if [[ -n "${RELOAD_CMD_DETECTED}" ]]; then
    RELOAD_CMD="${RELOAD_CMD_DETECTED}"
    echo "auto-detected RELOAD_CMD=${RELOAD_CMD}"
  else
    NO_SERVICE_MODE=1
    RELOAD_CMD=""
    echo "WARN: no xray/v2ray systemd service found, reload skipped"
  fi
fi

cleanup() {
  if [[ "${KEEP_ARTIFACTS}" != "1" ]]; then
    rm -f "${OUTPUT_CONFIG}" "${OUTPUT_MAPPING}" "${INPUT_TMP}" || true
  fi
}
trap cleanup EXIT

if [[ -z "${INPUT_FILE}" && -t 0 ]]; then
  collect_interactive_input
fi
if [[ -z "${INPUT_FILE}" && ! -t 0 ]]; then
  collect_stdin_input
fi

ENTRY_COUNT=0
if [[ -n "${INPUT_FILE}" ]]; then
  ENTRY_COUNT="$(count_input_lines "${INPUT_FILE}")"
fi
if [[ "${ENTRY_COUNT}" -le 0 ]]; then
  echo "ERROR: no valid input lines" >&2
  exit 1
fi
check_port_conflicts "${START_PORT}" "${ENTRY_COUNT}"

ARGS=(
  "--output" "${OUTPUT_CONFIG}"
  "--mapping" "${OUTPUT_MAPPING}"
  "--start-port" "${START_PORT}"
  "--listen" "${LISTEN}"
  "--server-name" "${SERVER_NAME}"
  "--dest" "${DEST}"
  "--flow" "${FLOW}"
  "--xray-bin" "${XRAY_BIN}"
  "--validate"
  "--deploy-target" "${DEPLOY_TARGET}"
  "--public-host" "${PUBLIC_HOST}"
  "--remark-prefix" "${REMARK_PREFIX}"
  "--fingerprint" "${FINGERPRINT}"
  "--spx" "${SPX}"
  "--qr-size" "${QR_SIZE}"
  "--no-link-files"
  "--print-links"
  "--print-qr"
)

if [[ -n "${RELOAD_CMD}" ]]; then
  ARGS+=("--reload-cmd" "${RELOAD_CMD}")
fi

if [[ "${PER_INBOUND_KEY}" == "1" ]]; then
  ARGS+=("--per-inbound-key")
fi

if [[ -n "${INPUT_FILE}" ]]; then
  ARGS+=("--input" "${INPUT_FILE}")
  python3 "${GEN_SCRIPT}" "${ARGS[@]}"
else
  python3 "${GEN_SCRIPT}" "${ARGS[@]}"
fi

if [[ "${NO_SERVICE_MODE}" == "1" ]]; then
  if [[ "${AUTO_FIX_SERVICE}" == "1" ]] && ensure_managed_service; then
    RELOAD_CMD="systemctl restart ${SERVICE_NAME}"
    echo "auto-fixed: using managed service ${SERVICE_NAME}"
  elif [[ "${AUTO_RUN_STANDALONE}" == "1" ]]; then
    start_standalone_xray
  else
    echo "ERROR: no runnable service mode available" >&2
    exit 1
  fi
fi

echo "done."
if [[ "${KEEP_ARTIFACTS}" == "1" ]]; then
  echo "config: ${OUTPUT_CONFIG}"
  echo "mapping: ${OUTPUT_MAPPING}"
fi
