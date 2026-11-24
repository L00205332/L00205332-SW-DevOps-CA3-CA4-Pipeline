"""Pydantic models — the API's actual contract with clients.

FastAPI uses these for request validation, response serialization, and to
auto-generate the OpenAPI docs. They're kept separate from models.py (the
DB layer) on purpose, even though the fields overlap right now.
"""

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field

from app.models import TaskStatus


class TaskCreate(BaseModel):
    """What a client sends to POST /api/tasks. No id/timestamps — the
    server assigns those."""

    title: str = Field(min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=2000)
    status: TaskStatus = TaskStatus.todo


class TaskUpdate(BaseModel):
    """What a client sends to PUT /api/tasks/{id}. Every field is optional
    so a client can change just the status without resending the title —
    crud.update_task() only applies the fields that were actually set
    (`exclude_unset=True`)."""

    title: str | None = Field(default=None, min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=2000)
    status: TaskStatus | None = None


class TaskOut(BaseModel):
    """What the API returns. `from_attributes=True` lets Pydantic read these
    fields straight off a SQLAlchemy Task object (model_validate / FastAPI's
    response_model), instead of requiring a dict."""

    model_config = ConfigDict(from_attributes=True)

    id: str
    title: str
    description: str | None
    status: TaskStatus
    created_at: datetime
    updated_at: datetime
