#!/usr/bin/env bash
# bootstrap.sh — поднимает локальный стек shortlink (Docker Compose) с нуля на чистом стенде.
#
# Коды возврата:
#   0 — стек поднят, проверочный запрос прошёл
#   1 — ошибка во время работы (сборка, запуск, проверка)
#   2 — неверные аргументы
#   3 — не хватает зависимостей
set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly COMPOSE_DIR="$REPO_ROOT/compose"
readonly ENV_FILE="$COMPOSE_DIR/.env"

TIMEOUT=90

usage() {
  cat <<EOF
Использование: $SCRIPT_NAME [--timeout СЕКУНДЫ] [-h|--help]

Поднимает локальный стек shortlink с нуля:
  1. проверяет зависимости (docker, docker compose, curl, git);
  2. создаёт compose/.env из .env.example, если его нет (пароль базы — случайный);
  3. запускает свой реестр, собирает образ и кладёт его в реестр;
  4. запускает приложение и базу, ждёт готовности (/readyz);
  5. делает проверочный запрос: создаёт ссылку и переходит по ней.

Параметры:
  --timeout СЕКУНДЫ  сколько ждать готовности приложения (по умолчанию $TIMEOUT)
  -h, --help         показать эту справку
EOF
}

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '%s: ОШИБКА: %s\n' "$SCRIPT_NAME" "$1" >&2; exit "${2:-1}"; }

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -h | --help) usage; exit 0 ;;
      --timeout)
        [[ $# -ge 2 ]] || die "--timeout требует значение" 2
        [[ "$2" =~ ^[0-9]+$ ]] || die "--timeout должен быть целым числом, получено '$2'" 2
        TIMEOUT="$2"; shift 2 ;;
      *) usage >&2; die "неизвестный аргумент: $1" 2 ;;
    esac
  done
}

check_deps() {
  local cmd missing=()
  for cmd in docker curl git; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) || die "не найдены команды: ${missing[*]}" 3
  docker compose version >/dev/null 2>&1 || die "не найден плагин docker compose" 3
  docker info >/dev/null 2>&1 || die "Docker daemon недоступен (запущен ли docker, есть ли права?)" 3
}

image_tag() {
  git -C "$REPO_ROOT" describe --tags --exact-match 2>/dev/null \
    || git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null \
    || echo "dev"
}

# Заполняет переменную в .env, только если она там пустая.
set_default() {
  local key="$1" value="$2"
  sed -i "s|^${key}=\$|${key}=${value}|" "$ENV_FILE"
}

prepare_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    log "Создаю compose/.env из .env.example"
    cp "$COMPOSE_DIR/.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
  fi
  set_default REGISTRY "localhost:5000"
  set_default IMAGE_TAG "$(image_tag)"
  set_default DB_NAME "shortlink"
  set_default DB_USER "shortlink"
  set_default DB_PASSWORD "$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
  set_default APP_PORT "8080"
  set_default LOG_LEVEL "INFO"
  set_default HOST_PORT "8080"

  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
}

compose() { docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_DIR/docker-compose.yml" "$@"; }

wait_for() {
  local url="$1" deadline=$((SECONDS + TIMEOUT))
  until curl -fsS -o /dev/null "$url"; do
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
}

main() {
  parse_args "$@"
  check_deps
  prepare_env

  log "Запускаю реестр образов ($REGISTRY)"
  compose up -d registry
  wait_for "http://$REGISTRY/v2/" || die "реестр не ответил за ${TIMEOUT}с"

  log "Собираю образ $REGISTRY/shortlink:$IMAGE_TAG"
  compose build app
  log "Кладу образ в реестр"
  compose push app

  log "Запускаю приложение и базу"
  compose up -d

  log "Жду готовности http://localhost:$HOST_PORT/readyz (до ${TIMEOUT}с)"
  wait_for "http://localhost:$HOST_PORT/readyz" || {
    compose ps >&2
    compose logs --tail 30 app >&2
    die "приложение не стало готовым за ${TIMEOUT}с"
  }

  log "Проверочный запрос: создаю ссылку"
  local response code location
  response="$(curl -fsS -X POST -H 'Content-Type: application/json' \
    -d '{"url": "https://example.com/bootstrap-check"}' "http://localhost:$HOST_PORT/api/links")" \
    || die "POST /api/links не прошёл"
  code="$(sed -n 's/.*"code": *"\([A-Za-z0-9]*\)".*/\1/p' <<<"$response")"
  [[ -n "$code" ]] || die "в ответе нет кода: $response"

  location="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "http://localhost:$HOST_PORT/r/$code")"
  [[ "$location" == "302 https://example.com/bootstrap-check" ]] || die "ожидал 302 на example.com, получил: $location"

  log "Готово: /r/$code -> $location"
  log "Стек поднят. Остановка: docker compose --project-directory compose down"
}

main "$@"
