#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""检查今天的学习目标是否都打过卡，给 AwayFromShorts 决定"要不要延长屏蔽"用。

数据源（2026-10-23 起 Gist 是中心仓库，云资料库降级为后备）：
  1. Gist 上的 checkin-ledger.json —— 台账权威（手机 StudyStore 整份推送）
     { "rev": n, "updated": "...",
       "goals": [ {id,name,unit,total,base,due} ],
       "recs":  [ {id,goalId,date,amount,ts} ] }
  2. 拉不到 / 解析失败 -> fail-open：输出 error，调用方按"正常解锁"处理
     （2026-10-24 起不再回退云端表，学习台已迁到 PC 本地）：输出 error，调用方按"正常解锁"处理，绝不锁死

输出：
  stdout 一行 JSON，同时写 study.flag 给 watcher.ps1 读。
  { "date": "...", "allDone": bool, "active": n, "pending": n, "pendingNames": [...],
    "lastHitAt": "YYYY-MM-DD HH:MM" }
  lastHitAt = 今天最后一笔打卡的本地时间(没有则空串)。PC 端 20:00 打卡罚时用它判
  "是不是 20:00 之后才补的卡"，与手机端 CheckinPenalty.missed() 同口径。
"""

from __future__ import annotations

import json
import math
import os
import sys
import urllib.request
from datetime import datetime

PY = sys.executable
# 面板（计划任务）拉起的进程没有这个变量，资料库脚本会退到另一套鉴权，
# 读能过、写直接 E_AUTH_FAILED。这里补默认值，子进程继承。
HERE = os.path.dirname(os.path.abspath(__file__))
FLAG = os.path.join(HERE, "study.flag")

# 与手机端 StudyGate.GIST_ID / PC 端 sync-state.json 是同一个同步 Gist
LEDGER_FILE = "checkin-ledger.json"


def days_left(deadline: str, today: str) -> int:
    """截止日到今天还有几天（已过期为负数，解析失败按 0 处理）。"""
    if not deadline:
        return 29  # No deadline: spread the remaining work over 30 days, like the phone.
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


def scalar(v):
    """云端表格字段带类型({text: ..}/{number: ..})，取裸值。本地库是裸值，直接返回。"""
    if isinstance(v, dict):
        for k in ("text", "number", "date", "checkbox"):
            if k in v:
                return v[k]
        return ""
    return v if v is not None else ""


def number(v, default: float = 0.0) -> float:
    try:
        return float(scalar(v) or default)
    except (TypeError, ValueError):
        return default


def hit_time(ts) -> str:
    """毫秒时间戳 -> 本地 'YYYY-MM-DD HH:MM'；缺失/异常返回空串。

    PC 端 20:00 打卡罚时要判「今天最后一笔卡是不是 20:00 之后才补的」,
    和手机端 CheckinPenalty.missed() 同口径。时间戳来自本地库的「时间戳」
    或 Gist 台账的 ts, 都是毫秒 epoch。
    """
    try:
        v = float(scalar(ts) or 0)
    except (TypeError, ValueError):
        return ""
    if v <= 0:
        return ""
    try:
        return datetime.fromtimestamp(v / 1000).strftime("%Y-%m-%d %H:%M")
    except (OSError, OverflowError, ValueError):
        return ""


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
        if g.get("已归档") or g.get("示例数据"):
            continue
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
                      "base": number(g.get("已完成量")), "daily": number(g.get("每日默认量")), "due": str(g.get("截止日") or "")})
    logs = []
    for r in store.get("logs") or []:
        rid = str(r.get("记录ID") or r.get("id") or "")
        gid = str(r.get("目标ID") or "")
        if not rid or not gid:
            continue
        logs.append({"id": rid, "goalId": gid,
                     "date": str(r.get("日期") or "")[:10],
                     "amount": number(r.get("完成量")),
                     "ts": number(r.get("时间戳"))})
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
                     "amount": number(r.get("amount")),
                     "ts": number(r.get("ts"))})
        seen.add(rid)
    return goals, logs


def main() -> int:
    today = datetime.now().strftime("%Y-%m-%d")
    result = {"date": today, "allDone": True, "active": 0, "pending": 0,
              "pendingNames": [], "goals": [], "lastHitAt": "",
              "checkedAt": datetime.now().strftime("%Y-%m-%d %H:%M")}
    pending_names = []
    try:
        local = local_view()
        ledger = fetch_ledger()
        if local is not None:
            src = "local"
            goals_raw, logs_raw = local
        elif ledger is not None:
            src = "hub"
            goals_raw = [g for g in ledger.get("goals", []) if not g.get("archived")]
            logs_raw = ledger.get("recs") or []
        else:
            # 本地库和台账都拿不到 -> fail-open，交给外层 except 输出 error
            raise RuntimeError("本地库与 Gist 台账都不可用")
        result["source"] = src

        if src in ("hub", "local"):
            # 本地库 / 台账都是明文键（goalId / amount / date），走的同一套统计
            done_by_goal = {}
            today_hit = set()
            now_ms = datetime.now().timestamp() * 1000
            last_hit_ms = 0.0
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
                    ts = number(r.get("ts"))
                    # 未来的时间戳(补记/时钟回拨)不参与"20:00 之后补卡"的判定
                    if 0 < ts <= now_ms:
                        last_hit_ms = max(last_hit_ms, ts)
            result["lastHitAt"] = hit_time(last_hit_ms)

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
                    "suggest": number(g.get("daily")) if 0 < number(g.get("daily")) <= 1e12 else suggest_amount(total - done,
                                              days_left(str(g.get("due") or ""), today)),
                })
                if not hit:
                    pending_names.append(name)
        result["pending"] = len(pending_names)
        result["pendingNames"] = pending_names[:5]
        result["allDone"] = len(pending_names) == 0
    except Exception as e:  # noqa: BLE001
        result = {"date": today, "error": str(e)[:200], "goals": [], "lastHitAt": "",
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
