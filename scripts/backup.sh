#!/usr/bin/env bash
# backup.sh — дамп базы shortlink в архив с датой в имени и удаление старых архивов.
#
# Коды возврата:
#   0 — дамп снят, старые архивы удалены
#   1 — ошибка при снятии дампа
#   2 — неверные аргументы
#   3 — не хватает зависимостей
set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

KEEP_DAYS=""
BACKUP_DIR="$REPO_ROOT/backups"
TARGET="compose"
NAMESPACE="shortlink"
DB_STATEFULSET="shortlink-db"
TMP_FILE=""

usage() {
  cat <<EOF
Использование: $SCRIPT_NAME --keep-days N [параметры]

Снимает pg_dump базы shortlink в BACKUP_DIR/shortlink-ГГГГММДД-ЧЧММСС.sql.gz
и удаляет архивы старше N дней.

Обязательные параметры:
  --keep-days N        сколько дней хранить архивы (целое число, 0 — удалить все прежние)

Необязательные:
  --dir ПУТЬ           куда класть архивы (по умолчанию $BACKUP_DIR)
  --target ЦЕЛЬ        compose | k8s (по умолчанию $TARGET)
  --namespace ИМЯ      namespace для --target k8s (по умолчанию $NAMESPACE)
  -h, --help           показать эту справку

Восстановление — см. docs/RUNBOOK.md, раздел «Резервная копия».
EOF
}

die() { printf '%s: ОШИБКА: %s\n' "$SCRIPT_NAME" "$1" >&2; exit "${2:-1}"; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

cleanup() { [[ -n "$TMP_FILE" && -f "$TMP_FILE" ]] && rm -f "$TMP_FILE"; return 0; }
trap cleanup EXIT

need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 требует значение" 2; }

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -h | --help) usage; exit 0 ;;
      --keep-days) need_value "$@"; KEEP_DAYS="$2"; shift 2 ;;
      --dir) need_value "$@"; BACKUP_DIR="$2"; shift 2 ;;
      --target) need_value "$@"; TARGET="$2"; shift 2 ;;
      --namespace) need_value "$@"; NAMESPACE="$2"; shift 2 ;;
      *) usage >&2; die "неизвестный аргумент: $1" 2 ;;
    esac
  done
  [[ -n "$KEEP_DAYS" ]] || { usage >&2; die "не задан --keep-days" 2; }
  [[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || die "--keep-days должен быть целым неотрицательным числом, получено '$KEEP_DAYS'" 2
  [[ "$TARGET" =~ ^(compose|k8s)$ ]] || die "--target: ожидается compose или k8s" 2
}

# --clean --if-exists: дамп можно накатить поверх существующей базы при восстановлении.
# Переменные раскрываются внутри контейнера базы, а не здесь.
# shellcheck disable=SC2016
readonly DUMP_CMD='pg_dump --clean --if-exists -U "$POSTGRES_USER" "$POSTGRES_DB"'

dump() {
  case "$TARGET" in
    compose)
      docker compose --project-directory "$REPO_ROOT/compose" -f "$REPO_ROOT/compose/docker-compose.yml" \
        exec -T db sh -c "$DUMP_CMD"
      ;;
    k8s)
      kubectl -n "$NAMESPACE" exec "statefulset/$DB_STATEFULSET" -- sh -c "$DUMP_CMD"
      ;;
  esac
}

main() {
  parse_args "$@"
  local tool="docker"
  [[ "$TARGET" == "k8s" ]] && tool="kubectl"
  command -v "$tool" >/dev/null 2>&1 || die "не найден $tool" 3
  command -v gzip >/dev/null 2>&1 || die "не найден gzip" 3

  mkdir -p "$BACKUP_DIR"
  local final
  final="$BACKUP_DIR/shortlink-$(date +%Y%m%d-%H%M%S).sql.gz"
  TMP_FILE="$final.partial"

  log "Снимаю дамп ($TARGET) в $final"
  dump | gzip >"$TMP_FILE" || die "не удалось снять дамп базы"
  gzip -t "$TMP_FILE" || die "архив повреждён: $TMP_FILE"
  mv "$TMP_FILE" "$final"
  TMP_FILE=""
  log "Готово: $(du -h "$final" | cut -f1) $final"

  log "Удаляю архивы старше $KEEP_DAYS дн. в $BACKUP_DIR"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'shortlink-*.sql.gz' -mtime +"$KEEP_DAYS" ! -path "$final" -print -delete
}

main "$@"
