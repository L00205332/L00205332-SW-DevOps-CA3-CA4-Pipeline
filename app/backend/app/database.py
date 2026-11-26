"""Database connection setup for the backend (the "data tier" client side).

Keeping this in one module means every other file imports `engine`,
`SessionLocal`, `Base`, or `get_db` from here instead of configuring its
own connection — one source of truth for how we talk to Postgres.
"""

import os

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

# DATABASE_URL is read from the environment so each place this app runs
# (docker-compose UAT, AWS prod) can point it at a different database
# without changing any code. The fallback is a local SQLite file, used only
# when running the app directly on a dev machine: it needs no server and,
# unlike a Postgres URL, contains no password (SonarQube Cloud flagged the
# previous credential-bearing default).
DATABASE_URL = os.environ.get("DATABASE_URL", "sqlite:///./local-dev.db")

# pool_pre_ping checks a connection is still alive before handing it to a
# request, instead of failing the request when it hits a connection that
# timed out while idle in the pool.
engine = create_engine(DATABASE_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


class Base(DeclarativeBase):
    """Base class every SQLAlchemy model (see models.py) inherits from."""

    pass


def get_db() -> Session:
    """FastAPI dependency: opens one DB session per request, closes it after.

    Using `yield` makes this a generator-based dependency — FastAPI runs the
    code before `yield` (open the session), hands the result to the route,
    then runs the code after `yield` (close it) once the route is done,
    success or failure.
    """
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
