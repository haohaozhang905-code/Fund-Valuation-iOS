"""
westockdata Python 客户端 —— 通过 subprocess 调用 npx westock-data-clawhub CLI
"""
import subprocess
import json
import os
import re
import threading
from typing import Optional

NPX = None  # lazy init
PACKAGE = "westock-data-clawhub@1.0.4"
ENV = None  # lazy init
MAX_CONCURRENCY = int(os.getenv("WESTOCK_MAX_CONCURRENCY", "2"))
SEARCH_TIMEOUT_SECONDS = int(os.getenv("WESTOCK_SEARCH_TIMEOUT_SECONDS", "15"))
COMMAND_TIMEOUT_SECONDS = int(os.getenv("WESTOCK_COMMAND_TIMEOUT_SECONDS", "30"))
_RUN_SEMAPHORE = threading.BoundedSemaphore(max(1, MAX_CONCURRENCY))


def _init_npx():
    global NPX, ENV
    if NPX is not None:
        return
    # 尝试多种常见的 npx 路径
    candidates = [
        "/usr/local/bin/npx",
        "/usr/bin/npx",
        "/opt/homebrew/bin/npx",
        "npx",
    ]
    for c in candidates:
        try:
            subprocess.run([c, "--version"], capture_output=True, timeout=5)
            NPX = c
            break
        except (FileNotFoundError, PermissionError, subprocess.TimeoutExpired):
            continue
    if NPX is None:
        raise RuntimeError("npx not found. Please install Node.js/npm.")

    npx_dir = os.path.dirname(os.path.abspath(NPX))
    ENV = {**os.environ, "PATH": f"{npx_dir}:{os.environ.get('PATH', '')}"}


# 模块加载时自动初始化
_init_npx()


def _parse_md_table(output: str) -> list[dict]:
    """解析 Markdown 表格为 dict 列表"""
    lines = output.strip().split("\n")
    if len(lines) < 3:
        return []
    # 第一行是表头（用 | 分隔）
    headers = [h.strip() for h in lines[0].split("|")[1:-1]]
    # 第二行是分隔线，跳过
    rows = []
    for line in lines[2:]:
        line = line.strip()
        if not line or not line.startswith("|"):
            continue
        line = line.rstrip("|")
        vals = [v.strip() for v in line.split("|")[1:]]
        if len(vals) != len(headers):
            continue
        row = {}
        for h, v in zip(headers, vals):
            # 尝试转换为数字
            try:
                row[h] = float(v)
                if row[h] == int(row[h]):
                    row[h] = int(row[h])
            except ValueError:
                row[h] = v
        rows.append(row)
    return rows


def _run(cmd: str, timeout: int = COMMAND_TIMEOUT_SECONDS) -> list[dict]:
    """执行 westockdata 命令并返回解析结果"""
    full_cmd = [NPX, "-y", PACKAGE] + cmd.split()
    with _RUN_SEMAPHORE:
        r = subprocess.run(full_cmd, capture_output=True, text=True, timeout=timeout, env=ENV)
    if r.returncode != 0:
        raise RuntimeError(f"CLI error: {r.stderr}")
    return _parse_md_table(r.stdout)


# ====== 以下为业务方法 ======

def search(keyword: str) -> list[dict]:
    """搜索股票代码"""
    return _run(f"search {keyword}", timeout=SEARCH_TIMEOUT_SECONDS)


def minute(code: str) -> list[dict]:
    """分钟K线 - 当日"""
    return _run(f"minute {code}")


def kline(code: str) -> list[dict]:
    """日K线"""
    return _run(f"kline {code}")


def hot() -> list[dict]:
    """热搜"""
    return _run("hot")


def profile(code: str) -> list[dict]:
    """公司简况"""
    return _run(f"profile {code}")


def finance(code: str) -> list[dict]:
    """财务报表"""
    return _run(f"finance {code}")


def technical(code: str) -> list[dict]:
    """技术指标"""
    return _run(f"technical {code}")


def chip(code: str) -> list[dict]:
    """筹码分布"""
    return _run(f"chip {code}")


def shareholder(code: str) -> list[dict]:
    """股东结构"""
    return _run(f"shareholder {code}")


def dividend(code: str) -> list[dict]:
    """分红除权"""
    return _run(f"dividend {code}")


# ====== 测试 ======
if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        code = sys.argv[1]
    else:
        code = "usMU"
    print(f"=== 搜索 {code} ===")
    s = search(code)
    print(json.dumps(s[:3], indent=2, ensure_ascii=False))
    print(f"\n=== K线 {code} ===")
    k = kline(code)
    print(json.dumps(k[:3], indent=2, ensure_ascii=False))
