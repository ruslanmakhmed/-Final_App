# RUNBOOK

Команды выполняются из корня репозитория. Kubernetes: namespace `shortlink`, релиз Helm `shortlink`, реестр `localhost:5001`.

## Выкатка новой версии

```bash
git checkout main && git pull
git tag v1.1.0 && git push origin v1.1.0          # в GitHub Actions это запустит deploy

# либо вручную на стенде:
export REGISTRY=localhost:5001 IMAGE_TAG=v1.1.0
bash ci/run-stage.sh build
bash ci/run-stage.sh push
bash ci/run-stage.sh deploy

kubectl -n shortlink rollout status deploy/shortlink
kubectl -n shortlink get pods -L app.kubernetes.io/version
helm -n shortlink history shortlink
```

**Что происходит по шагам:** Deployment получает новый шаблон пода, и создаётся новый ReplicaSet. Из-за `maxSurge: 1` и `maxUnavailable: 0` сначала поднимается один новый под. Старый под удаляется только после того, как новый прошёл пробу готовности. Так повторяется, пока все поды не обновятся.

**Наблюдения** *(заполнить по факту: время, вывод `rollout status`, что было видно в `get pods -w`)*:

- …

## Откат

```bash
helm -n shortlink history shortlink                 # найти предыдущую рабочую ревизию
helm -n shortlink rollback shortlink <РЕВИЗИЯ> --wait
kubectl -n shortlink rollout status deploy/shortlink

# без Helm, только Deployment:
kubectl -n shortlink rollout undo deploy/shortlink
```

Почему откат быстрый: старый ReplicaSet никуда не делся (`revisionHistoryLimit: 5`), а образ уже лежит на узлах. Скачивать и собирать нечего, остаётся только перемасштабировать ReplicaSet.

**Наблюдения** *(заполнить по факту)*:

- …

## Логи

```bash
# Kubernetes
kubectl -n shortlink logs deploy/shortlink --tail=100 -f          # один под из Deployment
kubectl -n shortlink logs -l app.kubernetes.io/component=app --prefix --tail=50
kubectl -n shortlink logs <под> --previous                        # логи упавшего контейнера до перезапуска
kubectl -n shortlink get events --sort-by=.lastTimestamp | tail -n 20

# Compose
docker compose --project-directory compose logs -f --tail=100 app

# Узлы Ansible
sudo tail -f /var/log/nginx/shortlink.access.log /var/log/nginx/shortlink.error.log
journalctl -t shortlink-healthcheck --since "1 hour ago"
```

## Резервная копия

```bash
# Снять (архивы старше 7 дней удаляются)
bash scripts/backup.sh --keep-days 7                               # Compose
bash scripts/backup.sh --keep-days 7 --target k8s                  # Kubernetes
ls -lh backups/
```

Восстановить (дамп снят с `--clean --if-exists`, поэтому накатывается поверх существующей базы):

```bash
FILE=backups/shortlink-YYYYMMDD-HHMMSS.sql.gz

# Compose
gunzip -c "$FILE" | docker compose --project-directory compose exec -T db \
  sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

# Kubernetes
gunzip -c "$FILE" | kubectl -n shortlink exec -i statefulset/shortlink-db -- \
  sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Проверка: `curl -si http://shortlink.localhost:8081/r/<известный код>` должен вернуть 302.

## Масштабирование

```bash
# Постоянно — через values, чтобы следующий deploy не откатил изменение
#   k8s/shortlink/values-<env>.yaml: replicaCount: N
bash ci/run-stage.sh deploy

# Временно, без коммита (следующий helm upgrade вернёт значение из values)
kubectl -n shortlink scale deploy/shortlink --replicas=4
kubectl -n shortlink get pods -l app.kubernetes.io/component=app -w
```

База не масштабируется репликами: один экземпляр PostgreSQL в StatefulSet (см. DECISIONS.md).

## Полный подъём с нуля (репетиция защиты)

```bash
time (
  k3d cluster create --config k8s/k3d-cluster.yaml &&
  export REGISTRY=localhost:5001 DB_PASSWORD='<пароль>' &&
  bash ci/run-stage.sh build && bash ci/run-stage.sh push && bash ci/run-stage.sh deploy
)
```

Результаты прогонов по секундомеру: *(дата — время — что пошло не так)*

- …
