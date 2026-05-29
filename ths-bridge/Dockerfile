# ---- 构建阶段 ----
FROM node:20-bookworm-slim AS node-base
RUN npm install -g westock-data-clawhub@1.0.4 && \
    npx -y westock-data-clawhub@1.0.4 hot 2>/dev/null || true

# ---- 运行阶段 ----
FROM python:3.11-slim

# 1) 安装 Node.js + npm（westock client 需要 npx）
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
       | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
       > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# 2) 从构建阶段拷贝预装的 npm 包，避免运行时 npx 下载
COPY --from=node-base /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=node-base /usr/local/bin/westock-data-clawhub /usr/local/bin/westock-data-clawhub 2>/dev/null || true
RUN npm install -g westock-data-clawhub@1.0.4 2>/dev/null || true

# 3) 安装 Python 依赖
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 4) 拷贝应用代码
COPY app.py .
COPY westock_client.py .

# 5) 暴露端口
EXPOSE 8787

# 6) 启动
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8787"]
