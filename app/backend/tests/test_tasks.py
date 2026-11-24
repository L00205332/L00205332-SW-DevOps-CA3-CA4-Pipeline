"""CRUD + validation tests for /api/tasks, run against the in-memory SQLite
DB set up by the `client` fixture in conftest.py (no Docker required).
"""


def test_healthz(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "database": "up"}


def test_create_and_list_tasks(client):
    create_response = client.post(
        "/api/tasks", json={"title": "Write report", "description": "CA3 writeup"}
    )
    assert create_response.status_code == 201
    created = create_response.json()
    assert created["title"] == "Write report"
    assert created["status"] == "todo"  # default status when none is given

    list_response = client.get("/api/tasks")
    assert list_response.status_code == 200
    tasks = list_response.json()
    assert len(tasks) == 1
    assert tasks[0]["id"] == created["id"]


def test_get_task_not_found(client):
    response = client.get("/api/tasks/does-not-exist")
    assert response.status_code == 404


def test_update_task(client):
    created = client.post("/api/tasks", json={"title": "Draft pipeline"}).json()

    # Partial update: only `status` is sent, so `title` must survive
    # untouched — this is what exercises crud.update_task's
    # exclude_unset=True behaviour.
    update_response = client.put(f"/api/tasks/{created['id']}", json={"status": "in_progress"})
    assert update_response.status_code == 200
    updated = update_response.json()
    assert updated["status"] == "in_progress"
    assert updated["title"] == "Draft pipeline"


def test_update_task_not_found(client):
    response = client.put("/api/tasks/does-not-exist", json={"status": "done"})
    assert response.status_code == 404


def test_delete_task(client):
    created = client.post("/api/tasks", json={"title": "Temporary"}).json()

    delete_response = client.delete(f"/api/tasks/{created['id']}")
    assert delete_response.status_code == 204

    get_response = client.get(f"/api/tasks/{created['id']}")
    assert get_response.status_code == 404


def test_create_task_validates_title(client):
    # Pydantic's min_length=1 on TaskCreate.title should reject this before
    # it ever reaches crud.create_task.
    response = client.post("/api/tasks", json={"title": ""})
    assert response.status_code == 422
