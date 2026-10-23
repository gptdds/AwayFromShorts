#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""检查今天的学习目标是否都打过卡，给 AwayFromShorts 决定"要不要延长屏蔽"用。

数据源（2026-10-23 起 Gist 是中心仓库，云资料库降级为后备）：
  1. Gist 上的 checkin-ledger.json —— 台账权威（手机 StudyStore 整份推送）
     { "rev": n, "updated": "...",
       "goals": [ {id,name,unit,total,base,due} ],
       "recs":  [ {id,goalId,date,amount,ts} ] }
  2. 拉不到 / 解析失败 -> 回退读 WorkBuddy 云资料库（老链路兜底）
  3. 全都失败 -> fail-open：输出 error，调用方按"正常解锁"处理，绝不锁死

输出：
  stdout 一行 JSON，同时写 study.flag 给 watcher.ps1 读。
  { "date": "...", "allDone": bool, "active": n, "pending": n, "pendingNames": [...] }
"""

from __future__ import annotations

import json
import math
import os
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime

PY = sys.executable
# 面板（计划任务）拉起的进程没有这个变量，资料库脚本会退到另一套鉴权，
# 读能过、写直接 E_AUTH_FAILED。这里补默认值，子进程继承。
os.environ.setdefault("WORKBUDDY_CONFIG_DIR", os.path.join(os.path.expanduser("~"), ".workbuddy"))
LIB = r"C:/Program Files/WorkBuddy/resources/app.asar.unpacked/resources/plugins/workbuddy-builtin/skills/library"
DB_GOALS = "0bGK9KsEEiWn1pc5rpkt0x"
DB_LOGS = "cfTvN9M6VSQCFyrGJrWM9Z"
HERE = os.path.dirname(os.path.abspath(__file__))
FLAG = os.path.join(HERE, "study.flag")

# 与手机端 StudyGate.GIST_ID / PC 端 sync-state.json 是同一个同步 Gist
LEDGER_FILE = "checkin-ledger.json"


def call(payload: dict) -> dict:
    script = os.path.join(LIB, "database", "query_database_record.py")
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
        tmp = f.name
    # 面板进程的代码页可能是 936(GBK)，子进程默认按它输出 -> UTF-8 解码直接炸
    env = dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8")
    try:
        with open(tmp, "r", encoding="utf-8") as stdin:
            p = subprocess.run([PY, script, "--stdin"], stdin=stdin, env=env,
                               capture_output=True, text=True, encoding="utf-8",
                               errors="replace", timeout=60)
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


def day_of(v) -> str:
    s = str(scalar(v) or "")
    return s[:10] if len(s) >= 10 else ""


def days_left(deadline: str, today: str) -> int:
    """截止日到今天还有几天（已过期为负数，解析失败按 0 处理）。"""
    try:
        d = datetime.strptime(deadline[:10], "%Y-%m-%d").date()
        t = datetime.strptime(today[:10], "%Y-%m-%d").date()
        return (d - t).days
    except (TypeError, ValueError):
        return 0


def suggest_amount(remain: float, left: int) -> float:
    """建议打卡量 —— 必须和页面 app.js 的 suggestOf() 完全一致。

    页面里「立即打卡」用的就是这个数；手机端如果算出另一个数，
    同一天在两边打卡会得到不同结果，看起来像 bug。
    """
    if remain <= 0:
        return 0
    if left < 0:
        return math.ceil(remain)          # 已过期：一次补齐
    raw = remain / max(1, left + 1)
    if raw >= 1:
        return math.ceil(raw)             # 建议 25.1 个单词没有意义
    return round(raw * 10) / 10


def number(v, default: float = 0.0) -> float:
    try:
        return float(scalar(v) or default)
    except (TypeError, ValueError):
        return default


def gist_id() -> str:
    with open(os.path.join(HERE, "sync-state.json"), encoding="utf-8") as f:
        gid = json.load(f).get("gistId")
    if not gid:
        raise RuntimeError("sync-state.json 里没有 gistId")
    return gid


def fetch_ledger() -> dict | None:
    """拉 hub 台账（secret gist raw 免鉴权）。拿不到/解析不动返回 None -> 走云库后备。

    ★ 显式 ProxyHandler({})：本机不该有 http_proxy，但万一有残留环境变量，
      GitHub raw 会被黑洞掉（工程上踩过）。绕代理在代码里做，不靠剥环境变量。
    """
    try:
        url = ("https://gist.githubusercontent.com/gptdds/" + gist_id()
               + "/raw/" + LEDGER_FILE + "?t=" + str(int(datetime.now().timestamp() * 1000)))
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(url, timeout=20) as r:
            raw = r.read().decode("utf-8", "replace")
        obj = json.loads(raw)
        if isinstance(obj, dict) and isinstance(obj.get("goals"), list):
            return obj
    except Exception:  # noqa: BLE001
        pass
    return None



def local_view():
    """PC 面板的本地库(study-db.json) -> 台账口径; 没有可用本地库返回 None。

    ★ 2026-10-23 起 PC 面板是主力入口, 打卡只写本地文件。
      闸门必须读它, 否则"在 PC 上打完卡, 闸门照样锁死"。
    ★ 本地库存在时以它为准(而不是"并进台账"): 台账拉不到时旧逻辑会退到云端表,
      那里是过期数据, 会把已经打完的卡判成没打 -> 白锁一晚。
    """
    path = os.path.join(HERE, "study-db.json")
    try:
        with open(path, encoding="utf-8-sig") as f:
            store = json.load(f) or {}
    except (OSError, ValueError):
        return None
    if not isinstance(store, dict):
        return None

    goals = []
    for g in store.get("goals") or []:
        gid = str(g.get("目标ID") or "")
        name = str(g.get("目标名称") or "")
        try:
            total = float(g.get("总量") or 0)
        except (TypeError, ValueError):
            total = 0.0
        if not gid or not name or total <= 0:
            continue
        goals.append({"id": gid, "name": name,
                      "unit": str(g.get("单位") or "个"), "total": total,
                      "base": number(g.get("已完成量")), "due": str(g.get("截止日") or "")})
    if not goals:
        return None

    logs = []
    for r in store.get("logs") or []:
        rid = str(r.get("记录ID") or r.get("id") or "")
        gid = str(r.get("目标ID") or "")
        if not rid or not gid:
            continue
        logs.append({"id": rid, "goalId": gid,
                     "date": str(r.get("日期") or "")[:10],
                     "amount": number(r.get("完成量"))})
    return goals, logs


def merge_ledger(goals: list, logs: list, ledger: dict) -> tuple:
    """把台账并进本地库视图 —— 手机打的卡只存在于台账里, 不并进来 PC 就永远看不到。

    去重键: 目标用 id, 记录用「记录ID」(手机 r<ts>_<n>, 面板 id-<base36>-<rand>)。
    """
    have = {str(g.get("id") or "") for g in goals}
    for g in ledger.get("goals") or []:
        gid = str(g.get("id") or "")
        if not gid or gid in have:
            continue
        try:
            total = float(g.get("total") or 0)
        except (TypeError, ValueError):
            total = 0.0
        if total <= 0:
            continue
        goals.append({"id": gid, "name": str(g.get("name") or ""),
                      "unit": str(g.get("unit") or "个"), "total": total,
                      "base": number(g.get("base")), "due": str(g.get("due") or "")})
        have.add(gid)

    seen = {str(r.get("id") or "") for r in logs}
    for r in ledger.get("recs") or []:
        rid = str(r.get("id") or "")
        gid = str(r.get("goalId") or "")
        if not rid or not gid or rid in seen:
            continue
        logs.append({"id": rid, "goalId": gid,
                     "date": str(r.get("date") or "")[:10],
                     "amount": number(r.get("amount"))})
        seen.add(rid)
    return goals, logs


def main() -> int:
    today = datetime.now().strftime("%Y-%m-%d")
    result = {"date": today, "allDone": True, "active": 0, "pending": 0,
              "pendingNames": [], "goals": [],
              "checkedAt": datetime.now().strftime("%Y-%m-%d %H:%M")}
    pending_names = []
    try:
        local = local_view()
        ledger = fetch_ledger()
        if local is not None:
            src = "local"
            goals_raw, logs_raw = local
            if ledger is not None:
                goals_raw, logs_raw = merge_ledger(goals_raw, logs_raw, ledger)
        elif ledger is not None:
            src = "hub"
            goals_raw = ledger.get("goals") or []
            logs_raw = ledger.get("recs") or []
        else:
            src = "cloud-fallback"
            goals_raw = fetch_all(DB_GOALS)
            logs_raw = fetch_all(DB_LOGS)
        result["source"] = src

        if src in ("hub", "local"):
            # 本地库 / 台账都是明文键（goalId / amount / date），走的同一套统计
            done_by_goal = {}
            today_hit = set()
            for r in logs_raw:
                gid = str(r.get("goalId") or "")
                if not gid:
                    continue
                try:
                    amount = float(r.get("amount") or 0)
                except (TypeError, ValueError):
                    amount = 0.0
                done_by_goal[gid] = done_by_goal.get(gid, 0.0) + amount
                if str(r.get("date") or "")[:10] == today:
                    today_hit.add(gid)

            for g in goals_raw:
                gid = str(g.get("id") or "")
                name = str(g.get("name") or "")
                if not gid or not name:
                    continue
                total = float(g.get("total") or 0)
                base = float(g.get("base") or 0)
                if total <= 0:
                    continue
                done = base + done_by_goal.get(gid, 0.0)
                if done >= total:
                    continue
                result["active"] += 1
                hit = gid in today_hit
                result["goals"].append({
                    "id": gid,
                    "name": name,
                    "unit": str(g.get("unit") or "个"),
                    "total": round(total, 2),
                    "done": round(done, 2),
                    "todayHit": hit,
                    "suggest": suggest_amount(total - done,
                                              days_left(str(g.get("due") or ""), today)),
                })
                if not hit:
                    pending_names.append(name)
        else:
            # 老链路：云资料库的表格字段（记录ID/目标ID/日期/完成量...）
            done_by_goal = {}
            today_hit = set()
            for r in logs_raw:
                gid = str(scalar(r.get("目标ID")) or "")
                if not gid:
                    continue
                amount = number(r.get("完成量"))
                done_by_goal[gid] = done_by_goal.get(gid, 0.0) + amount
                if day_of(r.get("日期")) == today:
                    today_hit.add(gid)

            for g in goals_raw:
                gid = str(scalar(g.get("目标ID")) or "")
                name = str(scalar(g.get("目标名称")) or "")
                if not gid or not name:
                    continue
                total = number(g.get("总量"))
                base = number(g.get("已完成量"))
                if total <= 0:
                    continue
                done = base + done_by_goal.get(gid, 0.0)
                if done >= total:
                    continue          # 已经达成，不用打卡
                result["active"] += 1
                hit = gid in today_hit
                # 目标明细给手机端用：上滑打卡要选目标，光知道"还有 2 个"没法选
                row = {
                    "id": gid,
                    "name": name,
                    "unit": str(scalar(g.get("单位")) or "个"),
                    "total": round(total, 2),
                    "done": round(done, 2),
                    "todayHit": hit,
                    "suggest": suggest_amount(total - done,
                                              days_left(day_of(g.get("截止日")), today)),
                }
                result["goals"].append(row)
                if not hit:
                    pending_names.append(name)

        result["pending"] = len(pending_names)
        result["pendingNames"] = pending_names[:5]
        result["allDone"] = len(pending_names) == 0
    except Exception as e:  # noqa: BLE001
        result = {"date": today, "error": str(e)[:200], "goals": [],
                  "checkedAt": datetime.now().strftime("%Y-%m-%d %H:%M")}

    try:
        with open(FLAG, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False)
    except OSError:
        pass

    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
