"""
THS Bridge —— 基于 westock-data-clawhub 的美股行情 HTTP 桥接服务
提供搜索、实时报价、日K 线接口供 iOS App 调用
"""
import logging
import os
import time
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import Depends, FastAPI, Header, HTTPException, status
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

import sys
# 优先同级目录加载 westock_client
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import westock_client as wc
from auth_service import (
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

app = FastAPI(title="THS Bridge", version="0.3.0")


@app.on_event("startup")
def startup() -> None:
    init_db()


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
    if user is None or not verify_password(payload.password, user.password_hash):
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
