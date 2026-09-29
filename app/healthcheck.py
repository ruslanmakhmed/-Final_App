"""HEALTHCHECK для Docker: в slim-образе нет curl, поэтому проверяем /healthz стандартной библиотекой."""
import os
import sys
import urllib.request

url = f"http://127.0.0.1:{os.environ.get('APP_PORT', '8080')}/healthz"
try:
    with urllib.request.urlopen(url, timeout=2) as response:
        sys.exit(0 if response.status == 200 else 1)
except Exception:  # noqa: BLE001 — любой сбой означает «нездоров»
    sys.exit(1)
