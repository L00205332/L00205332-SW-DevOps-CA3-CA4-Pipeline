"""Shared pytest fixtures for the backend test suite.

The key trick: instead of running tests against real Postgres (which
would need Docker just to run `pytest`), we point the app at an
in-memory SQLite database for the duration of each test.
"""

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app import database
from app.database import get_db
from app.main import app

TEST_DATABASE_URL = "sqlite://"  # in-memory


@pytest.fixture()
def client():
    # check_same_thread=False + StaticPool: SQLite's in-memory database
    # normally lives inside one connection and is wiped if that connection
    # closes. StaticPool keeps a single connection alive and reuses it for
    # every session, so the same in-memory DB persists across the request
    # (and across TestClient's startup event) within one test.
    engine = create_engine(
        TEST_DATABASE_URL,
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

    # Swap the module-level engine/session so main.py's startup hook and
    # /healthz (which both look these up via `database.X`, not an imported
    # name — see main.py's comments) pick up SQLite instead of Postgres.
    database.engine = engine
    database.SessionLocal = TestingSessionLocal

    def override_get_db():
        db = TestingSessionLocal()
        try:
            yield db
        finally:
            db.close()

    # FastAPI dependency override: anywhere a route does Depends(get_db),
    # it gets override_get_db() instead, for the life of this fixture.
    app.dependency_overrides[get_db] = override_get_db

    # Using TestClient as a context manager fires FastAPI's startup event
    # (which creates the tables) and shutdown event, same as a real run.
    with TestClient(app) as test_client:
        yield test_client

    app.dependency_overrides.clear()
