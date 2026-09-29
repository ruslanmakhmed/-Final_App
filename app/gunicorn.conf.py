import os

bind = f"0.0.0.0:{os.environ.get('APP_PORT', '8080')}"
# Метрики хранятся в памяти процесса: один воркер = один набор счётчиков на под.
# Параллельность даём потоками, масштабируем репликами.
workers = 1
threads = 4
# /tmp может быть только для чтения (readOnlyRootFilesystem в Kubernetes).
worker_tmp_dir = "/dev/shm"
# Строку на каждый запрос пишет само приложение, журнал доступа gunicorn не нужен.
accesslog = None
loglevel = os.environ.get("LOG_LEVEL", "info").lower()
graceful_timeout = 20
