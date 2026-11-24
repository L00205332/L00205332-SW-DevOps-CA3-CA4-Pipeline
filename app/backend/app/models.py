"""SQLAlchemy ORM model(s) — the shape of the data as stored in Postgres.

Deliberately separate from schemas.py (the API's Pydantic contract): the
database columns and the JSON a client sends/receives are allowed to
differ, even though today they happen to look similar.
"""

import enum
import uuid
from datetime import UTC, datetime

from sqlalchemy import DateTime, Enum, String
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class TaskStatus(str, enum.Enum):
    """The only three states a task can be in. `str` mixin so FastAPI/Pydantic
    serialize these as plain strings ("todo") instead of "TaskStatus.todo"."""

    todo = "todo"
    in_progress = "in_progress"
    done = "done"


def _utcnow() -> datetime:
    """Timezone-aware "now", used as the default for created_at/updated_at.

    A plain `datetime.now()` is naive (no timezone) and compares unreliably
    once data moves between machines/timezones, so we always attach UTC.
    """
    return datetime.now(UTC)


class Task(Base):
    __tablename__ = "tasks"

    # Stored as a string (not Postgres' native UUID type) to match
    # db/init.sql's VARCHAR(36) column — see that file for why.
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    description: Mapped[str | None] = mapped_column(String(2000), nullable=True)
    status: Mapped[TaskStatus] = mapped_column(
        Enum(TaskStatus), default=TaskStatus.todo, nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)
    # onupdate runs automatically every time this row is UPDATEd — no need
    # to set updated_at by hand anywhere in crud.py.
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow, onupdate=_utcnow
    )
