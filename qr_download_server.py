#!/usr/bin/env python3
import argparse
import html
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def read_key(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except Exception:
        return ""


class Handler(BaseHTTPRequestHandler):
    bundle_path: Path = Path("/opt/xray-oneclick/public/qr_bundle.zip")
    key_path: Path = Path("/opt/xray-oneclick/public/download.key")

    def _send_html(self, code: int, body: str) -> None:
        data = body.encode("utf-8", "ignore")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/index.html"):
            self._render_index("")
            return
        if parsed.path == "/download":
            self._handle_download(parsed.query)
            return
        self._send_html(404, "<h1>404</h1>")

    def _render_index(self, msg: str) -> None:
        bundle_name = html.escape(self.bundle_path.name)
        message = f"<p style='color:#b91c1c'>{html.escape(msg)}</p>" if msg else ""
        body = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>QR Bundle Download</title></head>
<body style="font-family:sans-serif;max-width:680px;margin:40px auto;line-height:1.6">
<h2>二维码压缩包下载</h2>
<p>请输入下载密钥后下载：<b>{bundle_name}</b></p>
{message}
<form method="get" action="/download">
  <input name="k" type="password" placeholder="输入下载密钥" style="width:340px;padding:8px" />
  <button type="submit" style="padding:8px 14px">下载</button>
</form>
</body></html>"""
        self._send_html(200, body)

    def _handle_download(self, query: str) -> None:
        key = read_key(self.key_path)
        req_key = parse_qs(query).get("k", [""])[0].strip()
        if not key or req_key != key:
            self._render_index("密钥错误或未设置，请重试。")
            return

        if not self.bundle_path.is_file():
            self._send_html(404, "<h1>二维码压缩包不存在</h1>")
            return

        size = self.bundle_path.stat().st_size
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Disposition", f'attachment; filename="{self.bundle_path.name}"')
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with self.bundle_path.open("rb") as f:
            while True:
                chunk = f.read(1024 * 256)
                if not chunk:
                    break
                self.wfile.write(chunk)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Key-protected QR bundle download server")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=18089)
    p.add_argument("--bundle", required=True, help="Path to qr_bundle.zip")
    p.add_argument("--key-file", required=True, help="Path to download key file")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    Handler.bundle_path = Path(args.bundle)
    Handler.key_path = Path(args.key_file)
    server = HTTPServer((args.host, args.port), Handler)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
