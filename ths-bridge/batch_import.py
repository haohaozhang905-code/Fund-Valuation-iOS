#!/usr/bin/env python3
"""
批量导入持仓工具

使用方法：
  1. 准备一个 JSON 文件，格式见下方示例
  2. 运行脚本导入

示例 JSON (positions.json):
{
  "funds": [
    {"fundCode": "016665", "fundName": "示例基金A", "costPrice": 1.2345, "shares": 1000},
    {"fundCode": "110011", "fundName": "示例基金B", "costPrice": 2.3456, "shares": 500}
  ],
  "stocks": [
    {"symbol": "AAPL", "displayName": "Apple Inc.", "averageCost": 150.0, "shares": 10},
    {"symbol": "NVDA", "displayName": "NVIDIA Corp.", "averageCost": 128.4, "shares": 5}
  ]
}

运行：
  python3 batch_import.py positions.json your@email.com your_password
"""

import json
import sys
import uuid
from datetime import datetime, timezone

import requests


BASE_URL = "https://thsbridge.zeabur.app"


def login(email: str, password: str) -> str:
    resp = requests.post(
        f"{BASE_URL}/v1/auth/login",
        json={"email": email, "password": password},
        timeout=10,
    )
    if resp.status_code != 200:
        print(f"❌ 登录失败: {resp.status_code} {resp.text}")
        sys.exit(1)
    data = resp.json()
    print(f"✅ 登录成功: {data['user']['email']}")
    return data["accessToken"]


def load_positions(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    now = datetime.now(timezone.utc).isoformat()

    funds = []
    for f in data.get("funds", []):
        funds.append({
            "id": str(uuid.uuid4()),
            "fundCode": f["fundCode"],
            "fundName": f.get("fundName", ""),
            "costPrice": f["costPrice"],
            "shares": f["shares"],
            "clientUpdatedAt": now,
        })

    stocks = []
    for s in data.get("stocks", []):
        stocks.append({
            "id": str(uuid.uuid4()),
            "symbol": s["symbol"],
            "displayName": s.get("displayName", ""),
            "averageCost": s["averageCost"],
            "shares": s["shares"],
            "clientUpdatedAt": now,
        })

    return {"funds": funds, "stocks": stocks}


def upload(token: str, payload: dict) -> None:
    resp = requests.put(
        f"{BASE_URL}/v1/portfolio",
        json=payload,
        headers={"Authorization": f"Bearer {token}"},
        timeout=15,
    )
    if resp.status_code != 200:
        print(f"❌ 上传失败: {resp.status_code} {resp.text}")
        sys.exit(1)
    data = resp.json()
    print(f"✅ 上传成功: {len(data['funds'])} 只基金, {len(data['stocks'])} 只美股")


def main():
    if len(sys.argv) != 4:
        print("用法: python3 batch_import.py <positions.json> <email> <password>")
        sys.exit(1)

    path = sys.argv[1]
    email = sys.argv[2]
    password = sys.argv[3]

    print(f"📂 读取持仓文件: {path}")
    payload = load_positions(path)
    print(f"   基金: {len(payload['funds'])} 只")
    print(f"   美股: {len(payload['stocks'])} 只")

    if not payload["funds"] and not payload["stocks"]:
        print("⚠️  没有需要导入的持仓")
        return

    token = login(email, password)
    upload(token, payload)


if __name__ == "__main__":
    main()
