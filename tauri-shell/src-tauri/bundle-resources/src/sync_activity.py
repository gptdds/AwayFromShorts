#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 AwayFromShorts 面板的活动统计(activity.json)同步到云端「专注记录」表。

数据来源：面板每 60 秒采样一次前台窗口，按天聚合到 activity.json：
    { days: { "YYYY-MM-DD": { apps: {进程: 分钟}, sites: {站点关键词: 分钟} } } }
sites 只统计浏览器窗口标题里命中娱乐站点关键词的时间，这就是面板「使用统计」里
那个娱乐时长，学习台读同一份数据，口径保持一致。

幂等：按「日期」比对云端，缺的补、变了的更新、没变化的不动。
本地是唯一事实来源，云端只是镜像，任何一次失败下次都能补上。

用法：
    python sync_activity.py             # 同步最近 14 天
    python sync_activity.py --days 45
    python sync_activity.py --dry-run
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

PY = sys.executable
# 面板（计划任务）拉起的进程没有这个变量，资料库脚本会退到另一套鉴权，
# 读能过、写直接 E_AUTH_FAILED。这里补默认值，子进程继承。
os.environ.setdefault("WORKBUDDY_CONFIG_DIR", os.path.join(os.path.expanduser("~"), ".workbuddy"))
LIB = (r"C:/Program Files/WorkBuddy/resources/app.asar.unpacked"
       r"/resources/plugins/workbuddy-builtin/skills/library")
DB_FOCUS = "v3qalVwAq3UxCQv7MGWK44"
HERE = os.path.dirname(os.path.abspath(__file__))
ACTIVITY = os.path.join(HERE, "activity.json")
CONFIG = os.path.join(HERE, "config.json")
LAST_RUN = os.path.join(HERE, "last-run.json")

QUERY = os.path.join(LIB, "database", "query_database_record.py")
BATCH_ADD = os.path.join(LIB, "database", "batch_add_database_records.py")
BATCH_UPDATE = os.path.join(LIB, "database", "batch_update_database_records.py")

GAME_HINTS = ("steam", "riot", "shipping", "valorant", "genshin", "ace-",
              "epicgames", "battle.net", "honkai", "zenless", "minecraft",
              "league", "wuthering", "原神", "三角洲")


def call(script: str, payload: dict) -> dict:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
        tmp = f.name
    # 面板进程的代码页可能是 936(GBK)，子进程默认按它输出 -> UTF-8 解码直接炸。
    # 强制子进程用 UTF-8 说话，输出再兜一层 errors=replace，任何情况都不至于解析失败。
    env = dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8")
    try:
        with open(tmp, "r", encoding="utf-8") as stdin:
            p = subprocess.run([PY, script, "--stdin"], stdin=stdin, env=env,
                               capture_output=True, text=True, encoding="utf-8",
                               errors="replace")
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    out = (p.stdout or "").strip()
    if not out:
        raise RuntimeError((p.stderr or "empty output").strip()[:300])
    line = out.splitlines()[-1]
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        raise RuntimeError(out[:300])


def flat(value):
    if isinstance(value, dict):
        for key in ("text", "number", "date", "checkbox"):
            if key in value:
                return value[key]
    return value


def read_json(path: str) -> dict:
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f) or {}
    except (OSError, ValueError):
        return {}


def unlock_hour(cfg: dict) -> int:
    """解锁时刻 = 屏蔽窗口的结束整点里最晚的那个（排除 00:00），默认 22。"""
    hours = []
    for w in ((cfg.get("schedule") or {}).get("windows") or []):
        try:
            h = int(str(w.get("end") or "").split(":")[0])
        except (TypeError, ValueError):
            continue
        if 0 < h < 24:
            hours.append(h)
    return max(hours) if hours else 22


def load_local(days: int, cfg: dict) -> list:
    data = read_json(ACTIVITY)
    all_days = data.get("days") or {}
    if not isinstance(all_days, dict):
        return []
    out = []
    for name in sorted(all_days.keys())[-days:]:
        d = all_days.get(name) or {}
        out.append({"date": name,
                    "apps": d.get("apps") or {},
                    "sites": d.get("sites") or {}})
    return out


def to_record(d: dict, cfg: dict, today: str, last_reason: str) -> dict:
    sites = {k: int(v or 0) for k, v in (d.get("sites") or {}).items() if int(v or 0) > 0}
    apps = {k: int(v or 0) for k, v in (d.get("apps") or {}).items() if int(v or 0) > 0}
    total_min = sum(sites.values())
    top = sorted(sites.items(), key=lambda x: -x[1])
    game_min = sum(m for k, m in apps.items()
                   if any(h in k.lower() for h in GAME_HINTS))
    detail = [{"domain": k, "minutes": m} for k, m in top[:8]]
    return {
        "日期": {"text": d["date"]},
        "状态": {"text": last_reason if d["date"] == today else ""},
        "解锁时刻": {"number": unlock_hour(cfg)},
        "娱乐秒数": {"number": total_min * 60},
        "活跃秒数": {"number": sum(apps.values()) * 60},
        "娱乐次数": {"number": 0},
        "主要站点": {"text": (top[0][0] if top else "")},
        "游戏分钟": {"number": game_min},
        "明细": {"text": json.dumps(detail, ensure_ascii=False)},
        "同步时间": {"text": datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")},
    }


def cloud_index() -> dict:
    idx, cursor, guard = {}, None, 0
    while guard < 50:
        guard += 1
        payload = {"database_id": DB_FOCUS, "page_size": 200}
        if cursor:
            payload["start_cursor"] = cursor
        data = call(QUERY, payload)
        for r in data.get("results") or []:
            rid = r.get("record_id") or r.get("_id") or r.get("id")
            date = flat(r.get("日期")) or ""
            if rid and date:
                idx[str(date)] = (rid, {k: flat(v) for k, v in r.items()
                                        if k not in ("_id", "id", "record_id")})
        cursor = data.get("nextCursor") or data.get("next_cursor")
        if not (data.get("hasMore") or data.get("has_more")) or not cursor:
            break
    return idx


SKIP_COMPARE = {"同步时间"}


def changed(old: dict, new: dict) -> bool:
    for k, v in new.items():
        if k in SKIP_COMPARE:
            continue
        if str(old.get(k, "")) != str(list(v.values())[0]):
            return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--days", type=int, default=45)
    args = ap.parse_args()

    cfg = read_json(CONFIG)
    today = datetime.now().strftime("%Y-%m-%d")
    last = read_json(LAST_RUN)
    last_reason = str(last.get("reason") or "") if str(last.get("time") or "")[:10] == today else ""

    local = load_local(args.days, cfg)
    if not local:
        print("SYNC_ACTIVITY_EMPTY activity.json 里没有数据")
        return 0

    # 面板「专注记录」读这份本地文件（study-db.json 里的 focus 只是迁移时的快照）。
    # 放在云同步之前：云端挂了本地也必须是最新的。
    try:
        rows = []
        for d in local:
            rec = to_record(d, cfg, today, last_reason)
            row = {"id": "focus-" + d["date"]}
            for k, v in rec.items():
                row[k] = list(v.values())[0] if isinstance(v, dict) and v else v
            rows.append(row)
        fp = os.path.join(HERE, "focus-local.json")
        with open(fp + ".tmp", "w", encoding="utf-8") as f:
            json.dump(rows, f, ensure_ascii=False)
        os.replace(fp + ".tmp", fp)
    except OSError:
        pass

    try:
        idx = cloud_index()
    except Exception as e:  # noqa: BLE001
        print("SYNC_ACTIVITY_FAIL 读取云端失败: %s" % e)
        return 1

    adds, updates, skips = [], [], 0
    for d in local:
        rec = to_record(d, cfg, today, last_reason)
        hit = idx.get(d["date"])
        if not hit:
            adds.append(rec)
        elif changed(hit[1], rec):
            updates.append({"record_id": hit[0], "properties": rec})
        else:
            skips += 1

    if args.dry_run:
        print("本地 %d 天 / 云端 %d 天 → 新增 %d, 更新 %d, 跳过 %d"
              % (len(local), len(idx), len(adds), len(updates), skips))
        print("DRY_RUN_OK")
        return 0

    try:
        # 这两个接口失败时是 stdout 返回 {"error": ...} 而 exit 0, 不检查就会"以为成功"
        if adds:
            r = call(BATCH_ADD, {"database_id": DB_FOCUS, "records": adds[:100]})
            if r.get("error"):
                raise RuntimeError("新增失败: %s" % r["error"])
        if updates:
            r = call(BATCH_UPDATE, {"database_id": DB_FOCUS, "records": updates[:100]})
            if r.get("error"):
                raise RuntimeError("更新失败: %s" % r["error"])
    except Exception as e:  # noqa: BLE001
        print("SYNC_ACTIVITY_FAIL 写入云端失败: %s" % e)
        return 1

    print("SYNC_ACTIVITY_OK 新增 %d / 更新 %d / 跳过 %d" % (len(adds), len(updates), skips))
    return 0


if __name__ == "__main__":
    sys.exit(main())
