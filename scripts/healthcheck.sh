#!/usr/bin/env bash
# healthcheck.sh — проверка состояния shortlink: готовность приложения, место на диске, контейнеры.
# Годится для cron/systemd-таймера: молчит на stdout при успехе с --quiet, пишет причину в stderr при сбое.
#
# Коды возврата:
#   0 — всё хорошо
#   1 — хотя бы одна проверка не прошла
#   2 — неверные аргументы
#   3 — не хватает зависимостей
set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"

URL="http://127.0.0.1:8080/readyz"
DISK_PATH="/"
DISK_MAX=90
CONTAINERS="auto"
PROJECT="shortlink"
QUIET=0

usage() {
  cat <<EOF
Использование: $SCRIPT_NAME [параметры]

Проверяет:
  - /readyz приложения отвечает 200;
  - занятое место на диске не выше порога;
  - все контейнеры compose-проекта запущены и не unhealthy.

Параметры:
  --url URL             адрес проверки готовности (по умолчанию $URL)
  --disk-path ПУТЬ      какой раздел проверять (по умолчанию $DISK_PATH)
  --disk-max ПРОЦЕНТ    порог занятого места, 1-100 (по умолчанию $DISK_MAX)
  --containers РЕЖИМ    auto | yes | no (по умолчанию $CONTAINERS;
                        auto — проверять, если на машине есть docker)
  --project ИМЯ         имя compose-проекта (по умолчанию $PROJECT)
  -q, --quiet           ничего не писать при успехе
  -h, --help            показать эту справку

Коды возврата: 0 — всё хорошо, 1 — проверка не прошла, 2 — неверные аргументы, 3 — нет зависимостей.
EOF
}

die() { printf '%s: ОШИБКА: %s\n' "$SCRIPT_NAME" "$1" >&2; exit "${2:-1}"; }
fail() { printf '%s: FAIL: %s\n' "$SCRIPT_NAME" "$*" >&2; FAILED=1; }
ok() { ((QUIET)) || printf 'OK: %s\n' "$*"; }

need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 требует значение" 2; }

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -h | --help) usage; exit 0 ;;
      -q | --quiet) QUIET=1; shift ;;
      --url) need_value "$@"; URL="$2"; shift 2 ;;
      --disk-path) need_value "$@"; DISK_PATH="$2"; shift 2 ;;
      --disk-max)
        need_value "$@"
        if ! [[ "$2" =~ ^[0-9]+$ ]] || (("$2" < 1 || "$2" > 100)); then
          die "--disk-max должен быть числом 1-100" 2
        fi
        DISK_MAX="$2"; shift 2 ;;
      --containers)
        need_value "$@"
        [[ "$2" =~ ^(auto|yes|no)$ ]] || die "--containers: ожидается auto, yes или no" 2
        CONTAINERS="$2"; shift 2 ;;
      --project) need_value "$@"; PROJECT="$2"; shift 2 ;;
      *) usage >&2; die "неизвестный аргумент: $1" 2 ;;
    esac
  done
}

check_ready() {
  local status
  status="$(curl -sS -o /dev/null -m 5 -w '%{http_code}' "$URL" 2>/dev/null)" || status="000"
  if [[ "$status" == "200" ]]; then
    ok "$URL ответил 200"
  else
    fail "$URL ответил $status (000 — нет соединения)"
  fi
}

check_disk() {
  [[ -e "$DISK_PATH" ]] || { fail "путь $DISK_PATH не существует"; return; }
  local used
  used="$(df -P "$DISK_PATH" | awk 'NR == 2 { sub("%", "", $5); print $5 }')"
  if ((used < DISK_MAX)); then
    ok "диск $DISK_PATH занят на ${used}% (порог ${DISK_MAX}%)"
  else
    fail "диск $DISK_PATH занят на ${used}%, порог ${DISK_MAX}%"
  fi
}

check_containers() {
  if [[ "$CONTAINERS" == "no" ]]; then
    return
  fi
  if ! command -v docker >/dev/null 2>&1; then
    [[ "$CONTAINERS" == "yes" ]] && die "docker не найден, а --containers yes" 3
    ok "docker на машине нет, проверка контейнеров пропущена"
    return
  fi

  local lines name state status bad=0
  lines="$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
    --format '{{.Names}}|{{.State}}|{{.Status}}')" || { fail "docker ps не выполнился"; return; }
  if [[ -z "$lines" ]]; then
    fail "контейнеров проекта $PROJECT нет"
    return
  fi
  while IFS='|' read -r name state status; do
    if [[ "$state" != "running" || "$status" == *"(unhealthy)"* ]]; then
      fail "контейнер $name: $state, $status"
      bad=1
    fi
  done <<<"$lines"
  ((bad)) || ok "все контейнеры проекта $PROJECT запущены"
}

main() {
  parse_args "$@"
  command -v curl >/dev/null 2>&1 || die "не найден curl" 3
  command -v df >/dev/null 2>&1 || die "не найден df" 3

  FAILED=0
  check_ready
  check_disk
  check_containers
  exit "$FAILED"
}

main "$@"
