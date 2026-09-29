#!/usr/bin/env bash
# run-stage.sh — стадии конвейера доставки. Те же команды вызывает .github/workflows/ci.yml,
# поэтому локальный прогон и конвейер не расходятся.
#
#   ./ci/run-stage.sh lint | build | push | deploy
#
# Коды возврата: 0 — стадия прошла, 1 — стадия упала, 2 — неверные аргументы, 3 — нет зависимостей.
set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly CHART="$REPO_ROOT/k8s/shortlink"

# Всё настраивается переменными окружения; значения по умолчанию — для стенда Kubernetes (k3d).
REGISTRY="${REGISTRY:-localhost:5001}"
IMAGE="${IMAGE:-$REGISTRY/shortlink}"
NAMESPACE="${NAMESPACE:-shortlink}"
RELEASE="${RELEASE:-shortlink}"
DEPLOY_ENV="${DEPLOY_ENV:-dev}"
# Домен для Ingress: shortlink.<домен>, grafana.<домен>, prometheus.<домен>.
# localhost — для k3d; для кластера на ВМ — <IP узла>.nip.io.
INGRESS_DOMAIN="${INGRESS_DOMAIN:-localhost}"

usage() {
  cat <<EOF
Использование: $SCRIPT_NAME lint | build | push | deploy

Стадии:
  lint    shellcheck по скриптам, yamllint по YAML, ansible-lint по роли, helm lint по чарту
  build   сборка образа \$IMAGE:\$IMAGE_TAG
  push    отправка образа в реестр
  deploy  namespace, секреты, helm upgrade --install, мониторинг (kubectl apply -k)

Переменные окружения:
  IMAGE_TAG    тег образа (по умолчанию: тег git на HEAD, иначе короткий хеш коммита)
  REGISTRY     реестр (по умолчанию $REGISTRY), IMAGE — полное имя (по умолчанию \$REGISTRY/shortlink)
  DEPLOY_ENV   dev | prod — какой values-файл применять (по умолчанию $DEPLOY_ENV)
  DB_PASSWORD  пароль базы для Secret (если пусто — берётся из compose/.env,
               а при уже существующем Secret не меняется)
  INGRESS_DOMAIN  домен для адресов Ingress (по умолчанию $INGRESS_DOMAIN)
  NAMESPACE, RELEASE — namespace и имя релиза Helm (по умолчанию $NAMESPACE / $RELEASE)
EOF
}

log() { printf '[%s] [%s] %s\n' "$(date +%H:%M:%S)" "${STAGE:-?}" "$*"; }
die() { printf '%s: ОШИБКА: %s\n' "$SCRIPT_NAME" "$1" >&2; exit "${2:-1}"; }

require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "не найдена команда $cmd" 3
  done
}

image_tag() {
  if [[ -n "${IMAGE_TAG:-}" ]]; then
    echo "$IMAGE_TAG"
    return
  fi
  require git
  if git -C "$REPO_ROOT" describe --tags --exact-match >/dev/null 2>&1; then
    git -C "$REPO_ROOT" describe --tags --exact-match
  else
    git -C "$REPO_ROOT" rev-parse --short HEAD
  fi
}

stage_lint() {
  require shellcheck yamllint ansible-lint helm
  log "shellcheck"
  shellcheck "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/ci/*.sh

  log "yamllint"
  (cd "$REPO_ROOT" && yamllint --strict .)

  log "проверка, что vault.yml зашифрован"
  local vault="$REPO_ROOT/ansible/group_vars/all/vault.yml"
  [[ -f "$vault" ]] || die "нет $vault (см. README, раздел Ansible)"
  head -n1 "$vault" | grep -q '^[$]ANSIBLE_VAULT;' || die "$vault НЕ зашифрован — не коммитьте его"

  log "ansible-lint"
  (cd "$REPO_ROOT/ansible" && ansible-lint)

  log "helm lint (dev и prod)"
  helm lint "$CHART" -f "$CHART/values-dev.yaml"
  helm lint "$CHART" -f "$CHART/values-prod.yaml"
}

stage_build() {
  require docker
  local tag
  tag="$(image_tag)"
  log "сборка $IMAGE:$tag"
  docker build --pull -t "$IMAGE:$tag" "$REPO_ROOT/app"
}

stage_push() {
  require docker
  local tag
  tag="$(image_tag)"
  log "отправка $IMAGE:$tag"
  docker push "$IMAGE:$tag"
}

ensure_secret() {
  local name="$1" key="$2" value="$3"
  if [[ -z "$value" ]]; then
    kubectl -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1 && { log "Secret $name уже есть"; return; }
    die "нет значения для Secret $name и его нет в кластере"
  fi
  kubectl -n "$NAMESPACE" create secret generic "$name" --from-literal="$key=$value" \
    --dry-run=client -o yaml | kubectl apply -f -
}

stage_deploy() {
  require kubectl helm
  [[ "$DEPLOY_ENV" =~ ^(dev|prod)$ ]] || die "DEPLOY_ENV должен быть dev или prod" 2
  local tag db_password grafana_password
  tag="$(image_tag)"

  db_password="${DB_PASSWORD:-}"
  if [[ -z "$db_password" && -f "$REPO_ROOT/compose/.env" ]]; then
    db_password="$(sed -n 's/^DB_PASSWORD=//p' "$REPO_ROOT/compose/.env")"
  fi
  grafana_password="${GRAFANA_ADMIN_PASSWORD:-}"
  if [[ -z "$grafana_password" ]] && ! kubectl -n "$NAMESPACE" get secret grafana-admin >/dev/null 2>&1; then
    grafana_password="$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')"
    log "пароль admin для Grafana: kubectl -n $NAMESPACE get secret grafana-admin -o jsonpath='{.data.password}' | base64 -d"
  fi

  log "namespace $NAMESPACE"
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  log "секреты"
  ensure_secret shortlink-db DB_PASSWORD "$db_password"
  ensure_secret grafana-admin password "$grafana_password"

  log "helm upgrade --install $RELEASE ($DEPLOY_ENV, $IMAGE:$tag)"
  helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$NAMESPACE" \
    -f "$CHART/values-$DEPLOY_ENV.yaml" \
    --set image.repository="$IMAGE" \
    --set image.tag="$tag" \
    --set ingress.host="shortlink.$INGRESS_DOMAIN" \
    --wait --timeout 5m

  log "мониторинг"
  # В манифестах мониторинга хосты записаны как *.localhost — подставляем домен стенда.
  kubectl kustomize "$REPO_ROOT/monitoring" \
    | sed -e "s/host: grafana\.localhost$/host: grafana.$INGRESS_DOMAIN/" \
          -e "s/host: prometheus\.localhost$/host: prometheus.$INGRESS_DOMAIN/" \
    | kubectl apply -f -

  kubectl -n "$NAMESPACE" get pods -o wide
  log "приложение: http://shortlink.$INGRESS_DOMAIN  grafana: http://grafana.$INGRESS_DOMAIN  prometheus: http://prometheus.$INGRESS_DOMAIN"
}

main() {
  (($# == 1)) || { usage >&2; die "нужен ровно один аргумент — имя стадии" 2; }
  STAGE="$1"
  case "$STAGE" in
    -h | --help) usage ;;
    lint) stage_lint ;;
    build) stage_build ;;
    push) stage_push ;;
    deploy) stage_deploy ;;
    *) usage >&2; die "неизвестная стадия: $STAGE" 2 ;;
  esac
  log "стадия завершена"
}

main "$@"
