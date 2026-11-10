#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把手机上的打卡请求补记进学习台（手机 -> Gist 队列 -> 这里 -> 打卡记录表）。

## 为什么要经过这一层

学习台的数据只有 WorkBuddy 宿主能写（页面里的 `__SMART_PAGE__.database` 靠
postMessage 跟宿主通信，宿主那边才持有登录态）。手机 App 没有这个身份，
所以它只能把"我要给 X 目标记 Y 个"写进 Gist，由 PC 这边代为落库。

## 幂等

手机的每次打卡都带一个本地生成的 localId，落库时直接写进「记录ID」。
每轮先扫一遍打卡表已有的「记录ID」，已经记过的直接跳过 ——
重跑、半路失败、队列没删干净，都不会重复记账。

## 队列文件

Gist 上的 `checkin-queue.json`：
    {"items":[{"id":"ck_...","goalId":"...","amount":20,"unit":"个",
               "date":"2026-10-23","ts":1759000000000}]}

处理成功的条目从队列里删掉；失败的留下，下一轮重试。
本地同时留一份快照 checkin-queue.local.json，给 push_gist.ps1 统计"待记账几条用。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta

PY = sys.executable
os.environ.setdefault("WORKBUDDY_CONFIG_DIR", os.path.join(os.path.expanduser("~"), ".workbuddy"))
LIB = r"C:/Program Files/WorkBuddy/resources/app.asar.unpacked/resources/plugins/workbuddy-builtin/skills/library"
DB_LOGS = "cfTvN9M6VSQCFyrGJrWM9Z"
QUEUE_FILE = "checkin-queue.json"

HERE = os.path.dirname(os.path.abspath(__file__))
SNAP = os.path.join(HERE, "checkin-queue.local.json")


# ---------- 学习台 ----------

def call(payload: dict) -> dict:
    script = os.path.join(LIB, "database", "query_database_record.py")
    return _run(script, payload)


def add_logs(records: list) -> dict:
    script = os.path.join(LIB, "database", "batch_add_database_records.py")
    return _run(script, {"database_id": DB_LOGS, "records": records})


def _run(script: str, payload: dict) -> dict:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
        tmp = f.name
    env = dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8")
    try:
        with open(tmp, "r", encoding="utf-8") as stdin:
            p = subprocess.run([PY, script, "--stdin"], stdin=stdin, env=env,
                               capture_output=True, text=True, encoding="utf-8",
                               errors="replace", timeout=90)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    out = (p.stdout or "").strip()
    if not out:
        raise RuntimeError((p.stderr or "empty output").strip()[:200])
    return json.loads(out.splitlines()[-1])


def fetch_all(database_id: str) -> list:
    rows, cursor, guard = [], None, 0
    while guard < 50:
        guard += 1
        payload = {"database_id": database_id, "page_size": 200}
        if cursor:
            payload["start_cursor"] = cursor
        data = call(payload)
        rows.extend(data.get("results") or [])
        cursor = data.get("next_cursor") or data.get("nextCursor")
        if not (data.get("has_more") or data.get("hasMore")) or not cursor:
            break
    return rows


def scalar(v):
    if isinstance(v, dict):
        for k in ("text", "number", "date", "checkbox"):
            if k in v:
                return v[k]
        return ""
    return v if v is not None else ""


# ---------- Gist ----------

def token() -> str:
    """走 DPAPI 解出 token（和 push_gist.ps1 用的是同一份）。

    ★ 注意两个坑：
      1. ConvertFrom-SecureString 存出来的是 **hex**，不是 base64；
      2. SecureString 内部是 UTF-16LE，解密出来的字节得按 utf-16-le 解。
    """
    import base64
    import ctypes
    from ctypes import wintypes

    enc_path = os.path.join(HERE, "github-token.enc")
    with open(enc_path, "r", encoding="utf-8") as f:
        enc = f.read().strip()
    try:
        blob = bytes.fromhex(enc)
    except ValueError:
        blob = base64.b64decode(enc)

    class DATA_BLOB(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    def blob_in(data: bytes) -> DATA_BLOB:
        buf = ctypes.create_string_buffer(data, len(data))
        return DATA_BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))

    crypt32 = ctypes.windll.crypt32
    out = DATA_BLOB()
    if not crypt32.CryptUnprotectData(ctypes.byref(blob_in(blob)), None, None, None, None, 0,
                                      ctypes.byref(out)):
        raise RuntimeError("DPAPI 解密失败")
    raw = ctypes.string_at(out.pbData, out.cbData)
    ctypes.windll.kernel32.LocalFree(out.pbData)
    return raw.decode("utf-16-le", "replace").rstrip("\x00").strip()


def gh(path: str, method: str = "GET", body: dict | None = None) -> dict:
    import urllib.request

    gist_id = json.load(open(os.path.join(HERE, "sync-state.json"), encoding="utf-8")).get("gistId")
    if not gist_id:
        raise RuntimeError("sync-state.json 里没有 gistId")
    url = "https://api.github.com/gists/" + gist_id + path
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "token " + token())
    req.add_header("User-Agent", "AwayFromShorts-PC")
    req.add_header("Accept", "application/vnd.github+json")
    if data is not None:
        req.add_header("Content-Type", "application/json; charset=utf-8")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=25) as r:
        raw = r.read().decode("utf-8", "replace")
    return json.loads(raw) if raw else {}


def read_queue() -> list:
    try:
        info = gh("")
    except Exception:
        return []
    files = info.get("files") or {}
    f = files.get(QUEUE_FILE)
    if not f:
        return []
    content = f.get("content")
    if content is None and f.get("truncated"):
        # 文件太大时 API 不回内容，得走 raw_url
        import urllib.request
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(f["raw_url"], timeout=25) as r:
            content = r.read().decode("utf-8", "replace")
    try:
        obj = json.loads(content or "{}")
    except Exception:
        return []
    items = obj.get("items")
    return [x for x in items if isinstance(x, dict)] if isinstance(items, list) else []


def write_queue(items: list) -> None:
    payload = json.dumps({"items": items, "at": now_str()}, ensure_ascii=False)
    gh("", "PATCH", {"files": {QUEUE_FILE: {"content": payload}}})


def snapshot(items: list, note: str) -> None:
    try:
        with open(SNAP, "w", encoding="utf-8") as f:
            json.dump({"items": items, "at": now_str(), "note": note}, f, ensure_ascii=False)
    except OSError:
        pass


def now_str() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M")


# ---------- 主流程 ----------

def main() -> int:
    result = {"done": 0, "skipped": 0, "failed": 0, "left": 0,
              "checkedAt": now_str(), "error": ""}
    items = read_queue()
    if not items:
        snapshot([], "empty")
        print(json.dumps(result, ensure_ascii=False))
        return 0

    try:
        existing = set()
        for r in fetch_all(DB_LOGS):
            rid = str(scalar(r.get("记录ID")) or "")
            if rid:
                existing.add(rid)

        # 日期兜底：只允许"今天"和"最近 7 天补记"，其余按今天算。
        # 和页面上的规则一致 —— 手机本地时间乱掉也不会写出未来日期的记录。
        today = datetime.now().date()
        earliest = (today - timedelta(days=6)).isoformat()

        records, handled = [], set()
        for it in items:
            lid = str(it.get("id") or "").strip()
            gid = str(it.get("goalId") or "").strip()
            try:
                amount = float(it.get("amount") or 0)
            except (TypeError, ValueError):
                amount = 0.0
            if not lid or not gid or amount <= 0:
                result["failed"] += 1
                if lid:
                    handled.add(lid)
                continue              # 坏数据：不重试，直接丢（留着只会每轮空转）
            if lid in existing:
                result["skipped"] += 1
                handled.add(lid)      # 已经记过，从队列里清掉
                continue
            d = str(it.get("date") or "")[:10]
            if not d or d > today.isoformat() or d < earliest:
                d = today.isoformat()
            try:
                ts = int(it.get("ts") or 0)
            except (TypeError, ValueError):
                ts = 0
            records.append({
                "记录ID": {"text": lid},
                "目标ID": {"text": gid},
                "日期": {"date": d},
                "完成量": {"number": amount},
                "补记": {"checkbox": d < today.isoformat()},
                "时间戳": {"number": ts or int(datetime.now().timestamp() * 1000)},
                "示例数据": {"checkbox": False},
            })
            handled.add(lid)

        if records:
            # 接口单次上限 100 条
            for i in range(0, len(records), 100):
                add_logs(records[i:i + 100])
            result["done"] = len(records)

        left = [x for x in items if str(x.get("id") or "").strip() not in handled]
        result["left"] = len(left)
        try:
            write_queue(left)
        except Exception as e:  # noqa: BLE001
            # 写不回队列不该让整轮失败：记录已经进库了，下一轮靠 localId 幂等跳过
            result["error"] = "队列回写失败: " + str(e)[:120]
        snapshot(left, "applied %d" % result["done"])
    except Exception as e:  # noqa: BLE001
        result["error"] = str(e)[:200]
        snapshot(items, "failed")
        print(json.dumps(result, ensure_ascii=False))
        return 1

    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
