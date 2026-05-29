"""
THS Bridge —— 基于 westock-data-clawhub 的美股行情 HTTP 桥接服务
提供搜索、实时报价、日K 线接口供 iOS App 调用
"""
import logging
import os
import time
from datetime import datetime, timezone
from typing import Optional

from fastapi import FastAPI, Header, HTTPException

import sys
# 优先同级目录加载 westock_client
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import westock_client as wc

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("ths-bridge")

app = FastAPI(title="THS Bridge", version="0.2.0")


def require_access_token(authorization: str | None) -> None:
    expected = os.getenv("BRIDGE_ACCESS_TOKEN", "").strip()
    if not expected:
        return
    if authorization != f"Bearer {expected}":
        raise HTTPException(status_code=401, detail="Invalid bridge access token")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def resolve_us_code(ticker: str) -> str:
    """
    根据 ticker 搜索 westock 数据源，返回符合美股代码格式的 code。
    如果搜索不到则直接返回 us + 大写的 ticker 作为兜底。
    """
    ticker = ticker.upper().strip()
    logger.info("resolve_us_code: searching for %s", ticker)
    results = wc.search(ticker)
    if results:
        logger.info("resolve_us_code: search returned %d results for %s", len(results), ticker)
        # 优先选普通股 (GP)，其次选第一个结果
        for r in results:
            rtype = r.get("type", "")
            if rtype == "GP":
                code = r["code"]
                logger.info("resolve_us_code: selected GP result: %s -> %s", ticker, code)
                return code
        code = results[0]["code"]
        logger.info("resolve_us_code: selected first result: %s -> %s", ticker, code)
        return code
    # 兜底：使用 ticker+交易所后缀猜测
    fallback = f"us{ticker}.OQ"
    logger.warning("resolve_us_code: no search results for %s, falling back to %s", ticker, fallback)
    return fallback


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "fetchedAt": now_iso()}


# ====== 搜索 ======

@app.get("/v1/stocks/search")
def search_stocks(q: str, market: str = "US",
                  authorization: str | None = Header(default=None)) -> dict:
    logger.info("GET /v1/stocks/search?q=%s&market=%s", q, market)
    require_access_token(authorization)
    if not q.strip():
        logger.warning("search: empty query")
        return {"items": [], "provider": "westock", "fetchedAt": now_iso()}
    logger.info("search: calling wc.search(%s)", q)
    results = wc.search(q.strip())
    logger.info("search: got %d results for %s", len(results), q)
    items = []
    seen = set()
    for r in results:
        code = r.get("code", "")
        name = r.get("name", "")
        rtype = r.get("type", "")
        if not code or code in seen:
            continue
        seen.add(code)
        # 提取纯 ticker: usMU.OQ → MU
        symbol = code.split(".")[0]
        if symbol.startswith("us"):
            symbol = symbol[2:]
        is_equity = rtype in ("GP", "")
        items.append({
            "symbol": symbol,
            "name": name,
            "displaySymbol": code,
            "market": market,
            "type": rtype,
            "isEquity": is_equity,
        })
    if items:
        return {"items": items, "provider": "westock", "fetchedAt": now_iso()}
    # 搜索不到时，尝试直接查询该 ticker 的 K 线来验证
    try:
        code = resolve_us_code(q)
        kdata = wc.kline(code)
        if kdata:
            symbol = code.split(".")[0]
            if symbol.startswith("us"):
                symbol = symbol[2:]
            items.append({
                "symbol": symbol,
                "name": symbol,
                "displaySymbol": code,
                "market": market,
                "type": "GP",
                "isEquity": True,
            })
    except Exception:
        pass
    return {"items": items, "provider": "westock", "fetchedAt": now_iso()}


# ====== 实时报价 ======

@app.get("/v1/stocks/quote")
def stock_quote(symbol: str, market: str = "US",
                authorization: str | None = Header(default=None)) -> dict:
    logger.info("GET /v1/stocks/quote?symbol=%s&market=%s", symbol, market)
    require_access_token(authorization)
    ticker = symbol.upper().strip()
    logger.info("quote: resolving code for %s", ticker)

    code = resolve_us_code(ticker)
    logger.info("quote: resolved %s -> %s", ticker, code)
    logger.info("quote: calling wc.kline(%s)", code)
    kdata = wc.kline(code)
    logger.info("quote: got %d kline rows for %s", len(kdata), code)
    if not kdata:
        raise HTTPException(status_code=502, detail=f"No data for {ticker}")

    latest = kdata[0]  # 最新交易日
    prev = kdata[1] if len(kdata) > 1 else kdata[0]

    regular_price = float(latest["last"])
    prev_close = float(prev["last"])
    change = regular_price - prev_close
    change_pct = (change / prev_close * 100) if prev_close > 0 else 0

    # 搜索名称
    name = ticker
    try:
        sr = wc.search(ticker)
        if sr:
            name = sr[0].get("name", ticker)
            logger.info("quote: resolved name=%s for %s", name, ticker)
    except Exception as e:
        logger.warning("quote: name search failed for %s: %s", ticker, e)

    now = now_iso()
    logger.info("quote: returning response for %s: price=%s, prevClose=%s, change=%.2f%%",
                ticker, latest.get("last"), prev.get("last"), change_pct)
    return {
        "symbol": ticker,
        "name": name,
        "currency": "USD",
        "regularPrice": round(regular_price, 4),
        "previousClose": round(prev_close, 4),
        "change": round(change, 4),
        "changePercent": round(change_pct, 4),
        "marketState": "regular" if _is_us_market_open() else "closed",
        "regularTimestamp": f"{latest['date']} 16:00:00",
        "extendedPrice": None,
        "extendedChange": None,
        "extendedChangePercent": None,
        "extendedTimestamp": None,
        "provider": "westock",
        "providerLabel": "Westock",
        "isStale": False,
        "fetchedAt": now,
        "open": float(latest.get("open", 0)),
        "high": float(latest.get("high", 0)),
        "low": float(latest.get("low", 0)),
        "volume": int(latest.get("volume", 0)),
    }


# ====== 日K 线 ======

@app.get("/v1/stocks/kline")
def stock_kline(symbol: str, count: int = 120,
                authorization: str | None = Header(default=None)) -> dict:
    """
    获取日K线数据。
    count: 返回最近 N 个交易日数据，默认 120
    """
    logger.info("GET /v1/stocks/kline?symbol=%s&count=%d", symbol, count)
    require_access_token(authorization)
    ticker = symbol.upper().strip()
    logger.info("kline: resolving code for %s", ticker)

    code = resolve_us_code(ticker)
    logger.info("kline: resolved %s -> %s", ticker, code)
    logger.info("kline: calling wc.kline(%s)", code)
    kdata = wc.kline(code)
    logger.info("kline: got %d rows for %s", len(kdata), code)
    if not kdata:
        logger.error("kline: no data for %s (code=%s)", ticker, code)
        raise HTTPException(status_code=502, detail=f"No kline data for {ticker}")

    points = []
    for i, row in enumerate(kdata[:count]):
        points.append({
            "date": row.get("date", ""),
            "open": round(float(row.get("open", 0)), 4),
            "high": round(float(row.get("high", 0)), 4),
            "low": round(float(row.get("low", 0)), 4),
            "close": round(float(row.get("last", 0)), 4),
            "volume": int(row.get("volume", 0)),
            "changePercent": round(float(row.get("exchange", 0)), 4),
        })

    return {
        "symbol": ticker,
        "code": code,
        "count": len(points),
        "items": points,
        "provider": "westock",
        "fetchedAt": now_iso(),
    }


def _is_us_market_open() -> bool:
    """简单判断美股是否处于交易时段（美国东部时间 9:30~16:00，周一到周五）"""
    from datetime import datetime
    et = timezone.utc  # 简化版，真实应转换到 America/New_York
    now = datetime.now(et)
    return now.weekday() < 5 and (9 <= now.hour < 16)
