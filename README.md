# shortlink

Shortlink — сервис коротких ссылок. `POST /api/links` сохраняет длинный адрес в PostgreSQL и возвращает короткий код, а `GET /r/<код>` отвечает редиректом 302 и считает переходы.
Приложение нарочно маленькое (Python/Flask). Весь репозиторий — это инфраструктура вокруг него: контейнер, Compose, Ansible-роль для фронтового узла, Helm-чарт для Kubernetes (k3d), конвейер из четырёх стадий, Prometheus и Grafana.
Любая часть поднимается с нуля командами из этого файла.

## Что с чем разговаривает

```
                        ┌──────────────── стенд Kubernetes (k3d) ─────────────────────┐
 curl / браузер ──:8081─►  traefik Ingress ─► Service shortlink ─► Deployment (2+ пода) │
                        │   │                                     │  env: ConfigMap,     │
                        │   │                                     │       Secret         │
                        │   │                                     ▼                      │
                        │   │                      Service shortlink-db ─► StatefulSet   │
                        │   │                                               postgres+PVC │
                        │   ├─► grafana.localhost ─► Grafana ─► Prometheus ─┐            │
                        │   └─► prometheus.localhost ─────────────┘  scrape │ /metrics   │
                        │                                          каждого пода + cAdvisor│
                        └─────────────────────────────────────────────────────────────┘
 узлы Ansible:  nginx :80  ──proxy──►  бэкенд (Compose :8080 или Ingress :8081)
 стенд Docker:  compose: app ─► db (postgres, том dbdata) ;  registry :5000
```

## Адреса приложения

| Адрес | Поведение |
|---|---|
| `POST /api/links` | `{"url": "https://..."}` → `201 {"code": "Ab3dE9x"}`, 400 для не-http(s) адреса |
| `GET /r/<код>` | 302 на исходный адрес и +1 к счётчику; 404, если кода нет |
| `GET /healthz` | 200, пока процесс жив (проба живости) |
| `GET /readyz` | 200, если база отвечает, иначе 503 (проба готовности) |
| `GET /metrics` | метрики Prometheus: `shortlink_links_created_total`, `shortlink_redirects_total`, `shortlink_redirects_not_found_total`, `shortlink_db_up` |

## Переменные окружения

| Имя | Назначение | По умолчанию | Обязательна |
|---|---|---|---|
| `DB_HOST` | адрес базы (DNS-имя сервиса) | — | да |
| `DB_PORT` | порт базы | `5432` | нет |
| `DB_NAME` | имя базы | — | да |
| `DB_USER` | пользователь базы | — | да |
| `DB_PASSWORD` | пароль базы (в Kubernetes — из Secret) | — | да |
| `APP_PORT` | порт HTTP внутри контейнера | `8080` | нет |
| `LOG_LEVEL` | `DEBUG` / `INFO` / `WARNING` | `INFO` | нет |

Только для Compose (`compose/.env`): `REGISTRY` (`localhost:5000`), `IMAGE_TAG` (тег git или хеш коммита), `HOST_PORT` (`8080`).
Без обязательной переменной приложение сразу завершается и пишет, какой переменной не хватает.

---

## 0. Подготовка (любой стенд)

```bash
git clone <URL репозитория> shortlink && cd shortlink
# На Windows git не сохраняет бит исполнения, поэтому скрипты запускаются через bash.
```

## 1. Локальный стек (стенд Docker)

Нужны `docker` с плагином `compose`, `curl`, `git`.

```bash
bash scripts/bootstrap.sh
```

Скрипт создаёт `compose/.env` со случайным паролем базы, поднимает свой реестр на `localhost:5000`, собирает образ и кладёт его в реестр, запускает приложение и базу, ждёт `/readyz` и делает проверочный запрос.

Проверка вручную:

```bash
CODE=$(curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com"}' http://localhost:8080/api/links | sed 's/.*"code":"\([^"]*\)".*/\1/')
curl -si http://localhost:8080/r/$CODE | head -n 3                   # 302, Location: https://example.com

docker compose --project-directory compose down                     # том dbdata остаётся
docker compose --project-directory compose up -d
curl -si http://localhost:8080/r/$CODE | head -n 1                   # всё ещё 302
```

Образ из реестра, а не из локального кэша:

```bash
source compose/.env
docker image rm $REGISTRY/shortlink:$IMAGE_TAG
docker pull $REGISTRY/shortlink:$IMAGE_TAG
curl -s http://localhost:5000/v2/shortlink/tags/list
```

Обслуживание: `bash scripts/healthcheck.sh --help`, `bash scripts/backup.sh --keep-days 7`.

## 2. Узлы (стенд Ansible)

Нужны `ansible-core` ≥ 2.15, `ansible-lint`, SSH-доступ к узлам **по ключу** (роль отключает вход по паролю).

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml

# Один раз на управляющей машине (всё лежит в домашней папке и переживает пересоздание стенда):
[ -f ~/.ssh/shortlink_deploy ] || ssh-keygen -t ed25519 -f ~/.ssh/shortlink_deploy -N "" -q
[ -f ~/.vault_pass ] || { read -rsp 'Vault password: ' p; printf '%s' "$p" > ~/.vault_pass; chmod 600 ~/.vault_pass; }

# Адреса узлов и бэкенда: inventory/hosts.yml и group_vars/edge_*.yml
ansible all -m ping

ansible-playbook site.yml --check --diff        # сухой прогон
ansible-playbook site.yml                        # настройка
ansible-playbook site.yml                        # повтор: должно быть changed=0
ansible-lint
```

Файл секретов `group_vars/all/vault.yml` лежит в репозитории зашифрованным. Если репозиторий новый и файла ещё нет:

```bash
cp vault.yml.example group_vars/all/vault.yml   # впишите свой токен
ansible-vault encrypt group_vars/all/vault.yml
ansible-vault view group_vars/all/vault.yml     # проверить
```

Проверка на узле: `curl -si http://<узел>/healthz`, `curl -s -H "X-Metrics-Token: <токен>" http://<узел>/metrics`.

## 3. Кластер (стенд Kubernetes)

Нужны `docker`, `k3d` ≥ 5.6, `kubectl`, `helm` ≥ 3.14.

```bash
k3d cluster create --config k8s/k3d-cluster.yaml     # кластер + реестр localhost:5001 + порт 8081 на Ingress
kubectl get ingressclass                               # ожидаем traefik

export REGISTRY=localhost:5001
export DB_PASSWORD='<пароль базы>'                     # один раз; дальше Secret уже в кластере
bash ci/run-stage.sh build
bash ci/run-stage.sh push
bash ci/run-stage.sh deploy                            # DEPLOY_ENV=prod — 3 реплики и prod-лимиты
```

Проверка (`*.localhost` резолвится в 127.0.0.1 без правки `/etc/hosts`):

```bash
kubectl -n shortlink get pods,svc,ingress,pvc
CODE=$(curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com"}' http://shortlink.localhost:8081/api/links | sed 's/.*"code":"\([^"]*\)".*/\1/')
curl -si http://shortlink.localhost:8081/r/$CODE | head -n 3
```

Если `shortlink.localhost` не резолвится, используйте `curl -H 'Host: shortlink.localhost' http://127.0.0.1:8081/...`.

Мониторинг: Grafana — http://grafana.localhost:8081 (дашборд «Shortlink» открывается сразу), Prometheus — http://prometheus.localhost:8081/targets (цели `shortlink` должны быть в состоянии **UP**), алерты — http://prometheus.localhost:8081/alerts.

Удалить всё: `k3d cluster delete shortlink`.

### Вариант: ВМ AlmaLinux 9 + готовый кластер k3s

| ВМ | Роль |
|---|---|
| 192.168.1.25 | Docker: Compose-стек, свой реестр `:5000`; управляющий узел Ansible; отсюда запускаются стадии конвейера; фронт dev |
| 192.168.1.26 | фронт prod (nginx → Ingress k3s) |
| 192.168.1.22–24 | k3s: master + 2 worker, traefik на порту 80 всех узлов |

Всё выполняется на 192.168.1.25 под root:

```bash
# инструменты (один раз, всё в домашней папке)
dnf install -y python3.11 ShellCheck
python3.11 -m venv ~/.venvs/ci && ~/.venvs/ci/bin/pip install ansible-core==2.17.5 ansible-lint==24.9.2 yamllint==1.35.1
mkdir -p ~/bin && curl -fsSL https://get.helm.sh/helm-v3.16.2-linux-amd64.tar.gz | tar -xz -C ~/bin --strip-components=1 linux-amd64/helm
curl -fsSLo ~/bin/kubectl https://dl.k8s.io/release/v1.36.4/bin/linux/amd64/kubectl && chmod +x ~/bin/kubectl
export PATH=$HOME/bin:$HOME/.venvs/ci/bin:$PATH
ssh root@192.168.1.22 cat /etc/rancher/k3s/k3s.yaml | sed 's#127.0.0.1#192.168.1.22#' > ~/.kube/config

# 1. стек Docker и реестр
./scripts/bootstrap.sh

# 2. узлы k3s тянут образы из реестра на .25 (registries.yaml), затем фронтовые узлы
cd ansible && ansible-galaxy collection install -r requirements.yml
ansible-playbook k3s-registry.yml
ansible-playbook site.yml -e ansible_user=root -e ansible_ssh_private_key_file=none   # только первый раз
ansible-playbook site.yml                                                             # дальше как shortlink
cd ..

# 3. кластер
export REGISTRY=localhost:5000 DEPLOY_ENV=prod INGRESS_DOMAIN=192.168.1.22.nip.io
./ci/run-stage.sh build && ./ci/run-stage.sh push && ./ci/run-stage.sh deploy
```

Адреса: http://shortlink.192.168.1.22.nip.io, http://grafana.192.168.1.22.nip.io, http://prometheus.192.168.1.22.nip.io/targets. Через фронт prod: http://192.168.1.26. Через фронт dev (Compose): http://192.168.1.25.

## 4. Конвейер

Конвейер описан в двух файлах, и оба вызывают `ci/run-stage.sh <стадия>`, поэтому локальный прогон и конвейер выполняют одни и те же команды:

- `.gitlab-ci.yml` — основной: свой GitLab CE (http://192.168.1.26:8929) и раннер `shortlink` (shell executor) на 192.168.1.25, где есть Docker, свой реестр и доступ к k3s. Все четыре стадии, включая deploy, выполняются по-настоящему;
- `.github/workflows/ci.yml` — то же самое для GitHub (зеркало репозитория). Deploy там пропускается: кластер из интернета не виден.

### Свой GitLab и раннер

```bash
cd ansible
ansible-playbook gitlab.yml                                          # GitLab CE на .26 (swap 4 ГБ, порт 8929), ~20 минут
# Пароль root GitLab: ansible-vault view group_vars/all/vault.yml
# В GitLab: Admin → CI/CD → Runners → New instance runner, тег shortlink → скопировать токен glrt-...
ansible-playbook gitlab-runner.yml -e gitlab_runner_token=glrt-...   # раннер, kubectl, helm, линтеры на .25
```

Переменные проекта в GitLab (Settings → CI/CD → Variables):

| Переменная | Тип | Значение |
|---|---|---|
| `ANSIBLE_VAULT_PASSWORD` | Variable, masked | содержимое `~/.vault_pass` |
| `KUBECONFIG` | File | kubeconfig кластера (сервер `https://192.168.1.22:6443`) |
| `DB_PASSWORD` | Variable, masked | пароль базы (нужен, только если Secret `shortlink-db` ещё не создан) |

### GitHub Actions

`.github/workflows/ci.yml`: lint → build → push → deploy.

- **lint и build** — на каждый push в `main`, на теги и на pull request;
- **push** — в GitHub Container Registry (`ghcr.io/<владелец>/shortlink`), только из `main` и по тегам, из pull request не публикуется;
- **deploy** — только по тегу `vX.Y.Z`: в кластер попадает осознанно выпущенная версия, а не каждый коммит.

Тег образа — это тег git (`v1.0.0`) или короткий хеш коммита. Тега `latest` нет нигде.

Секреты репозитория (Settings → Secrets and variables → Actions):

| Секрет | Для чего | Обязателен |
|---|---|---|
| `ANSIBLE_VAULT_PASSWORD` | ansible-lint расшифровывает `vault.yml` | да, для lint |
| `KUBECONFIG` | содержимое kubeconfig кластера, доступного из интернета | нет: без него deploy пропускается |
| `DB_PASSWORD` | пароль базы для Secret в кластере | вместе с `KUBECONFIG` |

Учебный кластер k3d из интернета не виден, поэтому на стендах стадия deploy выполняется той же командой вручную: `./ci/run-stage.sh deploy`. Образ для кластера k3d берётся из его локального реестра (`REGISTRY=localhost:5001`), а не из ghcr.io.

Локально: `bash ci/run-stage.sh lint`. Нужны `shellcheck`, `yamllint`, `ansible-lint`, `helm` и `~/.vault_pass`.

## Частые проблемы

| Симптом | Причина и что делать |
|---|---|
| `bootstrap.sh`: `Docker daemon недоступен` | пользователь не в группе `docker` или демон не запущен: `sudo systemctl start docker`, `sudo usermod -aG docker $USER` и перелогиниться |
| `/readyz` отвечает 503, `/healthz` отвечает 200 | приложение живо, но нет базы: `docker compose --project-directory compose ps`, `kubectl -n shortlink get pods -l app.kubernetes.io/component=db`, затем логи базы |
| поды в `ImagePullBackOff` | образа с таким тегом нет в реестре: `curl -s localhost:5001/v2/shortlink/tags/list`, затем `bash ci/run-stage.sh push` с тем же `IMAGE_TAG` |
| `curl http://shortlink.localhost:8081` → connection refused | кластер создан без проброса порта: пересоздать по `k8s/k3d-cluster.yaml` |
| Prometheus: цели `shortlink` DOWN или их нет | метки подов или имя порта (`http`) не совпадают с `relabel_configs`: `kubectl -n shortlink get pods --show-labels` |
| Ansible: второй прогон даёт changed≠0 | найти задачу по выводу `--diff`; обычно в ней `command`/`shell` без `changed_when` или шаблон с меняющимся содержимым |
| `bad interpreter: /bin/bash^M` | скрипт сохранён с CRLF: `.gitattributes` принудительно ставит LF; `git add --renormalize .` |

Документы: [RUNBOOK](docs/RUNBOOK.md) · [DECISIONS](docs/DECISIONS.md) · [INCIDENT](docs/INCIDENT.md) · [CLOUD](docs/CLOUD.md)
