#!/usr/bin/env python3
"""Small, self-hosted sync API for Guanpan Pro's legacy web and native apps."""
from __future__ import annotations

import hmac
import json
import os
import secrets
import sqlite3
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
DB_PATH = DATA_DIR / "sync.sqlite3"
TOKEN_PATH = DATA_DIR / "auth-token"
WEB_DIR = Path(__file__).resolve().parent / "web"
MAX_BODY = int(os.environ.get("MAX_BODY_BYTES", str(256 * 1024 * 1024)))
WRITE_LOCK = threading.Lock()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def get_token() -> str:
    configured = os.environ.get("SYNC_TOKEN", "").strip()
    if configured:
        return configured
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    try:
        token = TOKEN_PATH.read_text(encoding="utf-8").strip()
        if token:
            return token
    except FileNotFoundError:
        pass
    token = secrets.token_urlsafe(32)
    fd = os.open(TOKEN_PATH, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(token + "\n")
    print("首次运行已生成同步口令。请在容器日志中查看一次性口令，或读取持久化目录中的 auth-token 文件。", flush=True)
    print(f"SYNC_TOKEN={token}", flush=True)
    return token


def connect() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(DB_PATH, timeout=30, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=FULL")
    db.execute("""CREATE TABLE IF NOT EXISTS latest (
        namespace TEXT PRIMARY KEY, revision INTEGER NOT NULL,
        updated_at TEXT NOT NULL, payload TEXT NOT NULL)""")
    db.execute("""CREATE TABLE IF NOT EXISTS history (
        namespace TEXT NOT NULL, revision INTEGER NOT NULL,
        updated_at TEXT NOT NULL, payload TEXT NOT NULL,
        PRIMARY KEY(namespace, revision))""")
    return db


def read_snapshot(namespace: str) -> dict:
    with connect() as db:
        row = db.execute("SELECT revision, updated_at, payload FROM latest WHERE namespace=?", (namespace,)).fetchone()
    if not row:
        return {"revision": 0, "updatedAt": None, "data": None}
    return {"revision": row["revision"], "updatedAt": row["updated_at"], "data": json.loads(row["payload"])}


def write_snapshot(namespace: str, payload: object, expected_revision: int | None = None) -> dict:
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    now = utc_now()
    with WRITE_LOCK, connect() as db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT revision FROM latest WHERE namespace=?", (namespace,)).fetchone()
        current = int(row["revision"]) if row else 0
        if expected_revision is not None and expected_revision != current:
            db.execute("ROLLBACK")
            return {"conflict": True, "revision": current}
        revision = current + 1
        db.execute("INSERT INTO latest(namespace,revision,updated_at,payload) VALUES(?,?,?,?) "
                   "ON CONFLICT(namespace) DO UPDATE SET revision=excluded.revision, updated_at=excluded.updated_at, payload=excluded.payload",
                   (namespace, revision, now, encoded))
        db.execute("INSERT INTO history(namespace,revision,updated_at,payload) VALUES(?,?,?,?)",
                   (namespace, revision, now, encoded))
        db.execute("DELETE FROM history WHERE namespace=? AND revision <= ?", (namespace, max(0, revision - 10)))
        db.execute("COMMIT")
    return {"conflict": False, "revision": revision, "updatedAt": now}


def contains_user_data(payload: object) -> bool:
    if not isinstance(payload, dict):
        return False
    data = payload.get("data") if isinstance(payload.get("data"), dict) else payload
    if isinstance(data, dict):
        for key in ("holdings", "ledger", "fundTransactions", "fundNAVHistory", "fundFeePolicies", "fundDCAPlans", "cashFlows", "snapshots", "quotes", "quoteAlerts", "allocationTargets", "tradePlans", "dayGridPlans", "legacyGridArchives", "legacyShadowArchives", "legacyDCAEvents", "legacySettingsArchives", "intradayBars", "dailyBars"):
            value = data.get(key)
            if isinstance(value, list) and value:
                return True
        cash = data.get("cash", 0)
        if isinstance(cash, (int, float)) and cash != 0:
            return True
        if data.get("cashLinkedByDefault") or data.get("appearance", "system") != "system" or data.get("quoteRefreshSeconds", 60) != 60:
            return True
        profile = data.get("investmentProfile")
        defaults = {"style": "swing", "risk": "bal", "maxPositionPercent": 35,
                    "horizon": "1-3个月", "premiumSensitive": True, "preference": "",
                    "avoid": "", "method": "", "goal": ""}
        if isinstance(profile, dict) and any(profile.get(key, value) != value for key, value in defaults.items()):
            return True
    for key in ("intradayBars", "dailyBars"):
        value = payload.get(key)
        if isinstance(value, list) and value:
            return True
    return False


class Handler(BaseHTTPRequestHandler):
    server_version = "GuanpanNAS/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:
        # Avoid logging request URLs because legacy clients pass the token as ?tok=.
        safe_path = urlparse(self.path).path
        print(f"{self.client_address[0]} {self.command} {safe_path} - {fmt % args}", flush=True)

    def send_json(self, status: int, payload: dict) -> None:
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()
        self.wfile.write(raw)

    def send_static(self, path: str) -> None:
        # The web app is a single self-contained HTML file. Serve only that file
        # to avoid exposing the container filesystem through path traversal.
        if path in ("/", "/index.html"):
            file_path = WEB_DIR / "index.html"
        else:
            self.send_json(404, {"err": "静态文件不存在"})
            return
        try:
            raw = file_path.read_bytes()
        except OSError:
            self.send_json(503, {"err": "网页版文件未打包"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(raw)

    def do_OPTIONS(self) -> None:
        self.send_json(200, {"ok": True})

    def authorized(self, body: dict | None = None) -> bool:
        expected = get_token()
        query = parse_qs(urlparse(self.path).query)
        supplied = self.headers.get("Authorization", "")
        if supplied.lower().startswith("bearer "):
            supplied = supplied[7:].strip()
        else:
            supplied = query.get("tok", [""])[0]
        if not supplied and body:
            supplied = str(body.get("tok", ""))
        return bool(supplied) and hmac.compare_digest(supplied.encode(), expected.encode())

    def read_body(self) -> dict:
        size = int(self.headers.get("Content-Length", "0"))
        if size <= 0 or size > MAX_BODY:
            raise ValueError("请求内容为空或超过大小限制")
        parsed = json.loads(self.rfile.read(size).decode("utf-8"))
        if not isinstance(parsed, dict):
            raise ValueError("请求必须是 JSON 对象")
        return parsed

    def do_GET(self) -> None:
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/":
            self.send_static(path)
            return
        if path == "/api/ping":
            # The legacy web app interprets an unauthenticated `ok:true` ping as
            # an行情代理 and rewrites every market URL to its /api proxy routes.
            # This container is the sync server, so keep that probe false while
            # still answering authenticated sync diagnostics with ok:true.
            if self.authorized():
                self.send_json(200, {"ok": True, "msg": "观盘 Pro NAS 同步服务"})
            else:
                self.send_json(200, {"ok": False, "service": "Guanpan Pro NAS Sync", "proxy": False})
            return
        if path not in ("/api/data", "/api/native/data", "/api/native/ping"):
            self.send_json(404, {"err": "接口不存在"})
            return
        if not self.authorized():
            self.send_json(401, {"err": "同步口令错误或未填写"})
            return
        if path == "/api/native/ping":
            self.send_json(200, {"ok": True, "service": "Guanpan Pro Native Sync", "revision": 0, "updatedAt": None, "data": None})
            return
        namespace = "legacy" if path == "/api/data" else "native"
        snap = read_snapshot(namespace)
        value = snap["data"] if namespace == "native" else (snap["data"] or {})
        self.send_json(200, {"ok": True, "data": value, "revision": snap["revision"], "updatedAt": snap["updatedAt"]})

    def do_POST(self) -> None:
        path = urlparse(self.path).path.rstrip("/")
        if path not in ("/api/data", "/api/native/data"):
            self.send_json(404, {"err": "接口不存在"})
            return
        try:
            body = self.read_body()
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
            self.send_json(400, {"err": str(error) or "JSON 格式无效"})
            return
        if not self.authorized(body):
            self.send_json(401, {"err": "同步口令错误或未填写"})
            return
        if path == "/api/data":
            payload = body.get("data")
            if not isinstance(payload, dict):
                self.send_json(400, {"err": "缺少网页账本 data"})
                return
            result = write_snapshot("legacy", payload)
            self.send_json(200, {"ok": True, "revision": result["revision"], "updatedAt": result["updatedAt"]})
            return
        payload = body.get("data")
        expected = body.get("expectedRevision")
        if not isinstance(payload, dict) or not isinstance(expected, int) or expected < 0:
            self.send_json(400, {"err": "需要原生账本 data 和非负 expectedRevision"})
            return
        current = read_snapshot("native")
        if contains_user_data(current["data"]) and not contains_user_data(payload) and not body.get("allowEmptyOverwrite", False):
            self.send_json(409, {"err": "服务器已有原生账本数据；拒绝空数据覆盖，请先下载，或在确认后明确允许覆盖。", "revision": current["revision"]})
            return
        result = write_snapshot("native", payload, expected_revision=expected)
        if result["conflict"]:
            self.send_json(409, {"err": "服务器版本已变化，请先重新下载并核对", "revision": result["revision"]})
            return
        self.send_json(200, {"ok": True, "revision": result["revision"], "updatedAt": result["updatedAt"]})

    def do_HEAD(self) -> None:
        self.send_json(200, {"ok": True})


def main() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    get_token()
    connect().close()
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8787"))
    print(f"Guanpan Pro NAS Sync listening on {host}:{port}", flush=True)
    ThreadingHTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
