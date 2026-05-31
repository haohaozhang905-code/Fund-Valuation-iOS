#!/bin/sh
set -eu

cd "$(dirname "$0")"

if [ -f ".env" ]; then
  set -a
  . ./.env
  set +a
fi

if [ ! -d ".venv" ]; then
  python3 -m venv .venv
fi

. .venv/bin/activate
pip install -r requirements.txt
alembic upgrade head

echo "Starting THS Bridge on:"
echo "  Simulator: http://127.0.0.1:8787"
echo "  Real device: http://Mac.local:8787 or http://<your-mac-lan-ip>:8787"
if [ -z "${TWELVE_DATA_API_KEY:-}" ]; then
  echo "  OTC fallback: disabled (set TWELVE_DATA_API_KEY in ths-bridge/.env)"
else
  echo "  OTC fallback: Twelve Data enabled"
fi
exec uvicorn app:app --host 0.0.0.0 --port 8787 --reload
