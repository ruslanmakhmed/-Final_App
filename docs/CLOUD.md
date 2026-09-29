# Как это выглядело бы в AWS

Разбор письменный: аккаунт не заводился. Цель — один регион, два окружения (dev и prod), минимум ручного обслуживания.

## Сервисы под каждую часть

| Часть сейчас | В AWS | Почему |
|---|---|---|
| k3d | **EKS** (управляемый control plane), узлы — managed node group на 2–3 × `t3.medium` в приватных подсетях двух AZ | те же манифесты и Helm-чарт без переделки; control plane и его обновления — забота AWS |
| свой реестр | **ECR** с `imageTagMutability: IMMUTABLE` и сканированием при push | неизменяемые теги закрепляют правило «тег = версия»: перезаписать `v1.0.0` нельзя |
| PostgreSQL в StatefulSet | **RDS for PostgreSQL**, Multi-AZ в prod, одиночный инстанс в dev | см. ниже |
| traefik + NodePort 8081 | **AWS Load Balancer Controller** → ALB, сертификат из **ACM**, домен в **Route 53** | TLS и HTTPS без Let's Encrypt внутри кластера |
| nginx на узлах Ansible | не нужен: его роль выполняет ALB. Если нужен WAF, то **AWS WAF** на ALB | меньше серверов, которые надо патчить |
| Prometheus + Grafana | **Amazon Managed Service for Prometheus** + **Managed Grafana**; либо тот же стек в кластере | управляемые версии не теряют историю при пересоздании пода |
| Secret в кластере | **Secrets Manager** (пароль RDS с автоматической ротацией) + External Secrets Operator | секрет живёт вне кластера и ротируется без редеплоя образа |
| backup.sh | автоматические снапшоты RDS + point-in-time recovery на 7 дней | скрипт становится не нужен для основной базы |
| GitHub Actions | GitHub Actions как был (при необходимости self-hosted раннер в EKS) либо CodePipeline | инструмент не принципиален, важна схема lint → build → push → deploy |

## База: в кластере или управляемая

**За управляемую (RDS):** резервные копии, PITR, Multi-AZ с автоматическим переключением, минорные обновления и шифрование диска включаются настройками, а не пишутся самостоятельно. Кластер становится stateless: его можно пересоздать без риска для данных. В учебном проекте высокая доступность базы явно не входит в задачу, а в production это первое, что понадобится.

**Против:** стоимость (Multi-AZ примерно удваивает цену инстанса), меньше контроля над версиями и расширениями, привязка к AWS.

**База в кластере** оправдана для dev, для эфемерных окружений на каждый MR и для учебного стенда. **Вывод:** prod — RDS, dev — можно оставить StatefulSet ради цены.

## Доступ к облачным ресурсам без ключей в репозитории

- **Приложение в EKS → Secrets Manager / RDS:** IRSA или EKS Pod Identity. ServiceAccount пода связан с IAM-ролью, под получает временные учётные данные через web identity, и статических ключей нет нигде. Доступ к RDS — по паролю из Secrets Manager либо через IAM database authentication с токеном на 15 минут.
- **Конвейер → AWS:** OIDC-федерация GitHub Actions ↔ IAM (`aws-actions/configure-aws-credentials` с `permissions: id-token: write`). Задача получает JWT от GitHub и меняет его на временную роль через `AssumeRoleWithWebIdentity`. Доверие роли ограничено условием на `sub` (этот репозиторий и теги `v*`), поэтому deploy по тегу может пушить в ECR и обновлять EKS, а ветка — нет.
- **Люди:** IAM Identity Center (SSO), никаких долгоживущих access key.

## Что закрыто, что открыто

- **Наружу** открыт только ALB на 443 (80 перенаправляется на 443). Security group ALB: 0.0.0.0/0:443.
- **Узлы EKS** стоят в приватных подсетях. Входящий трафик — только от security group ALB, исходящий — через NAT Gateway (скачивание образов из ECR лучше вести через VPC endpoint).
- **RDS** в изолированных подсетях без маршрута в интернет. Security group принимает 5432 только от security group узлов (или подов, если включены security groups for pods).
- **API EKS** — приватный endpoint либо публичный с allowlist офисных адресов и адресов раннера.
- **Prometheus и Grafana** наружу не публикуются: доступ через SSO управляемой Grafana или `kubectl port-forward`.
- `/metrics` не маршрутизируется через ALB (правило Ingress только на `/api` и `/r`).

## Порядок месячной стоимости (prod, один регион)

| Позиция | ≈ $/мес |
|---|---|
| EKS control plane | 73 |
| 3 × t3.medium (on-demand) | 90 |
| RDS db.t4g.small Multi-AZ + 20 ГБ gp3 | 65 |
| ALB + немного трафика | 25 |
| NAT Gateway (1 шт.) + трафик | 40 |
| ECR, Secrets Manager, CloudWatch-логи, Route 53 | 15 |
| Managed Prometheus + Grafana (1 редактор) | 20 |
| **Итого** | **≈ 330** |

Самые крупные рычаги экономии: Savings Plans или spot для узлов (−30…60 % на EC2), один NAT на dev, RDS без Multi-AZ в dev. Для сервиса такого масштаба EKS избыточен: ECS Fargate или App Runner обошлись бы примерно в $60–100 в месяц, но тогда пропадает переносимость Helm-чарта. Это компромисс, который стоит обсуждать исходя из того, сколько сервисов будет рядом.
