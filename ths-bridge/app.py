"""
THS Bridge —— 基于 westock-data-clawhub 的美股行情 HTTP 桥接服务
提供搜索、实时报价、日K 线接口供 iOS App 调用
"""
import logging
import os
import threading
import time
import hashlib
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, status
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import database
from auth_service import (
    ACCESS_TOKEN_MINUTES,
    create_access_token,
    current_user,
    generate_reset_code,
    hash_password,
    hash_reset_code,
    normalize_email,
    verify_password,
    verify_reset_code,
)
from database import get_db, init_db
from mailer import mailer
from models import FundPositionDB, PasswordResetCode, StockPositionDB, User, utcnow
from schemas import (
    AuthRequest,
    AuthResponse,
    FundPositionOut,
    PasswordResetConfirmRequest,
    PasswordResetRequest,
    PortfolioIn,
    PortfolioOut,
    StockPositionOut,
    UserOut,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("ths-bridge")

app = FastAPI(
    title="THS Bridge",
    version="0.3.0",
    json_encoders={
        datetime: lambda dt: dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
    },
)

TWELVE_DATA_BASE_URL = "https://api.twelvedata.com"
YAHOO_BASE_URL = "https://query1.finance.yahoo.com"
SEARCH_CACHE_TTL_SECONDS = int(os.getenv("SEARCH_CACHE_TTL_SECONDS", "300"))
SEARCH_MIN_QUERY_LENGTH = int(os.getenv("SEARCH_MIN_QUERY_LENGTH", "2"))
QUOTE_CACHE_TTL_SECONDS = int(os.getenv("QUOTE_CACHE_TTL_SECONDS", "60"))
KLINE_CACHE_TTL_SECONDS = int(os.getenv("KLINE_CACHE_TTL_SECONDS", "3600"))
WESTOCK_ENABLED = os.getenv("WESTOCK_ENABLED", "false").strip().lower() in {"1", "true", "yes", "on"}
SYMBOL_OVERRIDES: dict[str, dict[str, Any]] = {
    "NASA": {
        "symbol": "NASA",
        "name": "Tema Space Innovators ETF",
        "displaySymbol": "NASA.NYSEARCA",
        "market": "NYSEARCA",
        "type": "ETF",
        "isEquity": True,
    },
    "SNXX": {
        "symbol": "SNXX",
        "name": "Tradr 2X Long SNDK Daily ETF",
        "displaySymbol": "SNXX.BATS",
        "market": "BATS",
        "type": "ETF",
        "isEquity": True,
    },
}
_search_cache_lock = threading.Lock()
_search_cache: dict[str, tuple[float, dict[str, Any]]] = {}
_quote_cache_lock = threading.Lock()
_quote_cache: dict[str, tuple[float, dict[str, Any]]] = {}
_kline_cache_lock = threading.Lock()
_kline_cache: dict[str, tuple[float, dict[str, Any]]] = {}
_wc = None


@app.on_event("startup")
def startup() -> None:
    init_db()
    for warning in deployment_warnings():
        logger.warning("deployment config: %s", warning)


def auth_response(user: User) -> AuthResponse:
    return AuthResponse(
        accessToken=create_access_token(user),
        user=UserOut(id=user.id, email=user.email_lower),
    )


def as_utc(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def require_access_token(authorization: str | None) -> None:
    expected = os.getenv("BRIDGE_ACCESS_TOKEN", "").strip()
    if not expected:
        return
    if authorization != f"Bearer {expected}":
        raise HTTPException(status_code=401, detail="Invalid bridge access token")


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fmt_iso(dt: datetime) -> str:
    """格式化日期为 iOS 能解析的格式（无微秒，Z 结尾）"""
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def get_westock():
    global _wc
    if not WESTOCK_ENABLED:
        raise RuntimeError("Westock is disabled")
    if _wc is None:
        import westock_client as westock_module
        _wc = westock_module
    return _wc


def stable_fingerprint(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def jwt_secret_configured() -> bool:
    return bool(os.getenv("JWT_SECRET", "").strip()) and os.getenv("JWT_SECRET") != "dev-change-me"


def deployment_warnings() -> list[str]:
    warnings: list[str] = []
    if not jwt_secret_configured():
        warnings.append("JWT_SECRET is not explicitly configured; token validity may be unsafe for production.")
    if os.getenv("JWT_SECRET", "").strip() == "change-me":
        warnings.append("JWT_SECRET is set to the documented placeholder value; replace it with a strong random secret.")
    if database.DATABASE_URL.startswith("sqlite") and database.DB_FILE_PATH and not os.path.isabs(database.DB_FILE_PATH):
        warnings.append("DATABASE_URL uses a relative SQLite file; container redeploys may lose account data without a persistent volume.")
    if WESTOCK_ENABLED:
        warnings.append("WESTOCK_ENABLED is true; westock uses Node subprocesses and can increase memory usage under load.")
    return warnings


def search_cache_key(q: str, market: str) -> str:
    return f"{market.upper().strip()}:{q.upper().strip()}"


def get_cached_search(q: str, market: str) -> dict[str, Any] | None:
    key = search_cache_key(q, market)
    now = time.monotonic()
    with _search_cache_lock:
        entry = _search_cache.get(key)
        if entry is None:
            return None
        expires_at, payload = entry
        if expires_at <= now:
            _search_cache.pop(key, None)
            return None
        return payload


def set_cached_search(q: str, market: str, payload: dict[str, Any]) -> dict[str, Any]:
    key = search_cache_key(q, market)
    with _search_cache_lock:
        _search_cache[key] = (time.monotonic() + SEARCH_CACHE_TTL_SECONDS, payload)
    return payload


def get_ttl_cache(cache: dict[str, tuple[float, dict[str, Any]]], lock: threading.Lock, key: str) -> dict[str, Any] | None:
    now = time.monotonic()
    with lock:
        entry = cache.get(key)
        if entry is None:
            return None
        expires_at, payload = entry
        if expires_at <= now:
            cache.pop(key, None)
            return None
        return payload


def set_ttl_cache(
    cache: dict[str, tuple[float, dict[str, Any]]],
    lock: threading.Lock,
    key: str,
    ttl: int,
    payload: dict[str, Any],
) -> dict[str, Any]:
    with lock:
        cache[key] = (time.monotonic() + ttl, payload)
    return payload


def get_cached_quote(symbol: str) -> dict[str, Any] | None:
    return get_ttl_cache(_quote_cache, _quote_cache_lock, symbol.upper().strip())


def set_cached_quote(symbol: str, payload: dict[str, Any]) -> dict[str, Any]:
    return set_ttl_cache(_quote_cache, _quote_cache_lock, symbol.upper().strip(), QUOTE_CACHE_TTL_SECONDS, payload)


def get_cached_kline(symbol: str, count: int) -> dict[str, Any] | None:
    return get_ttl_cache(_kline_cache, _kline_cache_lock, f"{symbol.upper().strip()}:{count}")


def set_cached_kline(symbol: str, count: int, payload: dict[str, Any]) -> dict[str, Any]:
    return set_ttl_cache(_kline_cache, _kline_cache_lock, f"{symbol.upper().strip()}:{count}", KLINE_CACHE_TTL_SECONDS, payload)


def is_symbol_like(query: str) -> bool:
    normalized = query.upper().strip()
    if not 1 <= len(normalized) <= 15:
        return False
    return all(ch.isalnum() or ch in ".-" for ch in normalized)


def parse_float(value: Any, default: float = 0.0) -> float:
    if value is None or value == "":
        return default
    try:
        return float(str(value).replace("%", "").replace(",", ""))
    except (TypeError, ValueError):
        return default


def parse_int(value: Any, default: int = 0) -> int:
    if value is None or value == "":
        return default
    try:
        return int(float(str(value).replace(",", "")))
    except (TypeError, ValueError):
        return default


def twelve_data_key() -> str:
    return os.getenv("TWELVE_DATA_API_KEY", "").strip()


def is_twelve_error(payload: dict[str, Any]) -> bool:
    return str(payload.get("status", "")).lower() == "error" or bool(payload.get("code"))


def twelve_get(path: str, params: dict[str, Any]) -> dict[str, Any]:
    api_key = twelve_data_key()
    if not api_key:
        raise RuntimeError("TWELVE_DATA_API_KEY is not configured")
    with httpx.Client(timeout=10) as client:
        response = client.get(f"{TWELVE_DATA_BASE_URL}{path}", params={**params, "apikey": api_key})
        response.raise_for_status()
        payload = response.json()
    if not isinstance(payload, dict):
        raise RuntimeError("Twelve Data returned invalid payload")
    if is_twelve_error(payload):
        raise RuntimeError(f"Twelve Data error: {payload.get('message', payload)}")
    return payload


def yahoo_get(path: str, params: dict[str, Any]) -> dict[str, Any]:
    headers = {"User-Agent": "Mozilla/5.0"}
    with httpx.Client(timeout=8, headers=headers) as client:
        response = client.get(f"{YAHOO_BASE_URL}{path}", params=params)
        response.raise_for_status()
        payload = response.json()
    if not isinstance(payload, dict):
        raise RuntimeError("Yahoo returned invalid payload")
    return payload


def yahoo_symbol_search(query: str) -> list[dict[str, Any]]:
    try:
        payload = yahoo_get("/v1/finance/search", {"q": query.strip().upper(), "quotesCount": 8, "newsCount": 0})
    except Exception as e:
        logger.warning("yahoo search failed for %s: %s", query, e)
        return []

    quotes = payload.get("quotes", [])
    if not isinstance(quotes, list):
        return []

    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for row in quotes:
        if not isinstance(row, dict):
            continue
        symbol = str(row.get("symbol", "")).upper().strip()
        if not symbol or symbol in seen:
            continue
        quote_type = str(row.get("quoteType") or row.get("typeDisp") or "").upper()
        if quote_type and quote_type not in {"EQUITY", "ETF"}:
            continue
        seen.add(symbol)
        exchange = str(row.get("exchange") or row.get("exchDisp") or "").upper()
        name = str(row.get("shortname") or row.get("longname") or symbol).strip()
        is_etf = quote_type == "ETF"
        items.append({
            "symbol": symbol,
            "name": name,
            "displaySymbol": f"{symbol}.{exchange}" if exchange else symbol,
            "market": exchange or "US",
            "type": "ETF" if is_etf else "Common Stock",
            "isEquity": True,
        })
    return items


def yahoo_chart_result(symbol: str, params: dict[str, Any]) -> dict[str, Any] | None:
    try:
        payload = yahoo_get(f"/v8/finance/chart/{symbol}", params)
    except Exception as e:
        logger.warning("yahoo chart failed for %s: %s", symbol, e)
        return None
    chart = payload.get("chart", {})
    result = chart.get("result", []) if isinstance(chart, dict) else []
    if not result:
        return None
    first = result[0]
    return first if isinstance(first, dict) else None


def yahoo_quote(ticker: str) -> dict[str, Any] | None:
    symbol = ticker.upper().strip()
    result = yahoo_chart_result(symbol, {"range": "5d", "interval": "1d"})
    if not result:
        return None
    meta = result.get("meta", {})
    if not isinstance(meta, dict):
        return None
    price = parse_float(meta.get("regularMarketPrice"))
    prev_close = parse_float(meta.get("previousClose") or meta.get("chartPreviousClose"))
    if price <= 0:
        return None
    change = price - prev_close if prev_close > 0 else 0
    change_pct = change / prev_close * 100 if prev_close > 0 else 0
    ts = parse_int(meta.get("regularMarketTime"))
    regular_timestamp = datetime.fromtimestamp(ts, timezone.utc).isoformat() if ts else now_iso()
    return {
        "symbol": symbol,
        "name": symbol,
        "currency": str(meta.get("currency") or "USD"),
        "regularPrice": round(price, 4),
        "previousClose": round(prev_close, 4) if prev_close > 0 else None,
        "change": round(change, 4),
        "changePercent": round(change_pct, 4),
        "marketState": "regular" if str(meta.get("marketState", "")).upper() == "REGULAR" else "closed",
        "regularTimestamp": regular_timestamp,
        "extendedPrice": None,
        "extendedChange": None,
        "extendedChangePercent": None,
        "extendedTimestamp": None,
        "provider": "yahoo",
        "providerLabel": "Yahoo Finance",
        "isStale": False,
        "fetchedAt": now_iso(),
        "open": parse_float(meta.get("regularMarketOpen")),
        "high": parse_float(meta.get("regularMarketDayHigh")),
        "low": parse_float(meta.get("regularMarketDayLow")),
        "volume": parse_int(meta.get("regularMarketVolume")),
    }


def yahoo_kline(ticker: str, count: int) -> dict[str, Any] | None:
    symbol = ticker.upper().strip()
    range_value = "6mo" if count <= 126 else "1y"
    result = yahoo_chart_result(symbol, {"range": range_value, "interval": "1d"})
    if not result:
        return None
    timestamps = result.get("timestamp", [])
    indicators = result.get("indicators", {})
    quotes = indicators.get("quote", []) if isinstance(indicators, dict) else []
    if not isinstance(timestamps, list) or not quotes or not isinstance(quotes[0], dict):
        return None
    quote = quotes[0]
    rows = []
    for idx, ts in enumerate(timestamps):
        close = parse_float((quote.get("close") or [None])[idx] if idx < len(quote.get("close") or []) else None)
        if close <= 0:
            continue
        rows.append({
            "date": datetime.fromtimestamp(parse_int(ts), timezone.utc).date().isoformat(),
            "open": round(parse_float((quote.get("open") or [None])[idx] if idx < len(quote.get("open") or []) else None), 4),
            "high": round(parse_float((quote.get("high") or [None])[idx] if idx < len(quote.get("high") or []) else None), 4),
            "low": round(parse_float((quote.get("low") or [None])[idx] if idx < len(quote.get("low") or []) else None), 4),
            "close": round(close, 4),
            "volume": parse_int((quote.get("volume") or [None])[idx] if idx < len(quote.get("volume") or []) else None),
            "changePercent": 0,
        })
    points = list(reversed(rows))[:count]
    if not points:
        return None
    return {
        "symbol": symbol,
        "code": symbol,
        "count": len(points),
        "items": points,
        "provider": "yahoo",
        "fetchedAt": now_iso(),
    }


def twelve_symbol_search(query: str) -> list[dict[str, Any]]:
    try:
        payload = twelve_get("/symbol_search", {"symbol": query.strip().upper(), "outputsize": 8})
    except Exception as e:
        logger.warning("twelve search failed for %s: %s", query, e)
        return []

    data = payload.get("data", [])
    if not isinstance(data, list):
        return []

    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for row in data:
        if not isinstance(row, dict):
            continue
        symbol = str(row.get("symbol", "")).upper().strip()
        exchange = str(row.get("exchange", "")).upper().strip()
        if not symbol or symbol in seen:
            continue
        seen.add(symbol)
        name = str(row.get("instrument_name") or row.get("name") or symbol).strip()
        instrument_type = str(row.get("instrument_type") or "Common Stock").strip()
        is_equity = instrument_type.lower() in {"common stock", "stock", "equity"} or not instrument_type
        items.append({
            "symbol": symbol,
            "name": name,
            "displaySymbol": f"{symbol}.{exchange}" if exchange else symbol,
            "market": exchange or "US",
            "type": instrument_type,
            "isEquity": is_equity,
        })
    return items


def exact_symbol_probe(symbol: str, market: str) -> tuple[list[dict[str, Any]], str]:
    normalized = symbol.upper().strip()
    if not normalized or len(normalized) > 15:
        return [], "none"

    quote = yahoo_quote(normalized)
    provider = "yahoo"
    if quote is None:
        quote = twelve_quote(normalized)
        provider = "twelvedata"
    if quote is None:
        return [], "none"

    name = str(quote.get("name") or normalized).strip()
    return [{
        "symbol": normalized,
        "name": name,
        "displaySymbol": normalized,
        "market": market,
        "type": "Common Stock",
        "isEquity": True,
    }], provider


def twelve_quote(ticker: str) -> dict[str, Any] | None:
    symbol = ticker.upper().strip()
    params = {"symbol": symbol}
    if len(symbol) == 5 and symbol.endswith("F"):
        params["exchange"] = "OTC"
    try:
        payload = twelve_get("/quote", params)
    except Exception as e:
        logger.warning("twelve quote failed for %s: %s", ticker, e)
        return None

    price = parse_float(payload.get("close") or payload.get("price"))
    prev_close = parse_float(payload.get("previous_close"))
    if price <= 0:
        return None
    change = parse_float(payload.get("change"), price - prev_close if prev_close > 0 else 0)
    change_pct = parse_float(payload.get("percent_change"))
    if change_pct == 0 and prev_close > 0:
        change_pct = change / prev_close * 100

    quote_time = payload.get("datetime") or now_iso()
    return {
        "symbol": symbol,
        "name": str(payload.get("name") or symbol),
        "currency": str(payload.get("currency") or "USD"),
        "regularPrice": round(price, 4),
        "previousClose": round(prev_close, 4) if prev_close > 0 else None,
        "change": round(change, 4),
        "changePercent": round(change_pct, 4),
        "marketState": "regular" if _is_us_market_open() else "closed",
        "regularTimestamp": quote_time,
        "extendedPrice": None,
        "extendedChange": None,
        "extendedChangePercent": None,
        "extendedTimestamp": None,
        "provider": "twelvedata",
        "providerLabel": "Twelve Data",
        "isStale": False,
        "fetchedAt": now_iso(),
        "open": parse_float(payload.get("open")),
        "high": parse_float(payload.get("high")),
        "low": parse_float(payload.get("low")),
        "volume": parse_int(payload.get("volume")),
    }


def twelve_kline(ticker: str, count: int) -> dict[str, Any] | None:
    symbol = ticker.upper().strip()
    params: dict[str, Any] = {
        "symbol": symbol,
        "interval": "1day",
        "outputsize": max(1, min(count, 5000)),
        "order": "DESC",
    }
    if len(symbol) == 5 and symbol.endswith("F"):
        params["exchange"] = "OTC"
    try:
        payload = twelve_get("/time_series", params)
    except Exception as e:
        logger.warning("twelve kline failed for %s: %s", ticker, e)
        return None

    values = payload.get("values", [])
    if not isinstance(values, list) or not values:
        return None

    points = []
    for row in values[:count]:
        if not isinstance(row, dict):
            continue
        close = parse_float(row.get("close"))
        if close <= 0:
            continue
        points.append({
            "date": str(row.get("datetime", "")),
            "open": round(parse_float(row.get("open")), 4),
            "high": round(parse_float(row.get("high")), 4),
            "low": round(parse_float(row.get("low")), 4),
            "close": round(close, 4),
            "volume": parse_int(row.get("volume")),
            "changePercent": 0,
        })
    if not points:
        return None
    return {
        "symbol": symbol,
        "code": f"{symbol}.OTC" if params.get("exchange") == "OTC" else symbol,
        "count": len(points),
        "items": points,
        "provider": "twelvedata",
        "fetchedAt": now_iso(),
    }


def resolve_us_code(ticker: str) -> str:
    """
    根据 ticker 搜索 westock 数据源，返回符合美股代码格式的 code。
    如果搜索不到则直接返回 us + 大写的 ticker 作为兜底。
    """
    ticker = ticker.upper().strip()
    logger.info("resolve_us_code: searching for %s", ticker)
    wc = get_westock()
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
def health() -> dict[str, Any]:
    db_file = database.DB_FILE_PATH
    db_exists = os.path.isfile(db_file) if db_file else False
    db_url = database.DATABASE_URL
    db_kind = db_url.split(":", 1)[0]
    jwt_secret = os.getenv("JWT_SECRET", "dev-change-me")
    return {
        "status": "ok",
        "fetchedAt": now_iso(),
        "database": {
            "kind": db_kind,
            "path": db_file or "not_sqlite",
            "exists": db_exists,
            "isRelativeSqlitePath": bool(db_file and not os.path.isabs(db_file)),
        },
        "auth": {
            "jwtSecretConfigured": jwt_secret_configured(),
            "jwtSecretFingerprint": stable_fingerprint(jwt_secret),
            "accessTokenMinutes": ACCESS_TOKEN_MINUTES,
        },
        "stocks": {
            "westockEnabled": WESTOCK_ENABLED,
            "searchCacheTtlSeconds": SEARCH_CACHE_TTL_SECONDS,
            "quoteCacheTtlSeconds": QUOTE_CACHE_TTL_SECONDS,
            "klineCacheTtlSeconds": KLINE_CACHE_TTL_SECONDS,
        },
        "warnings": deployment_warnings(),
    }


# ====== 用户账号 ======

@app.post("/v1/auth/register", response_model=AuthResponse, status_code=status.HTTP_201_CREATED)
def register(payload: AuthRequest, db: Session = Depends(get_db)) -> AuthResponse:
    email = normalize_email(str(payload.email))
    existing = db.scalar(select(User).where(User.email_lower == email))
    if existing is not None and existing.deleted_at is None:
        raise HTTPException(status_code=409, detail="Email already registered")
    if existing is not None:
        existing.password_hash = hash_password(payload.password)
        existing.deleted_at = None
        existing.updated_at = utcnow()
        user = existing
    else:
        user = User(email_lower=email, password_hash=hash_password(payload.password))
        db.add(user)
    db.commit()
    db.refresh(user)
    return auth_response(user)


@app.post("/v1/auth/login", response_model=AuthResponse)
def login(payload: AuthRequest, db: Session = Depends(get_db)) -> AuthResponse:
    email = normalize_email(str(payload.email))
    user = db.scalar(select(User).where(User.email_lower == email, User.deleted_at.is_(None)))
    email_id = stable_fingerprint(email)
    if user is None:
        logger.warning("login failed: user not found email_id=%s", email_id)
        raise HTTPException(status_code=401, detail="Invalid email or password")
    if not verify_password(payload.password, user.password_hash):
        logger.warning("login failed: password mismatch user_id=%s email_id=%s", user.id, email_id)
        raise HTTPException(status_code=401, detail="Invalid email or password")
    return auth_response(user)


@app.post("/v1/auth/password-reset/request")
def request_password_reset(payload: PasswordResetRequest, db: Session = Depends(get_db)) -> dict[str, str]:
    email = normalize_email(str(payload.email))
    user = db.scalar(select(User).where(User.email_lower == email, User.deleted_at.is_(None)))
    result = {"status": "ok", "userFound": "false"}
    if user is not None:
        result["userFound"] = "true"
        code = generate_reset_code()
        reset = PasswordResetCode(
            user_id=user.id,
            code_hash=hash_reset_code(code),
            expires_at=utcnow() + timedelta(minutes=10),
        )
        db.add(reset)
        db.commit()
        try:
            mailer.send_password_reset_code(email, code)
            result["emailSent"] = "true"
        except Exception as e:
            result["emailSent"] = "false"
            result["emailError"] = str(e)
    return result


@app.post("/v1/auth/password-reset/confirm", response_model=AuthResponse)
def confirm_password_reset(payload: PasswordResetConfirmRequest, db: Session = Depends(get_db)) -> AuthResponse:
    email = normalize_email(str(payload.email))
    user = db.scalar(select(User).where(User.email_lower == email, User.deleted_at.is_(None)))
    if user is None:
        raise HTTPException(status_code=400, detail="Invalid reset code")
    reset = db.scalar(
        select(PasswordResetCode)
        .where(PasswordResetCode.user_id == user.id, PasswordResetCode.used_at.is_(None))
        .order_by(PasswordResetCode.created_at.desc())
    )
    now = utcnow()
    if reset is None or as_utc(reset.expires_at) < now or reset.attempt_count >= 5:
        raise HTTPException(status_code=400, detail="Invalid reset code")
    reset.attempt_count += 1
    if not verify_reset_code(payload.code, reset.code_hash):
        db.commit()
        raise HTTPException(status_code=400, detail="Invalid reset code")
    reset.used_at = now
    user.password_hash = hash_password(payload.newPassword)
    user.updated_at = now
    db.commit()
    db.refresh(user)
    return auth_response(user)


@app.post("/v1/auth/logout")
def logout(_: User = Depends(current_user)) -> dict[str, str]:
    return {"status": "ok"}


@app.get("/v1/auth/me", response_model=UserOut)
def me(user: User = Depends(current_user)) -> UserOut:
    return UserOut(id=user.id, email=user.email_lower)


@app.get("/debug/portfolio-raw")
def debug_portfolio_raw(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """返回 portfolio 原始 JSON 用于调试日期格式"""
    from fastapi.responses import JSONResponse
    import json

    funds = db.scalars(
        select(FundPositionDB).where(FundPositionDB.user_id == user.id).order_by(FundPositionDB.created_at)
    ).all()
    stocks = db.scalars(
        select(StockPositionDB).where(StockPositionDB.user_id == user.id).order_by(StockPositionDB.created_at)
    ).all()

    data = {
        "funds": [
            {
                "id": f.id,
                "fundCode": f.fund_code,
                "fundName": f.fund_name,
                "costPrice": f.cost_price,
                "shares": f.shares,
                "clientUpdatedAt": fmt_iso(f.client_updated_at) if f.client_updated_at else None,
            }
            for f in funds
        ],
        "stocks": [
            {
                "id": s.id,
                "symbol": s.symbol,
                "displayName": s.display_name,
                "averageCost": s.average_cost,
                "shares": s.shares,
                "clientUpdatedAt": fmt_iso(s.client_updated_at) if s.client_updated_at else None,
            }
            for s in stocks
        ],
        "updatedAt": now_iso(),
    }
    return JSONResponse(content=data)


@app.delete("/v1/account")
def delete_account(user: User = Depends(current_user), db: Session = Depends(get_db)) -> dict[str, str]:
    db.execute(delete(FundPositionDB).where(FundPositionDB.user_id == user.id))
    db.execute(delete(StockPositionDB).where(StockPositionDB.user_id == user.id))
    user.deleted_at = utcnow()
    db.commit()
    return {"status": "deleted"}


# ====== 用户持仓 ======

def normalize_fund_code(raw: str) -> str:
    digits = "".join(ch for ch in raw if ch.isdigit())
    return digits[-6:].zfill(6)


def normalize_symbol(raw: str) -> str:
    return raw.strip().upper()


def portfolio_response(user_id: int, db: Session) -> PortfolioOut:
    funds = db.scalars(select(FundPositionDB).where(FundPositionDB.user_id == user_id).order_by(FundPositionDB.created_at)).all()
    stocks = db.scalars(select(StockPositionDB).where(StockPositionDB.user_id == user_id).order_by(StockPositionDB.created_at)).all()
    updated = utcnow()
    return PortfolioOut(
        funds=[
            FundPositionOut(
                id=f.id,
                fundCode=f.fund_code,
                fundName=f.fund_name,
                costPrice=f.cost_price,
                shares=f.shares,
                clientUpdatedAt=f.client_updated_at,
            )
            for f in funds
        ],
        stocks=[
            StockPositionOut(
                id=s.id,
                symbol=s.symbol,
                displayName=s.display_name,
                averageCost=s.average_cost,
                shares=s.shares,
                clientUpdatedAt=s.client_updated_at,
            )
            for s in stocks
        ],
        updatedAt=updated,
    )


@app.get("/v1/portfolio", response_model=PortfolioOut)
def get_portfolio(user: User = Depends(current_user), db: Session = Depends(get_db)) -> PortfolioOut:
    return portfolio_response(user.id, db)


@app.put("/v1/portfolio", response_model=PortfolioOut)
def replace_portfolio(
    payload: PortfolioIn,
    user: User = Depends(current_user),
    db: Session = Depends(get_db),
) -> PortfolioOut:
    fund_codes: set[str] = set()
    stock_symbols: set[str] = set()
    for fund in payload.funds:
        code = normalize_fund_code(fund.fundCode)
        if len(code) != 6 or code in fund_codes:
            raise HTTPException(status_code=422, detail="Duplicate or invalid fund code")
        fund_codes.add(code)
    for stock in payload.stocks:
        symbol = normalize_symbol(stock.symbol)
        if not symbol or symbol in stock_symbols:
            raise HTTPException(status_code=422, detail="Duplicate or invalid stock symbol")
        stock_symbols.add(symbol)

    with db.begin_nested():
        db.execute(delete(FundPositionDB).where(FundPositionDB.user_id == user.id))
        db.execute(delete(StockPositionDB).where(StockPositionDB.user_id == user.id))
        for fund in payload.funds:
            db.add(
                FundPositionDB(
                    id=fund.id,
                    user_id=user.id,
                    fund_code=normalize_fund_code(fund.fundCode),
                    fund_name=fund.fundName,
                    cost_price=fund.costPrice,
                    shares=fund.shares,
                    client_updated_at=fund.clientUpdatedAt,
                )
            )
        for stock in payload.stocks:
            db.add(
                StockPositionDB(
                    id=stock.id,
                    user_id=user.id,
                    symbol=normalize_symbol(stock.symbol),
                    display_name=stock.displayName,
                    average_cost=stock.averageCost,
                    shares=stock.shares,
                    client_updated_at=stock.clientUpdatedAt,
                )
            )
    db.commit()
    return portfolio_response(user.id, db)


# ====== 搜索 ======

@app.get("/v1/stocks/search")
def search_stocks(q: str, market: str = "US",
                  authorization: str | None = Header(default=None)) -> dict:
    logger.info("GET /v1/stocks/search?q=%s&market=%s", q, market)
    require_access_token(authorization)
    query = q.strip().upper()
    if not query:
        logger.warning("search: empty query")
        return {"items": [], "provider": "westock", "fetchedAt": now_iso()}
    if len(query) < SEARCH_MIN_QUERY_LENGTH:
        return {"items": [], "provider": "cache", "fetchedAt": now_iso()}
    cached = get_cached_search(query, market)
    if cached is not None:
        logger.info("search: cache hit for %s", query)
        return cached

    if is_symbol_like(query):
        items, probe_provider = exact_symbol_probe(query, market)
        if items:
            return set_cached_search(query, market, {"items": items, "provider": probe_provider, "fetchedAt": now_iso()})
        if query in SYMBOL_OVERRIDES:
            return set_cached_search(query, market, {"items": [SYMBOL_OVERRIDES[query]], "provider": "override", "fetchedAt": now_iso()})

    items = yahoo_symbol_search(query)
    if items:
        return set_cached_search(query, market, {"items": items, "provider": "yahoo", "fetchedAt": now_iso()})
    items = twelve_symbol_search(query)
    if items:
        return set_cached_search(query, market, {"items": items, "provider": "twelvedata", "fetchedAt": now_iso()})

    if not WESTOCK_ENABLED:
        return set_cached_search(query, market, {"items": [], "provider": "none", "fetchedAt": now_iso()})

    logger.info("search: calling wc.search(%s)", query)
    try:
        wc = get_westock()
        results = wc.search(query)
        logger.info("search: got %d results for %s", len(results), query)
    except Exception as e:
        logger.warning("search: westock failed for %s: %s", query, e)
        results = []
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
        return set_cached_search(query, market, {"items": items, "provider": "westock", "fetchedAt": now_iso()})

    # Do not validate misses with kline here. Search runs while the user types,
    # so fallback quote/kline probes belong to explicit quote/detail requests.
    return set_cached_search(query, market, {"items": [], "provider": "westock", "fetchedAt": now_iso()})


# ====== 实时报价 ======

@app.get("/v1/stocks/quote")
def stock_quote(symbol: str, market: str = "US",
                authorization: str | None = Header(default=None)) -> dict:
    logger.info("GET /v1/stocks/quote?symbol=%s&market=%s", symbol, market)
    require_access_token(authorization)
    ticker = symbol.upper().strip()
    logger.info("quote: resolving code for %s", ticker)

    cached = get_cached_quote(ticker)
    if cached is not None:
        logger.info("quote: cache hit for %s", ticker)
        return cached

    quote = yahoo_quote(ticker)
    if quote:
        logger.info("quote: returning yahoo response for %s", ticker)
        return set_cached_quote(ticker, quote)

    quote = twelve_quote(ticker)
    if quote:
        logger.info("quote: returning twelve data response for %s", ticker)
        return set_cached_quote(ticker, quote)

    if WESTOCK_ENABLED:
        try:
            wc = get_westock()
            code = resolve_us_code(ticker)
            logger.info("quote: resolved %s -> %s", ticker, code)
            logger.info("quote: calling wc.kline(%s)", code)
            kdata = wc.kline(code)
            logger.info("quote: got %d kline rows for %s", len(kdata), code)
            if kdata:
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
                logger.info("quote: returning westock response for %s: price=%s, prevClose=%s, change=%.2f%%",
                            ticker, latest.get("last"), prev.get("last"), change_pct)
                return set_cached_quote(ticker, {
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
                })
        except Exception as e:
            logger.warning("quote: westock failed for %s: %s", ticker, e)
    raise HTTPException(status_code=502, detail=f"No data for {ticker}")


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

    cached = get_cached_kline(ticker, count)
    if cached is not None:
        logger.info("kline: cache hit for %s count=%d", ticker, count)
        return cached

    kline = yahoo_kline(ticker, count)
    if kline:
        logger.info("kline: returning yahoo response for %s", ticker)
        return set_cached_kline(ticker, count, kline)

    kline = twelve_kline(ticker, count)
    if kline:
        logger.info("kline: returning twelve data response for %s", ticker)
        return set_cached_kline(ticker, count, kline)

    if WESTOCK_ENABLED:
        try:
            wc = get_westock()
            code = resolve_us_code(ticker)
            logger.info("kline: resolved %s -> %s", ticker, code)
            logger.info("kline: calling wc.kline(%s)", code)
            kdata = wc.kline(code)
            logger.info("kline: got %d rows for %s", len(kdata), code)
            if kdata:
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

                return set_cached_kline(ticker, count, {
                    "symbol": ticker,
                    "code": code,
                    "count": len(points),
                    "items": points,
                    "provider": "westock",
                    "fetchedAt": now_iso(),
                })
            logger.error("kline: no westock data for %s (code=%s)", ticker, code)
        except Exception as e:
            logger.warning("kline: westock failed for %s: %s", ticker, e)
    raise HTTPException(status_code=502, detail=f"No kline data for {ticker}")


def _is_us_market_open() -> bool:
    """简单判断美股是否处于交易时段（美国东部时间 9:30~16:00，周一到周五）"""
    from datetime import datetime
    et = timezone.utc  # 简化版，真实应转换到 America/New_York
    now = datetime.now(et)
    return now.weekday() < 5 and (9 <= now.hour < 16)
