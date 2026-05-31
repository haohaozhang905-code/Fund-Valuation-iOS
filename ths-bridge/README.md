# THS Bridge

轻量 HTTP Bridge。iOS App 不直接请求同花顺/Westock/其他上游行情，而是请求本服务，由本服务完成上游适配、字段标准化、鉴权、缓存和错误归一。

## 运行

```bash
cp .env.example .env
# 编辑 .env，填入 TWELVE_DATA_API_KEY 后再启动
./run_local.sh
```

`run_local.sh` 会安装依赖、执行迁移，并用 `0.0.0.0:8787` 启动服务。这样模拟器和真机都能访问。

iOS 设置页选择：

- Provider: `THS Bridge`
- Bridge URL: `http://127.0.0.1:8787`
- Access Token: 默认可空；如果设置了 `BRIDGE_ACCESS_TOKEN`，这里填写同一个值

账号服务地址：

- 模拟器：`http://127.0.0.1:8787`
- 真机：`http://Mac.local:8787`，或 `http://<电脑局域网 IP>:8787`

## 环境变量

```text
BRIDGE_ACCESS_TOKEN=
THS_UPSTREAM_BASE_URL=
THS_UPSTREAM_TOKEN=
TWELVE_DATA_API_KEY=
WESTOCK_ENABLED=false
WESTOCK_MAX_CONCURRENCY=1
WESTOCK_SEARCH_TIMEOUT_SECONDS=15
WESTOCK_COMMAND_TIMEOUT_SECONDS=30
SEARCH_CACHE_TTL_SECONDS=300
SEARCH_MIN_QUERY_LENGTH=2
QUOTE_CACHE_TTL_SECONDS=60
KLINE_CACHE_TTL_SECONDS=3600
DATABASE_URL=sqlite:///./ths_bridge.db
JWT_SECRET=change-me
ACCESS_TOKEN_MINUTES=43200
```

`THS_UPSTREAM_BASE_URL` 保持泛化命名。上游可以是同花顺 iFinD、thsdk、Westock，或另一个已经封装好行情能力的 HTTP 服务。Bridge 的职责是把上游响应适配成 iOS 需要的统一字段。

普通美股优先走 Yahoo Finance 的轻量 HTTP 接口，不消耗 Twelve Data 额度。`TWELVE_DATA_API_KEY` 用于 OTC/缺口兜底，例如 `SIVEF` 这类 OTC Markets 代码。生产环境默认关闭 Westock，避免 Node 子进程打满内存。

搜索性能保护：

- `SEARCH_MIN_QUERY_LENGTH=2`：少于 2 个字符不触发后端搜索。
- `SEARCH_CACHE_TTL_SECONDS=300`：搜索结果缓存 5 分钟，重复输入不会重复打上游。
- `QUOTE_CACHE_TTL_SECONDS=60`：报价缓存 60 秒，避免添加/刷新持仓时重复打上游。
- `KLINE_CACHE_TTL_SECONDS=3600`：K 线缓存 1 小时。
- `WESTOCK_ENABLED=false`：默认关闭 Westock Node 子进程；只有 Twelve Data 不满足需求时再打开。
- `WESTOCK_MAX_CONCURRENCY=1`：打开 Westock 时限制 Node 子进程并发，避免搜索流量打满 CPU/内存。
- `WESTOCK_SEARCH_TIMEOUT_SECONDS=15`：搜索子进程 15 秒超时，失败后可走 Twelve Data 兜底。

获取 Twelve Data API Key：

1. 打开 https://twelvedata.com/ 并注册/登录。
2. 进入 Dashboard 或 API Keys 页面。
3. 复制默认 API Key。
4. 写入 `ths-bridge/.env`：

```text
TWELVE_DATA_API_KEY=你的key
```

生产部署时不要提交 `.env`，在 Zeabur/服务器环境变量里配置同名 `TWELVE_DATA_API_KEY`。

Zeabur 生产环境至少应配置：

```text
DATABASE_URL=sqlite:////app/data/ths_bridge.db
JWT_SECRET=<固定不变的强随机字符串>
TWELVE_DATA_API_KEY=<Twelve Data API Key>
WESTOCK_ENABLED=false
WESTOCK_MAX_CONCURRENCY=1
WESTOCK_SEARCH_TIMEOUT_SECONDS=15
SEARCH_CACHE_TTL_SECONDS=300
SEARCH_MIN_QUERY_LENGTH=2
QUOTE_CACHE_TTL_SECONDS=60
KLINE_CACHE_TTL_SECONDS=3600
```

注意 SQLite 绝对路径格式有 4 个斜杠：`sqlite:////app/data/ths_bridge.db`。如果写成 `sqlite:///app/data/ths_bridge.db`，SQLAlchemy 通常也会解析为 `/app/data/ths_bridge.db`，但生产配置建议使用标准绝对路径写法。

账号与持仓同步：

- 本地开发默认使用 `sqlite:///./ths_bridge.db`。
- 生产必须使用持久化数据库，推荐 PostgreSQL；如果继续用 SQLite，必须把 `ths_bridge.db` 放在持久卷中，并把 `DATABASE_URL` 指向该持久路径。
- 生产必须设置固定强随机 `JWT_SECRET`。如果部署后 `JWT_SECRET` 改变，旧登录 token 会全部失效，App 会回到登录态。
- 邮箱验证码第一版会写入服务日志；接真实邮件服务时替换 `mailer.py`。

部署后先检查：

```http
GET /health
```

确认 `auth.jwtSecretConfigured=true`，且每次部署后的 `auth.jwtSecretFingerprint` 不变；确认 `database.exists=true`，并且生产环境不要使用容器内相对 SQLite 路径。否则可能出现旧 token 失效、原账号查不到、只能重新注册的现象。

## App-facing API

```http
GET /v1/stocks/search?q=MU&market=US
GET /v1/stocks/quote?symbol=MU&market=US
GET /v1/stocks/kline?symbol=MU&market=US&count=120
POST /v1/auth/register
POST /v1/auth/login
POST /v1/auth/password-reset/request
POST /v1/auth/password-reset/confirm
GET /v1/portfolio
PUT /v1/portfolio
DELETE /v1/account
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
- 接入真实邮件发送 Provider，替换日志验证码。
- 生产环境改为 Alembic 管理迁移，不依赖启动时自动建表。
