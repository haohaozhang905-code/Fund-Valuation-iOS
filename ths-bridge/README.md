# THS Bridge

轻量 HTTP Bridge。iOS App 不直接请求同花顺/Westock/其他上游行情，而是请求本服务，由本服务完成上游适配、字段标准化、鉴权、缓存和错误归一。

## 运行

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 127.0.0.1 --port 8787 --reload
```

iOS 设置页选择：

- Provider: `THS Bridge`
- Bridge URL: `http://127.0.0.1:8787`
- Access Token: 默认可空；如果设置了 `BRIDGE_ACCESS_TOKEN`，这里填写同一个值

## 环境变量

```text
BRIDGE_ACCESS_TOKEN=
THS_UPSTREAM_BASE_URL=
THS_UPSTREAM_TOKEN=
```

`THS_UPSTREAM_BASE_URL` 保持泛化命名。上游可以是同花顺 iFinD、thsdk、Westock，或另一个已经封装好行情能力的 HTTP 服务。Bridge 的职责是把上游响应适配成 iOS 需要的统一字段。

## App-facing API

```http
GET /v1/stocks/search?q=MU&market=US
GET /v1/stocks/quote?symbol=MU&market=US
GET /v1/stocks/kline?symbol=MU&market=US&count=120
```

行情响应建议字段：

```json
{
  "symbol": "MU",
  "name": "Micron Technology Inc.",
  "currency": "USD",
  "regularPrice": 123.45,
  "previousClose": 120.10,
  "change": 3.35,
  "changePercent": 2.79,
  "marketState": "regular",
  "regularTimestamp": "2026-05-28T14:32:10-04:00",
  "provider": "ths",
  "providerLabel": "同花顺",
  "isStale": false,
  "fetchedAt": "2026-05-28T18:32:11Z"
}
```

## 后续重点

- 接入稳定上游并完成字段映射。
- 增加 Bridge 侧缓存和限流。
- 增加批量报价接口，减少 iOS 多持仓并发请求。
- 统一错误码：鉴权失败、上游超时、限流、无数据、字段异常。
- 后续可承载支付宝基金截图 OCR 导入能力。

