# ---- builder: install dependencies into an isolated venv ----
FROM python:3.12-slim AS builder
WORKDIR /build

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
# --only-binary: install prebuilt wheels only, so no package's setup script
# can run arbitrary code at build time (SonarQube Cloud rule docker:S8541).
RUN pip install --no-cache-dir --only-binary :all: -r requirements.txt

# ---- runtime: copy only the venv + app code, run as non-root ----
FROM python:3.12-slim
RUN useradd --create-home --shell /bin/bash appuser

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY app.py backend_client.py ./
COPY templates ./templates
COPY static ./static

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1

USER appuser
EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/healthz')" || exit 1

# gunicorn, not Flask's own dev server — Flask's built-in server isn't
# meant for anything but local development (no concurrency, no process
# management).
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]
