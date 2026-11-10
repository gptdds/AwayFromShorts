#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一条命令跑完学习联动的三件事（供面板定时调用）。

    0. sync_ledger.py    PC 本地学习库 ↔ 手机 Gist 台账（三方合并）
    1. sync_activity.py  面板的使用统计 → 本地专注记录
    2. check_study.py    今天的学习目标是否都打卡 → study.flag（屏蔽闸门读它）
       ★ 2026-10-23 起台账读 Gist 中心的 checkin-ledger.json（手机 StudyStore 直推），
         云资料库降级为后备；apply_checkins.py 的"队列→代记"链路整体退役。
    3. push_gist.ps1     study.flag + studyHold → Gist（手机端学习闸门读它）
    4. hub_config.ps1    Gist 中心仓库的配置分节同步（PC 分节双向）

为什么合在一个进程里：面板每 15 分钟拉起一次，多个脚本并行会抢
同一个资料库 CLI（token 刷新 / 请求竞争），偶发"空输出"失败。串行跑最稳。
任何一步失败都不影响另一步，也不影响屏蔽本身。
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "study-sync.log")

# '"error": ""' 是脚本正常输出里一直带着的字段（旧 apply_checkins 就算成功也输出它），
# 只有非空才算失败 —— 只查 '"error"' 在不在会把成功的一轮误记成 FAIL。
_HAS_ERR = re.compile(r'"error"\s*:\s*"[^"]+')


def has_error_field(tail: str) -> bool:
    return bool(_HAS_ERR.search(tail or ""))

# (文件名, 解释器)；runner=None 用当前 python，"powershell" 用 PowerShell 跑 ps1
STEPS = (
    ("sync_ledger.py", None),
    ("sync_activity.py", None),
    ("check_study.py", None),
    ("push_gist.ps1", "powershell"),
    ("hub_config.ps1", "powershell"),
)
KEEP_LINES = 400


def log(line: str) -> None:
    text = datetime.now().strftime("%Y-%m-%d %H:%M:%S") + "  " + line
    print(text)
    try:
        old = []
        if os.path.exists(LOG):
            with open(LOG, encoding="utf-8", errors="replace") as f:
                old = f.read().splitlines()
        old.append(text)
        with open(LOG, "w", encoding="utf-8") as f:
            f.write("\n".join(old[-KEEP_LINES:]) + "\n")
    except OSError:
        pass


def main() -> int:
    # 面板进程的代码页可能是 936(GBK)，统一让子进程按 UTF-8 说话，避免解码炸掉
    os.environ["PYTHONUTF8"] = "1"
    os.environ["PYTHONIOENCODING"] = "utf-8"
    for name, runner in STEPS:
        path = os.path.join(HERE, name)
        if not os.path.exists(path):
            log("skip %s (not found)" % name)
            continue
        if runner == "powershell":
            ps = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
            cmd = [ps, "-NoProfile", "-NonInteractive",
                   "-ExecutionPolicy", "Bypass", "-File", path]
        else:
            cmd = [sys.executable, path]
        try:
            p = subprocess.run(cmd, capture_output=True,
                               text=True, encoding="utf-8", errors="replace",
                               env=dict(os.environ), timeout=180)
            out = [ln for ln in (p.stdout or "").strip().splitlines() if ln.strip()]
            tail = out[-1] if out else ""
            if p.returncode != 0 or not tail:
                err = (p.stderr or "").strip().splitlines()
                log("FAIL %s rc=%s %s" % (name, p.returncode,
                                          (err[-1] if err else tail or "no output")))
            elif "FAIL" in tail or has_error_field(tail):
                log("FAIL %s %s" % (name, tail))
            else:
                log("ok %s %s" % (name, tail))
        except Exception as e:  # noqa: BLE001
            log("FAIL %s %s" % (name, str(e)[:200]))
    return 0


if __name__ == "__main__":
    from sync_ledger import file_lock
    try:
        with file_lock(os.path.join(HERE, "study-run.lock")):
            sys.exit(main())
    except RuntimeError:
        print("STUDY_SYNC_ALREADY_RUNNING")
