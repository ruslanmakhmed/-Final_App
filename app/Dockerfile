# Python интерпретируемый — многоступенчатая сборка ничего не даст: колёса psycopg[binary]
# уже собраны, компилятор не нужен. Берём slim: glibc (колёса manylinux работают), ~50 МБ.
FROM python:3.12.7-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app

# Сначала зависимости: этот слой пересобирается только при изменении requirements.txt.
COPY requirements.txt .
RUN pip install -r requirements.txt

# Потом исходники: правка кода сбрасывает кэш только отсюда.
COPY gunicorn.conf.py healthcheck.py app.py ./

# Числовой UID, чтобы Kubernetes мог проверить runAsNonRoot.
USER 10001:10001

EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "healthcheck.py"]

CMD ["gunicorn", "--config", "gunicorn.conf.py", "app:app"]
