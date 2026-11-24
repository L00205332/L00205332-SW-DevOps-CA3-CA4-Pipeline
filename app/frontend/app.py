"""Presentation tier: server-rendered Flask UI for the Task Tracker.

Deliberately plain (Jinja2 templates, no JS framework, no client-side
state) so the pipeline stays the focus of this assignment rather than the
UI. All actual data access goes through backend_client.py.
"""

import requests
from flask import Flask, redirect, render_template, request, url_for
from prometheus_flask_exporter import PrometheusMetrics

import backend_client as backend

app = Flask(__name__)
metrics = PrometheusMetrics(app)  # auto-exposes /metrics for Prometheus


@app.get("/healthz")
def healthz():
    """503 (not 200) when the backend is unreachable, so this container
    only looks "healthy" when it can actually do its job."""
    backend_up = backend.backend_healthy()
    status_code = 200 if backend_up else 503
    return {"status": "ok" if backend_up else "degraded", "backend": backend_up}, status_code


@app.get("/")
def index():
    try:
        tasks = backend.list_tasks()
        error = None
    except requests.RequestException:
        # Backend down shouldn't mean a 500 page — show the list page with
        # a banner instead, so the UI stays usable/debuggable.
        tasks = []
        error = "Could not reach the backend API."
    return render_template("index.html", tasks=tasks, error=error)


@app.route("/tasks/new", methods=["GET", "POST"])
def new_task():
    if request.method == "POST":
        backend.create_task(
            {
                "title": request.form["title"],
                "description": request.form.get("description") or None,
            }
        )
        return redirect(url_for("index"))
    # GET: just show the empty form.
    return render_template("task_form.html", task=None)


@app.route("/tasks/<task_id>/edit", methods=["GET", "POST"])
def edit_task(task_id: str):
    if request.method == "POST":
        backend.update_task(
            task_id,
            {
                "title": request.form["title"],
                "description": request.form.get("description") or None,
                "status": request.form["status"],
            },
        )
        return redirect(url_for("index"))
    # GET: fetch the current task so the form can be pre-filled.
    task = backend.get_task(task_id)
    return render_template("task_form.html", task=task)


@app.post("/tasks/<task_id>/delete")
def delete_task(task_id: str):
    backend.delete_task(task_id)
    return redirect(url_for("index"))


if __name__ == "__main__":
    # Dev-only entry point; the Dockerfile serves this with gunicorn instead.
    app.run(host="0.0.0.0", port=5000)
