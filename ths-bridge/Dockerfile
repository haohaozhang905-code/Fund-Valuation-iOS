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

# 2) 预装 westock-data-clawhub，避免运行时 npx 下载
RUN npm install -g westock-data-clawhub@1.0.4

# 3) 安装 Python 依赖
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 4) 拷贝应用代码
COPY . .

# 5) 暴露端口
EXPOSE 8080

# 6) 启动
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
