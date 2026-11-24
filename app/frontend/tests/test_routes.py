"""Route tests for the Flask frontend. `@responses.activate` intercepts the
`requests` calls backend_client.py makes, so these never need a real
backend running.
"""

import requests
import responses

from backend_client import BACKEND_URL

SAMPLE_TASK = {
    "id": "11111111-1111-1111-1111-111111111111",
    "title": "Write report",
    "description": "CA3 writeup",
    "status": "todo",
    "created_at": "2026-01-01T00:00:00Z",
    "updated_at": "2026-01-01T00:00:00Z",
}


@responses.activate
def test_healthz_reports_backend_up(client):
    responses.get(f"{BACKEND_URL}/healthz", json={"status": "ok"}, status=200)

    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.get_json()["backend"] is True


@responses.activate
def test_healthz_reports_backend_down(client):
    responses.get(f"{BACKEND_URL}/healthz", status=500)

    response = client.get("/healthz")
    assert response.status_code == 503
    assert response.get_json()["backend"] is False


@responses.activate
def test_index_lists_tasks(client):
    responses.get(f"{BACKEND_URL}/api/tasks", json=[SAMPLE_TASK], status=200)

    response = client.get("/")
    assert response.status_code == 200
    assert b"Write report" in response.data


@responses.activate
def test_index_shows_error_when_backend_unreachable(client):
    # Simulate the backend being completely unreachable (not just erroring)
    # to exercise app.py's `except requests.RequestException` branch. It must
    # be the requests library's own ConnectionError: Python's built-in
    # ConnectionError is a different class and would not be caught there.
    responses.get(f"{BACKEND_URL}/api/tasks", body=requests.exceptions.ConnectionError())

    response = client.get("/")
    assert response.status_code == 200  # degraded, not a 500
    assert b"Could not reach the backend" in response.data


@responses.activate
def test_new_task_post_creates_and_redirects(client):
    responses.post(f"{BACKEND_URL}/api/tasks", json=SAMPLE_TASK, status=201)

    response = client.post(
        "/tasks/new", data={"title": "Write report", "description": "CA3 writeup"}
    )
    assert response.status_code == 302
    assert response.headers["Location"] == "/"


@responses.activate
def test_edit_task_get_renders_form(client):
    responses.get(f"{BACKEND_URL}/api/tasks/{SAMPLE_TASK['id']}", json=SAMPLE_TASK, status=200)

    response = client.get(f"/tasks/{SAMPLE_TASK['id']}/edit")
    assert response.status_code == 200
    assert b"Write report" in response.data


@responses.activate
def test_delete_task_redirects(client):
    responses.delete(f"{BACKEND_URL}/api/tasks/{SAMPLE_TASK['id']}", status=204)

    response = client.post(f"/tasks/{SAMPLE_TASK['id']}/delete")
    assert response.status_code == 302
    assert response.headers["Location"] == "/"
