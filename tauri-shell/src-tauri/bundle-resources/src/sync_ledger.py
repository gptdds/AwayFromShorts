"""Synchronize the local study database and the shared phone ledger.

Keep a common baseline so edits, archives and deletions propagate instead of
reviving old records. Unknown local fields (notes, colors, minutes) survive.
"""
from __future__ import annotations

import contextlib
import copy
import ctypes
from ctypes import wintypes
import base64
import json
import os
import re
import sys
import time
import urllib.request
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
STORE = os.environ.get('AFS_STUDY_DB', os.path.join(HERE, 'study-db.json'))
STATE = os.path.join(os.path.dirname(STORE), 'ledger-sync-state.json')
LEDGER_FILE = 'checkin-ledger.json'
GOAL_FIELDS = {'name': '目标名称', 'unit': '单位', 'total': '总量',
               'base': '已完成量', 'due': '截止日', 'archived': '已归档'}
REC_FIELDS = {'goalId': '目标ID', 'date': '日期', 'amount': '完成量', 'ts': '时间戳'}

def read_json(path, default=None):
    try:
        with open(path, encoding='utf-8-sig') as f:
            return json.load(f)
    except FileNotFoundError:
        return copy.deepcopy(default)

def atomic_json(path, obj):
    tmp = path + '.tmp-' + str(os.getpid())
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)

@contextlib.contextmanager
def file_lock(path):
    # FileShare.None in webui.ps1 uses the same file; hold only during local IO.
    import msvcrt
    deadline = time.monotonic() + 10
    while True:
        try:
            f = open(path, 'a+b')
            f.seek(0)
            msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
            break
        except OSError:
            if 'f' in locals():
                f.close()
            if time.monotonic() >= deadline:
                raise RuntimeError('学习数据正在写入，请稍后重试')
            time.sleep(.05)
    try:
        yield
    finally:
        f.seek(0)
        msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)
        f.close()

def token():
    with open(os.path.join(HERE, 'github-token.enc'), encoding='utf-8-sig') as f:
        enc = f.read().strip()
    try:
        raw = bytes.fromhex(enc)
    except ValueError:
        raw = base64.b64decode(enc)
    class Blob(ctypes.Structure):
        _fields_ = [('size', wintypes.DWORD), ('data', ctypes.POINTER(ctypes.c_char))]
    buf = ctypes.create_string_buffer(raw)
    src = Blob(len(raw), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char)))
    dst = Blob()
    if not ctypes.windll.crypt32.CryptUnprotectData(ctypes.byref(src), None, None, None, None, 0, ctypes.byref(dst)):
        raise RuntimeError('无法读取本机同步凭据')
    try:
        raw = ctypes.string_at(dst.data, dst.size)
    finally:
        ctypes.windll.kernel32.LocalFree.argtypes = [ctypes.c_void_p]
        ctypes.windll.kernel32.LocalFree(dst.data)
    for encoding in ('utf-16-le', 'utf-8'):
        clean = ''.join(c for c in raw.decode(encoding, 'ignore') if 32 <= ord(c) < 127)
        match = re.search(r'(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})', clean)
        if match:
            return match.group(1)
    raise RuntimeError('同步凭据格式无效，请重新登录')

def request(method='GET', ledger=None):
    gid = os.environ.get('AFS_GIST_ID') or read_json(os.path.join(HERE, 'sync-state.json'), {}).get('gistId')
    if not gid:
        raise RuntimeError('请先在账号/同步中登录')
    data = None if ledger is None else json.dumps({'files': {LEDGER_FILE: {'content': json.dumps(ledger, ensure_ascii=False)}}}, ensure_ascii=False).encode('utf-8')
    req = urllib.request.Request('https://api.github.com/gists/' + gid, data=data, method=method,
        headers={'Authorization': 'token ' + token(), 'User-Agent': 'AwayFromShorts-PC',
                 'Accept': 'application/vnd.github+json', 'Content-Type': 'application/json; charset=utf-8'})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=25) as r:
        gist = json.load(r)
    entry = gist.get('files', {}).get(LEDGER_FILE)
    if not entry:
        raise RuntimeError('云端没有学习台账，暂不覆盖任何数据')
    content = entry.get('content')
    if entry.get('truncated'):
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(entry['raw_url'], timeout=25) as r:
            content = r.read().decode('utf-8')
    obj = json.loads(content)
    if not isinstance(obj.get('goals'), list) or not isinstance(obj.get('recs'), list):
        raise RuntimeError('云端台账格式无效，暂不覆盖任何数据')
    return obj

def index(rows):
    return {str(r['id']): r for r in rows if r.get('id')}

def merge_rows(local, remote, base):
    """Three-way merge; deletion wins, simultaneous field edits prefer local."""
    lm, rm, bm = index(local), index(remote), index(base or [])
    out = []
    for key in dict.fromkeys(list(rm) + list(lm)):
        l, r, b = lm.get(key), rm.get(key), bm.get(key)
        if b is not None and (l is None or r is None):
            continue
        if l is None or r is None:
            out.append(copy.deepcopy(r if l is None else l))
        elif b is None:
            out.append(dict(l, **r))  # first contact: hub is authoritative
        else:
            merged = dict(r)
            for field, value in l.items():
                if value != b.get(field):
                    merged[field] = value
            out.append(merged)
    return out

def local_ledger(store):
    result = {'goals': [], 'recs': []}
    for table, target, fields, idfield in [('goals', 'goals', GOAL_FIELDS, '目标ID'), ('logs', 'recs', REC_FIELDS, '记录ID')]:
        for row in store.get(table, []):
            if row.get('示例数据'):
                continue
            obj = {'id': row.get(idfield) or row.get('id')}
            for key, field in fields.items():
                if field in row:
                    obj[key] = row[field]
            if target == 'goals':
                obj.setdefault('archived', False)
            else:
                obj.setdefault('ts', 0)
            result[target].append(obj)
    return result

def merge(store, remote, baseline=None):
    local = local_ledger(store)
    if baseline is None:
        # Imported rows no longer in the phone snapshot were deleted there.
        for table, target, idfield in [('goals', 'goals', '目标ID'), ('logs', 'recs', '记录ID')]:
            imported = {str(r.get(idfield)) for r in store.get(table, []) if str(r.get('id', '')).startswith(('lg-', 'lr-'))}
            remote_ids = set(index(remote[target]))
            local[target] = [r for r in local[target] if r['id'] not in imported or r['id'] in remote_ids]
    merged = dict(remote)
    for target in ('goals', 'recs'):
        merged[target] = merge_rows(local[target], remote[target], None if baseline is None else baseline.get(target, []))
    new_store = copy.deepcopy(store)
    for table, target, fields, idfield, prefix in [('goals', 'goals', GOAL_FIELDS, '目标ID', 'lg-'), ('logs', 'recs', REC_FIELDS, '记录ID', 'lr-')]:
        old = {str(r.get(idfield) or r.get('id')): r for r in store.get(table, [])}
        rows = []
        for obj in merged[target]:
            row = dict(old.get(obj['id'], {'id': prefix + obj['id'], idfield: obj['id'], '示例数据': False}))
            for key, field in fields.items():
                if key in obj:
                    row[field] = obj[key]
            rows.append(row)
        rows.extend(r for r in store.get(table, []) if r.get('示例数据'))
        new_store[table] = rows
    return new_store, merged

def synchronize():
    with file_lock(STORE + '.sync.lock'):
        remote = request()
        # Download again just before a write to retain concurrent phone additions.
        for attempt in range(3):
            with file_lock(STORE + '.lock'):
                store = read_json(STORE)
                baseline = read_json(STATE) if store is not None else None
                if store is None:
                    store = {'goals': [], 'logs': []}
                if not isinstance(store.get('goals'), list) or not isinstance(store.get('logs'), list):
                    raise RuntimeError('本机学习库格式无效，暂不覆盖任何数据')
                new_store, merged = merge(store, remote, baseline)
                changed_cloud = any(merged[k] != remote[k] for k in ('goals', 'recs'))
                if changed_cloud:
                    latest = request()
                    if any(latest[k] != remote[k] for k in ('goals', 'recs')):
                        remote = latest
                        continue
                    merged['rev'] = int(latest.get('rev', 0)) + 1
                    merged['updated'] = datetime.now().strftime('%Y-%m-%d %H:%M')
                    confirmed = request('PATCH', merged)
                    if any(confirmed[k] != merged[k] for k in ('goals', 'recs')):
                        raise RuntimeError('云端写入校验失败，将在下一轮重试')
                if new_store != store:
                    if not os.path.exists(STORE + '.before-sync.json'):
                        atomic_json(STORE + '.before-sync.json', store)
                    atomic_json(STORE, new_store)
                atomic_json(STATE, merged)
                result = {'ok': True, 'goals': len(merged['goals']), 'records': len(merged['recs']), 'pushed': changed_cloud, 'updated': datetime.now().isoformat(timespec='seconds')}
                atomic_json(os.path.join(HERE, 'ledger-sync-status.json'), result)
                return result
        raise RuntimeError('手机正在更新台账，请稍后重试')

if __name__ == '__main__':
    try:
        print(json.dumps(synchronize(), ensure_ascii=False))
    except Exception as error:
        result = {'ok': False, 'error': str(error)[:200]}
        atomic_json(os.path.join(HERE, 'ledger-sync-status.json'), result)
        print(json.dumps(result, ensure_ascii=False))
        sys.exit(1)
