# ---- builder: install dependencies into an isolated venv ----
# Kept in its own stage so build tools / pip cache never end up in the
# final image — only the already-built venv gets copied forward.
FROM python:3.12-slim AS builder
WORKDIR /build

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---- runtime: copy only the venv + app code, run as non-root ----
FROM python:3.12-slim
RUN useradd --create-home --shell /bin/bash appuser

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY app ./app

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1

# Non-root: if this container is ever compromised, the attacker doesn't
# get root inside it either.
USER appuser
EXPOSE 8000

# Lets `docker ps` / docker-compose / ECS report this container as
# unhealthy if /healthz stops responding, without needing an external
# monitoring agent just to notice the process has wedged.
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')" || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
