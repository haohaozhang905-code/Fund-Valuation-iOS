import os
import sys
from pathlib import Path

os.environ["DATABASE_URL"] = "sqlite+pysqlite:///:memory:"
os.environ["JWT_SECRET"] = "test-secret"

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi.testclient import TestClient  # noqa: E402

from app import app  # noqa: E402
from database import Base, engine  # noqa: E402
from models import PasswordResetCode, utcnow  # noqa: E402
from sqlalchemy import select  # noqa: E402
from database import SessionLocal  # noqa: E402


def reset_db() -> None:
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)


def client() -> TestClient:
    reset_db()
    return TestClient(app)


def register(c: TestClient, email: str = "user@example.com") -> str:
    response = c.post("/v1/auth/register", json={"email": email, "password": "password123"})
    assert response.status_code == 201
    return response.json()["accessToken"]


def test_register_duplicate_email_rejected() -> None:
    c = client()
    register(c)
    duplicate = c.post("/v1/auth/register", json={"email": "USER@example.com", "password": "password123"})
    assert duplicate.status_code == 409


def test_health_exposes_deployment_diagnostics() -> None:
    response = client().get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["auth"]["jwtSecretConfigured"] is True
    assert body["auth"]["jwtSecretFingerprint"]
    assert body["database"]["kind"].startswith("sqlite")
    assert "warnings" in body


def test_login_success_and_failure() -> None:
    c = client()
    token = register(c)
    me = c.get("/v1/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert me.status_code == 200
    assert me.json()["email"] == "user@example.com"
    ok = c.post("/v1/auth/login", json={"email": "user@example.com", "password": "password123"})
    assert ok.status_code == 200
    assert ok.json()["accessToken"]
    bad = c.post("/v1/auth/login", json={"email": "user@example.com", "password": "wrongpass"})
    assert bad.status_code == 401


def test_reset_request_always_ok_and_confirm_single_use(monkeypatch) -> None:
    sent: list[tuple[str, str]] = []

    class FakeMailer:
        def send_password_reset_code(self, email: str, code: str) -> None:
            sent.append((email, code))

    import app as app_module

    monkeypatch.setattr(app_module, "mailer", FakeMailer())
    c = client()
    register(c)

    unknown = c.post("/v1/auth/password-reset/request", json={"email": "unknown@example.com"})
    assert unknown.status_code == 200
    assert sent == []

    requested = c.post("/v1/auth/password-reset/request", json={"email": "user@example.com"})
    assert requested.status_code == 200
    assert len(sent) == 1

    code = sent[0][1]
    confirmed = c.post(
        "/v1/auth/password-reset/confirm",
        json={"email": "user@example.com", "code": code, "newPassword": "newpassword123"},
    )
    assert confirmed.status_code == 200

    reused = c.post(
        "/v1/auth/password-reset/confirm",
        json={"email": "user@example.com", "code": code, "newPassword": "anotherpass123"},
    )
    assert reused.status_code == 400

    login = c.post("/v1/auth/login", json={"email": "user@example.com", "password": "newpassword123"})
    assert login.status_code == 200


def test_reset_code_attempt_limit() -> None:
    c = client()
    register(c)
    c.post("/v1/auth/password-reset/request", json={"email": "user@example.com"})
    for _ in range(5):
        response = c.post(
            "/v1/auth/password-reset/confirm",
            json={"email": "user@example.com", "code": "000000", "newPassword": "newpassword123"},
        )
        assert response.status_code == 400
    locked = c.post(
        "/v1/auth/password-reset/confirm",
        json={"email": "user@example.com", "code": "000000", "newPassword": "newpassword123"},
    )
    assert locked.status_code == 400


def test_reset_code_expiration() -> None:
    c = client()
    register(c)
    c.post("/v1/auth/password-reset/request", json={"email": "user@example.com"})
    with SessionLocal() as db:
        reset = db.scalar(select(PasswordResetCode))
        assert reset is not None
        reset.expires_at = utcnow().replace(year=2000)
        db.commit()
    expired = c.post(
        "/v1/auth/password-reset/confirm",
        json={"email": "user@example.com", "code": "000000", "newPassword": "newpassword123"},
    )
    assert expired.status_code == 400


def test_portfolio_owned_and_replaced_atomically() -> None:
    c = client()
    token_a = register(c, "a@example.com")
    token_b = register(c, "b@example.com")

    payload = {
        "funds": [{"id": "f1", "fundCode": "13841", "fundName": "Fund", "costPrice": 1.23, "shares": 100}],
        "stocks": [{"id": "s1", "symbol": "mu", "displayName": "Micron", "averageCost": 80, "shares": 2}],
    }
    saved = c.put("/v1/portfolio", json=payload, headers={"Authorization": f"Bearer {token_a}"})
    assert saved.status_code == 200
    assert saved.json()["funds"][0]["fundCode"] == "013841"
    assert saved.json()["stocks"][0]["symbol"] == "MU"

    other = c.get("/v1/portfolio", headers={"Authorization": f"Bearer {token_b}"})
    assert other.status_code == 200
    assert other.json()["funds"] == []
    assert other.json()["stocks"] == []

    bad = c.put(
        "/v1/portfolio",
        json={"funds": [{"id": "bad", "fundCode": "000001", "costPrice": 1, "shares": 1}], "stocks": []},
        headers={"Authorization": f"Bearer invalid"},
    )
    assert bad.status_code == 401

    duplicate = c.put(
        "/v1/portfolio",
        json={
            "funds": [
                {"id": "f1", "fundCode": "000001", "costPrice": 1, "shares": 1},
                {"id": "f2", "fundCode": "000001", "costPrice": 2, "shares": 2},
            ],
            "stocks": [],
        },
        headers={"Authorization": f"Bearer {token_a}"},
    )
    assert duplicate.status_code == 422

    after_bad = c.get("/v1/portfolio", headers={"Authorization": f"Bearer {token_a}"})
    assert len(after_bad.json()["funds"]) == 1
    assert len(after_bad.json()["stocks"]) == 1


def test_stock_search_uses_yahoo_before_twelve_or_westock(monkeypatch) -> None:
    import app as app_module

    with app_module._search_cache_lock:
        app_module._search_cache.clear()

    monkeypatch.setattr(app_module, "get_westock", lambda: (_ for _ in ()).throw(AssertionError("westock should not be imported")))
    monkeypatch.setattr(app_module, "twelve_symbol_search", lambda _query: (_ for _ in ()).throw(AssertionError("twelve should not be called")))
    monkeypatch.setattr(app_module, "yahoo_symbol_search", lambda _query: [{
        "symbol": "MU",
        "name": "Micron Technology",
        "displaySymbol": "MU.NASDAQ",
        "market": "NASDAQ",
        "type": "Common Stock",
        "isEquity": True,
    }])

    response = client().get("/v1/stocks/search", params={"q": "MU"})
    assert response.status_code == 200
    body = response.json()
    assert body["provider"] == "yahoo"
    assert body["items"][0]["symbol"] == "MU"


def test_stock_search_uses_twelve_data_when_yahoo_misses(monkeypatch) -> None:
    import app as app_module

    with app_module._search_cache_lock:
        app_module._search_cache.clear()

    monkeypatch.setattr(app_module, "get_westock", lambda: (_ for _ in ()).throw(AssertionError("westock should not be imported")))
    monkeypatch.setattr(app_module, "yahoo_symbol_search", lambda _query: [])
    monkeypatch.setattr(app_module, "twelve_symbol_search", lambda _query: [{
        "symbol": "SIVEF",
        "name": "Sivers Semiconductors AB (publ)",
        "displaySymbol": "SIVEF.OTC",
        "market": "OTC",
        "type": "Common Stock",
        "isEquity": True,
    }])

    response = client().get("/v1/stocks/search", params={"q": "SIVEF"})
    assert response.status_code == 200
    assert response.json()["provider"] == "twelvedata"


def test_stock_search_probes_exact_symbol_when_indexes_miss(monkeypatch) -> None:
    import app as app_module

    with app_module._search_cache_lock:
        app_module._search_cache.clear()

    monkeypatch.setattr(app_module, "get_westock", lambda: (_ for _ in ()).throw(AssertionError("westock should not be imported")))
    monkeypatch.setattr(app_module, "yahoo_symbol_search", lambda _query: [])
    monkeypatch.setattr(app_module, "twelve_symbol_search", lambda _query: [])
    monkeypatch.setattr(app_module, "twelve_quote", lambda _query: (_ for _ in ()).throw(AssertionError("twelve quote should not be called")))
    monkeypatch.setattr(app_module, "yahoo_quote", lambda _query: {
        "symbol": "SNXX",
        "name": "SNXX",
        "currency": "USD",
        "regularPrice": 25.0,
        "previousClose": 24.5,
        "change": 0.5,
        "changePercent": 2.0408,
        "marketState": "closed",
        "regularTimestamp": "2026-05-29",
        "extendedPrice": None,
        "extendedChange": None,
        "extendedChangePercent": None,
        "extendedTimestamp": None,
        "provider": "yahoo",
        "providerLabel": "Yahoo Finance",
        "isStale": False,
        "fetchedAt": app_module.now_iso(),
        "open": 24.6,
        "high": 25.2,
        "low": 24.4,
        "volume": 1000,
    })

    response = client().get("/v1/stocks/search", params={"q": "SNXX"})
    assert response.status_code == 200
    body = response.json()
    assert body["provider"] == "yahoo"
    assert body["items"][0]["symbol"] == "SNXX"


def test_stock_search_uses_symbol_override_when_indexes_and_probe_miss(monkeypatch) -> None:
    import app as app_module

    with app_module._search_cache_lock:
        app_module._search_cache.clear()

    monkeypatch.setattr(app_module, "get_westock", lambda: (_ for _ in ()).throw(AssertionError("westock should not be imported")))
    monkeypatch.setattr(app_module, "yahoo_symbol_search", lambda _query: [])
    monkeypatch.setattr(app_module, "twelve_symbol_search", lambda _query: [])
    monkeypatch.setattr(app_module, "yahoo_quote", lambda _query: None)
    monkeypatch.setattr(app_module, "twelve_quote", lambda _query: None)

    response = client().get("/v1/stocks/search", params={"q": "NASA"})
    assert response.status_code == 200
    body = response.json()
    assert body["provider"] == "override"
    assert body["items"][0]["symbol"] == "NASA"
    assert body["items"][0]["type"] == "ETF"


def test_short_stock_search_does_not_call_upstream(monkeypatch) -> None:
    import app as app_module

    monkeypatch.setattr(app_module, "get_westock", lambda: (_ for _ in ()).throw(AssertionError("westock should not be imported")))
    monkeypatch.setattr(app_module, "yahoo_symbol_search", lambda _query: (_ for _ in ()).throw(AssertionError("yahoo should not be called")))
    monkeypatch.setattr(app_module, "twelve_symbol_search", lambda _query: (_ for _ in ()).throw(AssertionError("twelve should not be called")))

    response = client().get("/v1/stocks/search", params={"q": "S"})
    assert response.status_code == 200
    assert response.json()["items"] == []


def test_stock_search_uses_cache(monkeypatch) -> None:
    import app as app_module

    with app_module._search_cache_lock:
        app_module._search_cache.clear()

    calls = {"count": 0}

    def fake_yahoo_search(_query: str) -> list[dict]:
        calls["count"] += 1
        return [{
            "symbol": "MU",
            "name": "Micron Technology",
            "displaySymbol": "MU.NASDAQ",
            "market": "NASDAQ",
            "type": "Common Stock",
            "isEquity": True,
        }]

    monkeypatch.setattr(app_module, "get_westock", lambda: (_ for _ in ()).throw(AssertionError("westock should not be imported")))
    monkeypatch.setattr(app_module, "yahoo_symbol_search", fake_yahoo_search)
    monkeypatch.setattr(app_module, "twelve_symbol_search", lambda _query: (_ for _ in ()).throw(AssertionError("twelve should not be called")))

    c = client()
    first = c.get("/v1/stocks/search", params={"q": "MU"})
    second = c.get("/v1/stocks/search", params={"q": "MU"})

    assert first.status_code == 200
    assert second.status_code == 200
    assert calls["count"] == 1
    assert first.json()["items"][0]["symbol"] == "MU"
    assert second.json()["items"][0]["symbol"] == "MU"


def test_stock_quote_uses_yahoo_before_twelve_or_westock(monkeypatch) -> None:
    import app as app_module

    with app_module._quote_cache_lock:
        app_module._quote_cache.clear()

    monkeypatch.setattr(app_module, "get_westock", lambda: (_ for _ in ()).throw(AssertionError("westock should not be imported")))
    monkeypatch.setattr(app_module, "twelve_quote", lambda _ticker: (_ for _ in ()).throw(AssertionError("twelve should not be called")))
    monkeypatch.setattr(app_module, "yahoo_quote", lambda _ticker: {
        "symbol": "MU",
        "name": "MU",
        "currency": "USD",
        "regularPrice": 80.0,
        "previousClose": 79.0,
        "change": 1.0,
        "changePercent": 1.2658,
        "marketState": "closed",
        "regularTimestamp": "2026-05-29",
        "extendedPrice": None,
        "extendedChange": None,
        "extendedChangePercent": None,
        "extendedTimestamp": None,
        "provider": "yahoo",
        "providerLabel": "Yahoo Finance",
        "isStale": False,
        "fetchedAt": app_module.now_iso(),
        "open": 79.5,
        "high": 81.0,
        "low": 79.0,
        "volume": 1000,
    })

    response = client().get("/v1/stocks/quote", params={"symbol": "MU"})
    assert response.status_code == 200
    body = response.json()
    assert body["provider"] == "yahoo"
    assert body["regularPrice"] == 80.0


def test_stock_quote_uses_twelve_data_when_yahoo_misses(monkeypatch) -> None:
    import app as app_module

    with app_module._quote_cache_lock:
        app_module._quote_cache.clear()

    monkeypatch.setattr(app_module, "get_westock", lambda: (_ for _ in ()).throw(AssertionError("westock should not be imported")))
    monkeypatch.setattr(app_module, "yahoo_quote", lambda _ticker: None)
    monkeypatch.setattr(app_module, "twelve_quote", lambda _ticker: {
        "symbol": "SIVEF",
        "name": "Sivers Semiconductors AB (publ)",
        "currency": "USD",
        "regularPrice": 0.1234,
        "previousClose": 0.12,
        "change": 0.0034,
        "changePercent": 2.8333,
        "marketState": "closed",
        "regularTimestamp": "2026-05-29",
        "extendedPrice": None,
        "extendedChange": None,
        "extendedChangePercent": None,
        "extendedTimestamp": None,
        "provider": "twelvedata",
        "providerLabel": "Twelve Data",
        "isStale": False,
        "fetchedAt": app_module.now_iso(),
        "open": 0.12,
        "high": 0.13,
        "low": 0.12,
        "volume": 1000,
    })

    response = client().get("/v1/stocks/quote", params={"symbol": "SIVEF"})
    assert response.status_code == 200
    body = response.json()
    assert body["provider"] == "twelvedata"
    assert body["regularPrice"] == 0.1234


def test_stock_kline_uses_yahoo_before_twelve_or_westock(monkeypatch) -> None:
    import app as app_module

    with app_module._kline_cache_lock:
        app_module._kline_cache.clear()

    monkeypatch.setattr(app_module, "get_westock", lambda: (_ for _ in ()).throw(AssertionError("westock should not be imported")))
    monkeypatch.setattr(app_module, "twelve_kline", lambda _ticker, _count: (_ for _ in ()).throw(AssertionError("twelve should not be called")))
    monkeypatch.setattr(app_module, "yahoo_kline", lambda _ticker, _count: {
        "symbol": "MU",
        "code": "MU",
        "count": 1,
        "items": [{
            "date": "2026-05-29",
            "open": 79.5,
            "high": 81.0,
            "low": 79.0,
            "close": 80.0,
            "volume": 1000,
            "changePercent": 0,
        }],
        "provider": "yahoo",
        "fetchedAt": app_module.now_iso(),
    })

    response = client().get("/v1/stocks/kline", params={"symbol": "MU", "count": 120})
    assert response.status_code == 200
    body = response.json()
    assert body["provider"] == "yahoo"
    assert body["items"][0]["close"] == 80.0


def test_stock_kline_uses_twelve_data_when_yahoo_misses(monkeypatch) -> None:
    import app as app_module

    with app_module._kline_cache_lock:
        app_module._kline_cache.clear()

    monkeypatch.setattr(app_module, "get_westock", lambda: (_ for _ in ()).throw(AssertionError("westock should not be imported")))
    monkeypatch.setattr(app_module, "yahoo_kline", lambda _ticker, _count: None)
    monkeypatch.setattr(app_module, "twelve_kline", lambda _ticker, _count: {
        "symbol": "SIVEF",
        "code": "SIVEF.OTC",
        "count": 1,
        "items": [{
            "date": "2026-05-29",
            "open": 0.12,
            "high": 0.13,
            "low": 0.12,
            "close": 0.1234,
            "volume": 1000,
            "changePercent": 0,
        }],
        "provider": "twelvedata",
        "fetchedAt": app_module.now_iso(),
    })

    response = client().get("/v1/stocks/kline", params={"symbol": "SIVEF", "count": 120})
    assert response.status_code == 200
    body = response.json()
    assert body["provider"] == "twelvedata"
    assert body["items"][0]["close"] == 0.1234
