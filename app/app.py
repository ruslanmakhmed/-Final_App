"""Shortlink — сервис коротких ссылок. Все настройки берутся из переменных окружения."""
import logging
import os
import secrets
import string
import sys
import threading
import time

import psycopg
from flask import Flask, g, jsonify, redirect, request


def required_env(name):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"missing required environment variable {name}")
    return value


DB = {
    "host": required_env("DB_HOST"),
    "port": os.environ.get("DB_PORT", "5432"),
    "dbname": required_env("DB_NAME"),
    "user": required_env("DB_USER"),
    "password": required_env("DB_PASSWORD"),
    "connect_timeout": 2,
}

logging.basicConfig(stream=sys.stdout, level=os.environ.get("LOG_LEVEL", "INFO").upper(),
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("shortlink")
app = Flask(__name__)

ALPHABET = string.ascii_letters + string.digits
COUNTERS = {
    "shortlink_links_created_total": "Short links created",
    "shortlink_redirects_total": "Successful redirects",
    "shortlink_redirects_not_found_total": "Redirects to a non-existent code",
}
counters = dict.fromkeys(COUNTERS, 0)
counters_lock = threading.Lock()
schema_ready = False


def inc(name):
    with counters_lock:
        counters[name] += 1


def db():
    """Новое соединение на запрос; таблица создаётся при первом успешном подключении."""
    global schema_ready
    conn = psycopg.connect(**DB, autocommit=True)
    if not schema_ready:
        try:
            conn.execute("CREATE TABLE IF NOT EXISTS links ("
                         "code varchar(16) PRIMARY KEY, url text NOT NULL, "
                         "hits bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now())")
        except (psycopg.errors.UniqueViolation, psycopg.errors.DuplicateTable):
            pass  # две реплики создавали таблицу одновременно — она уже есть
        schema_ready = True
    return conn


def db_ok():
    try:
        with db() as conn:
            conn.execute("SELECT 1")
        return True
    except psycopg.Error as exc:
        log.warning("database check failed: %s", exc)
        return False


@app.before_request
def start_timer():
    g.started = time.monotonic()


@app.after_request
def access_log(response):
    elapsed_ms = (time.monotonic() - g.started) * 1000
    log.info("%s %s %s %.1fms", request.method, request.path, response.status_code, elapsed_ms)
    return response


@app.errorhandler(psycopg.OperationalError)
def db_unavailable(exc):
    log.error("database unavailable: %s", exc)
    return jsonify(error="database unavailable"), 503


@app.post("/api/links")
def create_link():
    url = (request.get_json(silent=True) or {}).get("url")
    if not isinstance(url, str) or not url.startswith(("http://", "https://")):
        return jsonify(error="field 'url' must be an http(s) URL"), 400
    with db() as conn:
        for _ in range(5):
            code = "".join(secrets.choice(ALPHABET) for _ in range(7))
            cur = conn.execute("INSERT INTO links (code, url) VALUES (%s, %s) ON CONFLICT DO NOTHING", (code, url))
            if cur.rowcount:
                inc("shortlink_links_created_total")
                return jsonify(code=code), 201
    return jsonify(error="could not generate a unique code"), 500


@app.get("/r/<code>")
def follow(code):
    with db() as conn:
        row = conn.execute("UPDATE links SET hits = hits + 1 WHERE code = %s RETURNING url", (code,)).fetchone()
    if row is None:
        inc("shortlink_redirects_not_found_total")
        return jsonify(error="not found"), 404
    inc("shortlink_redirects_total")
    return redirect(row[0], code=302)


@app.get("/healthz")
def healthz():
    return "ok\n", 200


@app.get("/readyz")
def readyz():
    return ("ready\n", 200) if db_ok() else ("database unavailable\n", 503)


@app.get("/metrics")
def metrics():
    with counters_lock:
        snapshot = dict(counters)
    lines = []
    for name, help_text in COUNTERS.items():
        lines += [f"# HELP {name} {help_text}", f"# TYPE {name} counter", f"{name} {snapshot[name]}"]
    lines += ["# HELP shortlink_db_up 1 if the database answers, 0 otherwise",
              "# TYPE shortlink_db_up gauge", f"shortlink_db_up {int(db_ok())}"]
    return "\n".join(lines) + "\n", 200, {"Content-Type": "text/plain; version=0.0.4; charset=utf-8"}
