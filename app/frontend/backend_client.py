"""Every HTTP call the frontend makes to the backend lives in this one
module. Centralizing it here (instead of calling `requests` directly from
app.py's routes) is what lets tests/test_routes.py mock just this module's
calls instead of patching Flask internals.
"""

import os

import requests

# Read from the environment so docker-compose / Jenkins / Terraform can each
# point this at a different backend without touching code.
BACKEND_URL = os.environ.get("BACKEND_URL", "http://localhost:8000").rstrip("/")
TIMEOUT_SECONDS = 5


def list_tasks() -> list[dict]:
    response = requests.get(f"{BACKEND_URL}/api/tasks", timeout=TIMEOUT_SECONDS)
    response.raise_for_status()
    return response.json()


def get_task(task_id: str) -> dict:
    response = requests.get(f"{BACKEND_URL}/api/tasks/{task_id}", timeout=TIMEOUT_SECONDS)
    response.raise_for_status()
    return response.json()


def create_task(data: dict) -> dict:
    response = requests.post(f"{BACKEND_URL}/api/tasks", json=data, timeout=TIMEOUT_SECONDS)
    response.raise_for_status()
    return response.json()


def update_task(task_id: str, data: dict) -> dict:
    response = requests.put(
        f"{BACKEND_URL}/api/tasks/{task_id}", json=data, timeout=TIMEOUT_SECONDS
    )
    response.raise_for_status()
    return response.json()


def delete_task(task_id: str) -> None:
    response = requests.delete(f"{BACKEND_URL}/api/tasks/{task_id}", timeout=TIMEOUT_SECONDS)
    response.raise_for_status()


def backend_healthy() -> bool:
    """Used by this service's own /healthz — lets a load balancer or the
    pipeline's smoke test tell "frontend is up but backend is unreachable"
    apart from "everything is fine", instead of always returning 200.
    """
    try:
        response = requests.get(f"{BACKEND_URL}/healthz", timeout=TIMEOUT_SECONDS)
        return response.status_code == 200
    except requests.RequestException:
        return False
