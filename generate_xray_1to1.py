#!/usr/bin/env python3
import argparse
import base64
import concurrent.futures
import csv
import datetime
import ipaddress
import json
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import uuid
import zipfile
from dataclasses import dataclass
from pathlib import Path

try:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

    HAS_CRYPTOGRAPHY = True
except ImportError:
    HAS_CRYPTOGRAPHY = False


HOST_RE = re.compile(r"^[A-Za-z0-9.-]+$")


@dataclass
class SocksEntry:
    host: str
    port: int
    username: str
    password: str


def b64url_no_pad(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def generate_reality_keypair_from_xray(xray_bin: str) -> tuple[str, str]:
    try:
        proc = subprocess.run(
            [xray_bin, "x25519"], capture_output=True, text=True, check=False
        )
    except FileNotFoundError as exc:
        raise RuntimeError(
            f"xray binary not found for key generation: {xray_bin}"
        ) from exc

    if proc.returncode != 0:
        details = (proc.stderr or proc.stdout or "").strip() or "xray x25519 failed"
        raise RuntimeError(f"key generation failed: {details}")

    private_key = ""
    public_key = ""
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.lower().startswith("private key:"):
            private_key = line.split(":", 1)[1].strip()
        if line.lower().startswith("public key:"):
            public_key = line.split(":", 1)[1].strip()

    if not private_key or not public_key:
        raise RuntimeError("failed to parse xray x25519 output")
    return private_key, public_key


def generate_reality_keypair(xray_bin: str) -> tuple[str, str]:
    if HAS_CRYPTOGRAPHY:
        private_key = X25519PrivateKey.generate()
        public_key = private_key.public_key()
        private_raw = private_key.private_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PrivateFormat.Raw,
            encryption_algorithm=serialization.NoEncryption(),
        )
        public_raw = public_key.public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        return b64url_no_pad(private_raw), b64url_no_pad(public_raw)

    return generate_reality_keypair_from_xray(xray_bin)


def valid_host(host: str) -> bool:
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return bool(HOST_RE.match(host))


def parse_line(line: str, lineno: int) -> SocksEntry:
    parts = line.strip().split(":")
    if len(parts) != 4:
        raise ValueError(f"line {lineno}: must be host:port:username:password")
    host, port_raw, username, password = parts
    if not host or not valid_host(host):
        raise ValueError(f"line {lineno}: invalid host '{host}'")
    try:
        port = int(port_raw)
    except ValueError as exc:
        raise ValueError(f"line {lineno}: invalid port '{port_raw}'") from exc
    if not (1 <= port <= 65535):
        raise ValueError(f"line {lineno}: port out of range '{port}'")
    if not username:
        raise ValueError(f"line {lineno}: username cannot be empty")
    if not password:
        raise ValueError(f"line {lineno}: password cannot be empty")
    return SocksEntry(host=host, port=port, username=username, password=password)


def load_entries(path: str | None) -> list[SocksEntry]:
    raw_lines: list[str]
    if path:
        raw_lines = Path(path).read_text(encoding="utf-8").splitlines()
    else:
        raw_lines = sys.stdin.read().splitlines()
    entries: list[SocksEntry] = []
    seen: set[tuple[str, int, str]] = set()
    for lineno, line in enumerate(raw_lines, start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        entry = parse_line(line, lineno)
        dedup_key = (entry.host, entry.port, entry.username)
        if dedup_key in seen:
            raise ValueError(
                f"line {lineno}: duplicated socks endpoint/user {entry.host}:{entry.port}:{entry.username}"
            )
        seen.add(dedup_key)
        entries.append(entry)
    if not entries:
        raise ValueError("no valid socks entries found")
    return entries


def build_config(
    entries: list[SocksEntry],
    start_port: int,
    listen: str,
    server_names: list[str],
    dest: str,
    flow: str,
    per_inbound_key: bool,
    xray_bin: str,
) -> tuple[dict, list[dict]]:
    if start_port < 1 or start_port > 65535:
        raise ValueError("start-port must be in range 1..65535")
    end_port = start_port + len(entries) - 1
    if end_port > 65535:
        raise ValueError(
            f"port range overflow: start-port {start_port} + {len(entries)} entries exceeds 65535"
        )

    shared_private_key, shared_public_key = generate_reality_keypair(xray_bin)
    inbounds = []
    outbounds = []
    rules = []
    mapping = []

    for i, entry in enumerate(entries, start=1):
        inbound_port = start_port + i - 1
        in_tag = f"in-{i:03d}"
        out_tag = f"out-{i:03d}"
        client_uuid = str(uuid.uuid4())
        short_id = secrets.token_hex(8)
        if per_inbound_key:
            private_key, public_key = generate_reality_keypair(xray_bin)
        else:
            private_key, public_key = shared_private_key, shared_public_key

        inbound = {
            "tag": in_tag,
            "listen": listen,
            "port": inbound_port,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": client_uuid, "flow": flow}],
                "decryption": "none",
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": False,
                    "dest": dest,
                    "xver": 0,
                    "serverNames": server_names,
                    "privateKey": private_key,
                    "shortIds": [short_id],
                },
            },
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls", "quic"],
            },
        }

        outbound = {
            "tag": out_tag,
            "protocol": "socks",
            "settings": {
                "servers": [
                    {
                        "address": entry.host,
                        "port": entry.port,
                        "users": [{"user": entry.username, "pass": entry.password}],
                    }
                ]
            },
        }

        rule = {
            "type": "field",
            "inboundTag": [in_tag],
            "outboundTag": out_tag,
        }

        inbounds.append(inbound)
        outbounds.append(outbound)
        rules.append(rule)
        mapping.append(
            {
                "index": i,
                "inbound_tag": in_tag,
                "inbound_port": inbound_port,
                "outbound_tag": out_tag,
                "socks_host": entry.host,
                "socks_port": entry.port,
                "socks_user": entry.username,
                "uuid": client_uuid,
                "short_id": short_id,
                "reality_public_key": public_key,
            }
        )

    config = {
        "log": {"loglevel": "warning"},
        "inbounds": inbounds,
        "outbounds": outbounds
        + [
            {"tag": "direct", "protocol": "freedom", "settings": {}},
            {"tag": "block", "protocol": "blackhole", "settings": {}},
        ],
        "routing": {"domainStrategy": "AsIs", "rules": rules},
    }
    return config, mapping


def write_mapping_csv(path: Path, mapping: list[dict]) -> None:
    if not mapping:
        return
    fieldnames = list(mapping[0].keys())
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(mapping)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Xray config with 1:1 VLESS Reality inbounds -> SOCKS outbounds"
    )
    parser.add_argument(
        "-i",
        "--input",
        help="Input file. If omitted, read from stdin. Format: host:port:user:pass",
    )
    parser.add_argument(
        "-o",
        "--output",
        default="config.json",
        help="Output config path (default: config.json)",
    )
    parser.add_argument(
        "--mapping",
        default="mapping.csv",
        help="Output mapping CSV path (default: mapping.csv)",
    )
    parser.add_argument(
        "--start-port",
        type=int,
        default=20000,
        help="Inbound start port (default: 20000)",
    )
    parser.add_argument(
        "--listen",
        default="0.0.0.0",
        help="Inbound listen IP (default: 0.0.0.0)",
    )
    parser.add_argument(
        "--server-name",
        default="www.cloudflare.com",
        help="Reality serverName (default: www.cloudflare.com)",
    )
    parser.add_argument(
        "--dest",
        default="www.cloudflare.com:443",
        help="Reality dest (default: www.cloudflare.com:443)",
    )
    parser.add_argument(
        "--flow",
        default="xtls-rprx-vision",
        help="VLESS flow (default: xtls-rprx-vision)",
    )
    parser.add_argument(
        "--per-inbound-key",
        action="store_true",
        help="Generate a distinct Reality key pair for each inbound",
    )
    parser.add_argument(
        "--xray-bin",
        default="xray",
        help="Xray binary path for config test (default: xray)",
    )
    parser.add_argument(
        "--validate",
        action="store_true",
        help="Run xray -test -config on generated config",
    )
    parser.add_argument(
        "--deploy-target",
        help="Deploy to target config path atomically (writes .new, validates, then replace)",
    )
    parser.add_argument(
        "--reload-cmd",
        help="Optional reload command after successful deploy, e.g. 'systemctl reload xray'",
    )
    parser.add_argument(
        "--reload-strict",
        action="store_true",
        help="Treat reload failure as fatal (default: warning only)",
    )
    parser.add_argument(
        "--public-host",
        help="Public server domain/IP used in client share links",
    )
    parser.add_argument(
        "--fingerprint",
        default="chrome",
        help="Reality client fingerprint in share links (default: chrome)",
    )
    parser.add_argument(
        "--spx",
        default="/",
        help="Reality spiderX path in share links (default: /)",
    )
    parser.add_argument(
        "--remark-prefix",
        default="node",
        help="Share-link remark prefix (default: node)",
    )
    parser.add_argument(
        "--links-file",
        default="links.txt",
        help="Output unified VLESS links file (default: links.txt)",
    )
    parser.add_argument(
        "--no-link-files",
        action="store_true",
        help="Do not write share links to files",
    )
    parser.add_argument(
        "--print-links",
        action="store_true",
        help="Print generated share links to stdout",
    )
    parser.add_argument(
        "--print-qr",
        action="store_true",
        help="Print public QR code PNG links to stdout",
    )
    parser.add_argument(
        "--qr-size",
        type=int,
        default=300,
        help="QR image size in pixels (default: 300)",
    )
    parser.add_argument(
        "--qr-api-base",
        default="https://api.qrserver.com/v1/create-qr-code/",
        help="QR API base URL (default: https://api.qrserver.com/v1/create-qr-code/)",
    )
    parser.add_argument(
        "--qr-links",
        default="qr_links.txt",
        help="Output QR links path (default: qr_links.txt)",
    )
    parser.add_argument(
        "--qr-bundle-zip",
        default="qr_bundle.zip",
        help="Output zip path containing all QR PNG files (default: qr_bundle.zip)",
    )
    parser.add_argument(
        "--build-qr-bundle",
        action="store_true",
        help="Download all QR PNG files and pack into --qr-bundle-zip",
    )
    parser.add_argument(
        "--exit-ip-timeout",
        type=float,
        default=6.0,
        help="Timeout seconds for each SOCKS egress IP probe (default: 6.0)",
    )
    parser.add_argument(
        "--exit-ip-workers",
        type=int,
        default=20,
        help="Concurrent workers for SOCKS egress IP probing (default: 20)",
    )
    parser.add_argument(
        "--no-progress",
        action="store_true",
        help="Disable progress logs during generation",
    )
    return parser.parse_args()


def build_vless_link(
    host: str,
    port: int,
    client_uuid: str,
    flow: str,
    sni: str,
    public_key: str,
    short_id: str,
    fp: str,
    spx: str,
    remark: str,
) -> str:
    query = urllib.parse.urlencode(
        {
            "encryption": "none",
            "flow": flow,
            "security": "reality",
            "sni": sni,
            "fp": fp,
            "pbk": public_key,
            "sid": short_id,
            "spx": spx,
            "type": "tcp",
        },
        quote_via=urllib.parse.quote,
    )
    return f"vless://{client_uuid}@{host}:{port}?{query}#{urllib.parse.quote(remark)}"


def sanitize_remark(text: str) -> str:
    text = text.strip().replace(" ", "-")
    text = re.sub(r"[^A-Za-z0-9._-]+", "-", text)
    text = re.sub(r"-{2,}", "-", text).strip("-")
    return text or "node"


def query_country_by_ip(ip_or_host: str) -> str:
    providers = [
        (f"https://ipwho.is/{urllib.parse.quote(ip_or_host)}", "country"),
        (f"https://ipapi.co/{urllib.parse.quote(ip_or_host)}/json/", "country_name"),
    ]
    for url, key in providers:
        try:
            with urllib.request.urlopen(url, timeout=3.5) as resp:
                data = json.loads(resp.read().decode("utf-8", "ignore"))
        except Exception:
            continue
        value = str(data.get(key, "")).strip()
        if value and value.lower() not in {"none", "null"}:
            return value
    return "Unknown"


def detect_exit_ip_via_socks(entry: SocksEntry, timeout_sec: float) -> str:
    if timeout_sec <= 0:
        timeout_sec = 6.0
    curl_bin = shutil.which("curl")
    if not curl_bin:
        return ""
    proxy = f"socks5h://{entry.host}:{entry.port}"
    auth = f"{entry.username}:{entry.password}"
    providers = [
        "https://api64.ipify.org",
        "https://ifconfig.me/ip",
        "https://icanhazip.com",
        "https://ipinfo.io/ip",
    ]
    for url in providers:
        try:
            proc = subprocess.run(
                [
                    curl_bin,
                    "-4fsS",
                    "--max-time",
                    str(timeout_sec),
                    "--proxy",
                    proxy,
                    "--proxy-user",
                    auth,
                    url,
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        except Exception:
            continue
        if proc.returncode != 0:
            continue
        text = (proc.stdout or "").strip().splitlines()
        if not text:
            continue
        candidate = text[0].strip()
        try:
            ip = ipaddress.ip_address(candidate)
        except ValueError:
            continue
        if ip.version == 4:
            return str(ip)
    return ""


def detect_exit_ips_for_entries(
    entries: list[SocksEntry], timeout_sec: float, workers: int, show_progress: bool
) -> list[str]:
    if not entries:
        return []
    workers = max(1, min(workers, len(entries), 64))
    results = [""] * len(entries)
    total = len(entries)
    completed = 0
    if show_progress:
        print(f"[progress] 探测 SOCKS 出口IP: 0/{total}", file=sys.stderr, flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        future_map = {
            pool.submit(detect_exit_ip_via_socks, entry, timeout_sec): idx
            for idx, entry in enumerate(entries)
        }
        for fut in concurrent.futures.as_completed(future_map):
            idx = future_map[fut]
            try:
                results[idx] = fut.result() or ""
            except Exception:
                results[idx] = ""
            completed += 1
            if show_progress:
                if sys.stderr.isatty():
                    print(f"\r[progress] 探测 SOCKS 出口IP: {completed}/{total}", end="", file=sys.stderr, flush=True)
                else:
                    print(f"[progress] 探测 SOCKS 出口IP: {completed}/{total}", file=sys.stderr, flush=True)
    if show_progress and sys.stderr.isatty():
        print("", file=sys.stderr, flush=True)
    return results


def build_share_links(
    mapping: list[dict],
    entries: list[SocksEntry],
    public_host: str,
    flow: str,
    sni: str,
    fp: str,
    spx: str,
    remark_prefix: str,
    exit_ip_timeout: float,
    exit_ip_workers: int,
    show_progress: bool,
) -> list[str]:
    share_lines = []
    country_cache: dict[str, str] = {}
    exit_ips = detect_exit_ips_for_entries(
        entries=entries,
        timeout_sec=exit_ip_timeout,
        workers=exit_ip_workers,
        show_progress=show_progress,
    )
    if show_progress:
        ok_count = sum(1 for ip in exit_ips if ip)
        print(
            f"[progress] 出口IP探测完成: 成功 {ok_count}/{len(entries)}，失败 {len(entries)-ok_count}",
            file=sys.stderr,
            flush=True,
        )
    for idx, row in enumerate(mapping):
        exit_ip = exit_ips[idx] if idx < len(exit_ips) else ""
        if exit_ip and exit_ip not in country_cache:
            country_cache[exit_ip] = query_country_by_ip(exit_ip)
        country = country_cache.get(exit_ip, "Unknown") if exit_ip else "Unknown"
        row["socks_exit_ip"] = exit_ip
        row["socks_exit_country"] = country
        display_host = exit_ip if exit_ip else "unknown-exit-ip"

        remark = sanitize_remark(f"{display_host}-{country}-{remark_prefix}-{int(row['index']):03d}")
        link = build_vless_link(
            host=public_host,
            port=int(row["inbound_port"]),
            client_uuid=row["uuid"],
            flow=flow,
            sni=sni,
            public_key=row["reality_public_key"],
            short_id=row["short_id"],
            fp=fp,
            spx=spx,
            remark=remark,
        )
        share_lines.append(link)
    return share_lines


def write_share_links(links_file: Path, share_lines: list[str]) -> None:
    links_file.write_text("\n".join(share_lines) + "\n", encoding="utf-8")


def build_qr_links(vless_lines: list[str], qr_api_base: str, qr_size: int) -> list[str]:
    qr_lines: list[str] = []
    size = qr_size if qr_size > 0 else 300
    base = qr_api_base.strip() or "https://api.qrserver.com/v1/create-qr-code/"
    for idx, link in enumerate(vless_lines, start=1):
        parsed = urllib.parse.urlparse(link)
        remark = urllib.parse.unquote(parsed.fragment) if parsed.fragment else f"node-{idx:03d}"
        query = urllib.parse.urlencode(
            {"size": f"{size}x{size}", "data": link},
            quote_via=urllib.parse.quote,
        )
        qr_lines.append(f"{remark} {base}?{query}")
    return qr_lines


def write_qr_links(path: Path, qr_lines: list[str]) -> None:
    if not qr_lines:
        return
    path.write_text("\n".join(qr_lines) + "\n", encoding="utf-8")


def build_qr_bundle(
    qr_lines: list[str],
    bundle_zip_path: Path,
    share_lines: list[str] | None = None,
    links_filename: str = "links.txt",
) -> int:
    if not qr_lines:
        return 0
    bundle_zip_path.parent.mkdir(parents=True, exist_ok=True)
    success_count = 0
    used_stems: dict[str, int] = {}
    with tempfile.TemporaryDirectory(prefix="qr_bundle_") as tmpdir:
        tmpdir_path = Path(tmpdir)
        for i, line in enumerate(qr_lines, start=1):
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            remark_raw, qr_url = parts

            # Prefer the node remark embedded in the VLESS link itself.
            file_stem = ""
            try:
                parsed_qr = urllib.parse.urlparse(qr_url)
                query_map = urllib.parse.parse_qs(parsed_qr.query)
                link_raw = query_map.get("data", [""])[0]
                if link_raw:
                    link_parsed = urllib.parse.urlparse(link_raw)
                    if link_parsed.fragment:
                        file_stem = sanitize_remark(urllib.parse.unquote(link_parsed.fragment))
            except Exception:
                file_stem = ""

            if not file_stem:
                file_stem = sanitize_remark(remark_raw) or f"node-{i:03d}"

            dup_count = used_stems.get(file_stem, 0) + 1
            used_stems[file_stem] = dup_count
            final_stem = file_stem if dup_count == 1 else f"{file_stem}-{dup_count}"
            file_path = tmpdir_path / f"{final_stem}.png"
            try:
                with urllib.request.urlopen(qr_url, timeout=8) as resp:
                    content = resp.read()
                if not content:
                    continue
                file_path.write_bytes(content)
                success_count += 1
            except Exception:
                continue

        if share_lines:
            links_name = sanitize_remark(links_filename).replace("-", "_")
            if not links_name.lower().endswith(".txt"):
                links_name = f"{links_name}.txt"
            links_path = tmpdir_path / links_name
            links_path.write_text("\n".join(share_lines) + "\n", encoding="utf-8")

        with zipfile.ZipFile(bundle_zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            for png_file in sorted(tmpdir_path.glob("*.png")):
                zf.write(png_file, arcname=png_file.name)
            if share_lines:
                zf.write(links_path, arcname=links_path.name)
    return success_count


def run_validate(xray_bin: str, config_path: Path) -> None:
    cmd = [xray_bin, "-test", "-config", str(config_path)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise RuntimeError(
            f"validation failed: xray binary not found: {xray_bin}. "
            "Set --xray-bin /path/to/xray or XRAY_BIN env."
        ) from exc
    if proc.returncode != 0:
        stderr = (proc.stderr or "").strip()
        stdout = (proc.stdout or "").strip()
        details = stderr or stdout or "unknown xray error"
        raise RuntimeError(f"validation failed: {details}")


def deploy_config(
    config: dict,
    deploy_target: Path,
    xray_bin: str,
    reload_cmd: str | None,
    reload_strict: bool,
) -> None:
    deploy_target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", suffix=".json", prefix="xray_deploy_", dir=str(deploy_target.parent), delete=False
    ) as tmp_file:
        tmp_path = Path(tmp_file.name)
    tmp_path.write_text(json.dumps(config, indent=2), encoding="utf-8")

    try:
        run_validate(xray_bin, tmp_path)
    except Exception:
        try:
            tmp_path.unlink(missing_ok=True)
        finally:
            raise

    if deploy_target.exists():
        ts = datetime.datetime.utcnow().strftime("%Y%m%d%H%M%S")
        backup = deploy_target.with_suffix(deploy_target.suffix + f".bak.{ts}")
        shutil.copy2(deploy_target, backup)
        print(f"backup: {backup}")

    os_replace_error = None
    try:
        tmp_path.replace(deploy_target)
    except OSError as exc:
        os_replace_error = exc

    if os_replace_error is not None:
        raise RuntimeError(
            f"failed to atomically replace {deploy_target}: {os_replace_error}"
        )

    print(f"deployed: {deploy_target}")

    if reload_cmd:
        proc = subprocess.run(reload_cmd, shell=True, text=True, capture_output=True)
        if proc.returncode != 0:
            details = (proc.stderr or proc.stdout or "").strip() or "reload command failed"
            if reload_strict:
                raise RuntimeError(f"reload failed: {details}")
            print(f"WARN: reload failed: {details}", file=sys.stderr)
            return
        print("reload: success")


def main() -> int:
    args = parse_args()
    try:
        entries = load_entries(args.input)
        config, mapping = build_config(
            entries=entries,
            start_port=args.start_port,
            listen=args.listen,
            server_names=[args.server_name],
            dest=args.dest,
            flow=args.flow,
            per_inbound_key=args.per_inbound_key,
            xray_bin=args.xray_bin,
        )
    except (ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    output_path = Path(args.output)
    output_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    share_lines: list[str] = []
    qr_lines: list[str] = []
    qr_bundle_count = 0
    if args.public_host:
        if not args.no_progress:
            print("[progress] 开始生成分享链接...", file=sys.stderr, flush=True)
        share_lines = build_share_links(
            mapping=mapping,
            entries=entries,
            public_host=args.public_host,
            flow=args.flow,
            sni=args.server_name,
            fp=args.fingerprint,
            spx=args.spx,
            remark_prefix=args.remark_prefix,
            exit_ip_timeout=args.exit_ip_timeout,
            exit_ip_workers=args.exit_ip_workers,
            show_progress=not args.no_progress,
        )
        qr_lines = build_qr_links(
            vless_lines=share_lines,
            qr_api_base=args.qr_api_base,
            qr_size=args.qr_size,
        )
        if not args.no_progress:
            print("[progress] 链接与二维码索引已生成", file=sys.stderr, flush=True)
        if not args.no_link_files:
            write_share_links(links_file=Path(args.links_file), share_lines=share_lines)
            write_qr_links(Path(args.qr_links), qr_lines)
        if args.build_qr_bundle:
            if not args.no_progress:
                print("[progress] 正在打包二维码与链接文件...", file=sys.stderr, flush=True)
            qr_bundle_count = build_qr_bundle(
                qr_lines=qr_lines,
                bundle_zip_path=Path(args.qr_bundle_zip),
                share_lines=share_lines,
                links_filename=Path(args.links_file).name,
            )
            if not args.no_progress:
                print("[progress] 二维码压缩包已生成", file=sys.stderr, flush=True)
    write_mapping_csv(Path(args.mapping), mapping)

    try:
        if args.validate:
            run_validate(args.xray_bin, output_path)
            print("validate: success")

        if args.deploy_target:
            deploy_config(
                config=config,
                deploy_target=Path(args.deploy_target),
                xray_bin=args.xray_bin,
                reload_cmd=args.reload_cmd,
                reload_strict=args.reload_strict,
            )
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    print(f"generated: {output_path} ({len(mapping)} inbounds)")
    print(f"generated: {args.mapping}")
    if args.public_host:
        if not args.no_link_files:
            print(f"generated: {args.links_file}")
            print(f"generated: {args.qr_links}")
        if args.build_qr_bundle:
            print(f"generated: {args.qr_bundle_zip} ({qr_bundle_count} png + {Path(args.links_file).name})")
        if args.print_links:
            print("=== unified vless links ===")
            for link in share_lines:
                print(link)
        if args.print_qr:
            print("=== QR PNG public links ===")
            for line in qr_lines:
                print(line)
    else:
        print("share links skipped: set --public-host to generate client links")
    if mapping:
        print(f"reality public key: {mapping[0]['reality_public_key']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
