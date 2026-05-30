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


def test_login_success_and_failure() -> None:
    c = client()
    register(c)
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
