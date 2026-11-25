"""Startup behaviour: the app must tolerate the database coming up late."""

import pytest
from sqlalchemy.exc import OperationalError

from app import main


def _connection_refused() -> OperationalError:
    return OperationalError("CREATE TABLE tasks", {}, Exception("connection refused"))


def test_create_tables_retries_until_database_is_ready(monkeypatch):
    calls = {"count": 0}

    def flaky_create_all(*_args, **_kwargs):
        calls["count"] += 1
        if calls["count"] < 3:
            raise _connection_refused()

    monkeypatch.setattr(main.database.Base.metadata, "create_all", flaky_create_all)
    monkeypatch.setattr(main.time, "sleep", lambda _seconds: None)  # don't really wait

    main._create_tables()

    assert calls["count"] == 3  # two failures, then success


def test_create_tables_gives_up_after_max_attempts(monkeypatch):
    def always_refused(*_args, **_kwargs):
        raise _connection_refused()

    monkeypatch.setattr(main.database.Base.metadata, "create_all", always_refused)
    monkeypatch.setattr(main.time, "sleep", lambda _seconds: None)

    with pytest.raises(OperationalError):
        main._create_tables(attempts=3)
