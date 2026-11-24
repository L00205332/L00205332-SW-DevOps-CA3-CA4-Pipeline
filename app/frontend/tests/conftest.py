"""Shared pytest fixtures for the frontend test suite. Unlike the backend,
there's no database swap needed here — test_routes.py mocks the HTTP calls
in backend_client.py directly with the `responses` library instead."""

import pytest

from app import app as flask_app
from backend_client import BACKEND_URL

BACKEND = BACKEND_URL


@pytest.fixture()
def client():
    flask_app.config.update(TESTING=True)
    return flask_app.test_client()
