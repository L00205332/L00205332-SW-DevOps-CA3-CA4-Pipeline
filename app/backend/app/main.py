"""Application tier entry point: assembles the FastAPI app.

Run directly with `uvicorn app.main:app` (see the Dockerfile's CMD), or
imported by tests (tests/conftest.py) which swap the database out from
under it before the startup code fires.
"""

from contextlib import asynccontextmanager

from fastapi import FastAPI
from prometheus_fastapi_instrumentator import Instrumentator
from sqlalchemy import text

from app import database
from app.routers.tasks import router as tasks_router


@asynccontextmanager
async def lifespan(_app: FastAPI):
    """Runs once when the app starts (code before `yield`) and once when it
    stops (code after it). Replaces the deprecated @app.on_event("startup").

    `database` is used as a module (e.g. `database.engine`) rather than
    importing the name directly so tests can monkey-patch database.engine
    to a SQLite engine *before* this fires - see tests/conftest.py. A
    direct `from app.database import engine` would bind the original
    Postgres engine here permanently at import time.

    Note for production: auto-creating tables on every startup is a
    convenience for this assignment's scope, not a real migration strategy
    (Alembic would be the next step for a long-lived app).
    """
    database.Base.metadata.create_all(bind=database.engine)
    yield


app = FastAPI(title="Task Tracker API", lifespan=lifespan)

app.include_router(tasks_router)
# Auto-instruments every request (latency, status codes, in-flight count)
# and exposes it at /metrics for Prometheus to scrape - see monitoring/.
Instrumentator().instrument(app).expose(app, endpoint="/metrics")


@app.get("/healthz")
def healthz():
    """Liveness/readiness probe used by docker-compose healthchecks, the
    ECS/ALB target group, and the Jenkinsfile's post-deploy smoke test.
    Actually queries the DB (SELECT 1) rather than just returning 200, so
    "the process is running" and "the app can serve real requests" aren't
    conflated.
    """
    db = database.SessionLocal()
    try:
        db.execute(text("SELECT 1"))
        db_status = "up"
    except Exception:
        db_status = "down"
    finally:
        db.close()
    return {"status": "ok", "database": db_status}
