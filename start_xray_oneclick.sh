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
PUBLIC_FILES_DIR="${PUBLIC_FILES_DIR:-/opt/xray-oneclick/public}"
QR_BUNDLE_ZIP="${QR_BUNDLE_ZIP:-${PUBLIC_FILES_DIR}/qr_bundle.zip}"
FILE_HTTP_PORT="${FILE_HTTP_PORT:-18089}"
FILE_SERVICE_NAME="${FILE_SERVICE_NAME:-xray-oneclick-files.service}"
AUTO_QR_FILE_SERVER="${AUTO_QR_FILE_SERVER:-1}"
MENU_ENABLED="${MENU_ENABLED:-1}"
NODES_DB="${NODES_DB:-/opt/xray-oneclick/nodes.csv}"
START_PORT_FILE="${START_PORT_FILE:-/opt/xray-oneclick/start_port}"
USE_SAVED_PORT=0
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
  AUTO_QR_FILE_SERVER auto-start file server for QR bundle zip (1/0, default: 1)
  FILE_HTTP_PORT    file server port for QR bundle download (default: 18089)
  MENU_ENABLED      show interactive management menu in TTY mode (1/0, default: 1)
  NODES_DB          node source file for management menu (default: /opt/xray-oneclick/nodes.csv)
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

ensure_nodes_db_dir() {
  mkdir -p "$(dirname "${NODES_DB}")"
}

persist_nodes_db_from_input() {
  local src="$1"
  local tmp=""
  ensure_nodes_db_dir
  tmp="$(mktemp /tmp/nodes_db.XXXXXX)"
  awk '
    /^[[:space:]]*$/ {next}
    /^[[:space:]]*#/ {next}
    {print}
  ' "${src}" > "${tmp}"
  mv -f "${tmp}" "${NODES_DB}"
}

save_start_port() {
  ensure_nodes_db_dir
  echo "${START_PORT}" > "${START_PORT_FILE}"
}

load_saved_start_port() {
  if [[ -f "${START_PORT_FILE}" ]]; then
    local saved=""
    saved="$(tr -d '[:space:]' < "${START_PORT_FILE}" || true)"
    if [[ "${saved}" =~ ^[0-9]+$ ]] && (( saved >= 1 && saved <= 65535 )); then
      START_PORT="${saved}"
      echo "using saved START_PORT=${START_PORT}"
      return 0
    fi
  fi
  return 1
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

list_nodes_db() {
  if [[ ! -f "${NODES_DB}" ]]; then
    echo "nodes db not found: ${NODES_DB}"
    return 1
  fi
  awk '
    /^[[:space:]]*$/ {next}
    /^[[:space:]]*#/ {next}
    {print ++n ". " $0}
    END{if(n==0) print "no nodes"}
  ' "${NODES_DB}"
}

collect_nodes_append_to_db() {
  local tmp=""
  local line=""
  local normalized=""
  local blank_count=0
  local data_count=0
  tmp="$(mktemp /tmp/node_add.XXXXXX)"
  echo "Paste SOCKS lines to add (host:port:user:pass)"
  echo "Finish with: end / END / 结束 / double Enter / Ctrl+D"
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
    echo "${line}" >> "${tmp}"
  done
  if (( data_count == 0 )); then
    rm -f "${tmp}"
    echo "no lines added"
    return 1
  fi
  ensure_nodes_db_dir
  touch "${NODES_DB}"
  cat "${tmp}" >> "${NODES_DB}"
  rm -f "${tmp}"
  echo "nodes appended into ${NODES_DB}"
  return 0
}

parse_batch_indices_to_csv() {
  local raw="$1"
  python3 - <<PY
raw = """${raw}"""
parts = [p.strip() for p in raw.replace(" ", "").split(",") if p.strip()]
nums = set()
for p in parts:
    if "-" in p:
        a, b = p.split("-", 1)
        if a.isdigit() and b.isdigit():
            x, y = int(a), int(b)
            if x > y:
                x, y = y, x
            for i in range(x, y + 1):
                nums.add(i)
    elif p.isdigit():
        nums.add(int(p))
vals = [str(x) for x in sorted(n for n in nums if n > 0)]
print(",".join(vals))
PY
}

delete_nodes_by_csv_indices() {
  local csv_indices="$1"
  local tmp=""
  if [[ -z "${csv_indices}" ]]; then
    echo "no valid indices"
    return 1
  fi
  if [[ ! -f "${NODES_DB}" ]]; then
    echo "nodes db not found: ${NODES_DB}"
    return 1
  fi
  tmp="$(mktemp /tmp/node_del.XXXXXX)"
  awk -v dels="${csv_indices}" '
    BEGIN {
      split(dels, a, ",")
      for (i in a) del[a[i]] = 1
    }
    /^[[:space:]]*$/ {next}
    /^[[:space:]]*#/ {next}
    {
      n++
      if (!(n in del)) print $0
    }
  ' "${NODES_DB}" > "${tmp}"
  mv -f "${tmp}" "${NODES_DB}"
  echo "deleted indices: ${csv_indices}"
  return 0
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

show_service_status() {
  local main_state="inactive"
  local file_state="inactive"
  echo "=== Service Status ==="
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
      main_state="active"
    fi
    if systemctl is-active --quiet "${FILE_SERVICE_NAME}" 2>/dev/null; then
      file_state="active"
    fi
    echo "- ${SERVICE_NAME}: ${main_state}"
    echo "- ${FILE_SERVICE_NAME}: ${file_state}"
  else
    echo "systemctl not found"
  fi

  echo "=== Listener Ports ==="
  if [[ -f "${DEPLOY_TARGET}" ]]; then
    python3 - <<PY
import json
from pathlib import Path
p=Path("${DEPLOY_TARGET}")
try:
    c=json.loads(p.read_text())
except Exception:
    print("config parse failed:", p)
    raise SystemExit(0)
ports=[str(b.get("port")) for b in c.get("inbounds",[]) if b.get("port")]
print("configured inbound ports:", ",".join(ports) if ports else "none")
PY
  fi
  ss -lnt 2>/dev/null | awk 'NR==1 || /:20[0-9]{3}|:18[0-9]{3}/'
}

service_action() {
  local action="$1"
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found"
    return 1
  fi
  if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "${SERVICE_NAME}"; then
    systemctl "${action}" "${SERVICE_NAME}" || true
  else
    echo "${SERVICE_NAME} not found"
  fi
  if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "${FILE_SERVICE_NAME}"; then
    systemctl "${action}" "${FILE_SERVICE_NAME}" || true
  fi
}

show_recent_logs() {
  echo "=== Logs: ${SERVICE_NAME} ==="
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "${SERVICE_NAME}"; then
    journalctl -u "${SERVICE_NAME}" -n 80 --no-pager || true
  else
    echo "service log not available, fallback:"
    tail -n 80 "${STANDALONE_LOG_FILE}" 2>/dev/null || true
  fi
}

show_qr_bundle_download() {
  local host="${PUBLIC_HOST}"
  if [[ -z "${host}" ]]; then
    host="$(detect_public_host || true)"
  fi
  if [[ -z "${host}" ]]; then
    host="YOUR_PUBLIC_IP"
  fi
  if [[ -f "${QR_BUNDLE_ZIP}" ]]; then
    echo "QR bundle download:"
    echo "http://${host}:${FILE_HTTP_PORT}/$(basename "${QR_BUNDLE_ZIP}")"
  else
    echo "QR bundle not found: ${QR_BUNDLE_ZIP}"
  fi
}

interactive_menu() {
  local choice=""
  local idx=""
  local batch=""
  local csv_indices=""
  while true; do
    cat <<EOF

======== Xray OneClick Menu ========
1) Generate / Update Nodes
2) Show Service Status
3) Start Services
4) Restart Services
5) Stop Services
6) Show Recent Logs
7) Show QR Bundle Download Link
8) Add Nodes (append)
9) Delete One Node
10) Delete Batch Nodes
11) List Nodes DB
0) Exit
====================================
EOF
    read -r -p "Select: " choice || true
    case "${choice}" in
      1) return 0 ;;
      2) show_service_status ;;
      3) service_action start ;;
      4) service_action restart ;;
      5) service_action stop ;;
      6) show_recent_logs ;;
      7) show_qr_bundle_download ;;
      8)
        if collect_nodes_append_to_db; then
          INPUT_FILE="${NODES_DB}"
          USE_SAVED_PORT=1
          return 0
        fi
        ;;
      9)
        list_nodes_db || true
        read -r -p "Delete index: " idx || true
        idx="$(echo "${idx}" | tr -d '[:space:]')"
        if [[ "${idx}" =~ ^[0-9]+$ ]]; then
          if delete_nodes_by_csv_indices "${idx}"; then
            INPUT_FILE="${NODES_DB}"
            USE_SAVED_PORT=1
            return 0
          fi
        else
          echo "invalid index"
        fi
        ;;
      10)
        list_nodes_db || true
        read -r -p "Delete indices (example: 1,3,5-8): " batch || true
        csv_indices="$(parse_batch_indices_to_csv "${batch}")"
        if delete_nodes_by_csv_indices "${csv_indices}"; then
          INPUT_FILE="${NODES_DB}"
          USE_SAVED_PORT=1
          return 0
        fi
        ;;
      11)
        list_nodes_db || true
        ;;
      0|q|Q) exit 0 ;;
      *) echo "invalid selection" ;;
    esac
  done
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

ensure_file_service() {
  local service_path="/etc/systemd/system/${FILE_SERVICE_NAME}"
  mkdir -p "${PUBLIC_FILES_DIR}"
  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi
  cat > "${service_path}" <<EOF
[Unit]
Description=Xray OneClick Public Files Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server ${FILE_HTTP_PORT} --directory ${PUBLIC_FILES_DIR}
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${FILE_SERVICE_NAME}"
  systemctl is-active --quiet "${FILE_SERVICE_NAME}"
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
    echo "unzip not found, trying to install..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y unzip >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y unzip >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y unzip >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache unzip >/dev/null 2>&1 || true
    fi
  fi
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

if [[ -t 0 && -z "${INPUT_FILE}" && "${MENU_ENABLED}" == "1" ]]; then
  interactive_menu
fi

if [[ "${USE_SAVED_PORT}" == "1" ]]; then
  load_saved_start_port || prompt_start_port
elif [[ -t 0 ]]; then
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
  "--qr-bundle-zip" "${QR_BUNDLE_ZIP}"
  "--build-qr-bundle"
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

if [[ -n "${INPUT_FILE}" ]]; then
  persist_nodes_db_from_input "${INPUT_FILE}"
  save_start_port
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

if [[ "${AUTO_QR_FILE_SERVER}" == "1" ]] && [[ -f "${QR_BUNDLE_ZIP}" ]]; then
  if ensure_file_service; then
    echo "QR bundle download:"
    echo "http://${PUBLIC_HOST}:${FILE_HTTP_PORT}/$(basename "${QR_BUNDLE_ZIP}")"
  else
    echo "WARN: failed to start QR file server service ${FILE_SERVICE_NAME}" >&2
  fi
fi

echo "done."
if [[ "${KEEP_ARTIFACTS}" == "1" ]]; then
  echo "config: ${OUTPUT_CONFIG}"
  echo "mapping: ${OUTPUT_MAPPING}"
fi
