"""Database operations for Task, kept separate from the HTTP route layer.

Routers (routers/tasks.py) only deal with HTTP concerns (status codes,
request/response bodies); these functions only deal with SQLAlchemy. That
split is what makes it easy to unit-test either layer without the other.
"""

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import Task
from app.schemas import TaskCreate, TaskUpdate


def list_tasks(db: Session) -> list[Task]:
    return list(db.scalars(select(Task).order_by(Task.created_at)))


def get_task(db: Session, task_id: str) -> Task | None:
    # Session.get() is a primary-key lookup — returns None if not found,
    # rather than raising, so callers decide what a missing task means.
    return db.get(Task, task_id)


def create_task(db: Session, data: TaskCreate) -> Task:
    task = Task(title=data.title, description=data.description, status=data.status)
    db.add(task)
    db.commit()
    db.refresh(task)  # pulls back server-generated fields: id, timestamps
    return task


def update_task(db: Session, task: Task, data: TaskUpdate) -> Task:
    # exclude_unset=True means only the fields the client actually sent end
    # up here — a partial update won't blank out fields it didn't mention.
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(task, field, value)
    db.commit()
    db.refresh(task)
    return task


def delete_task(db: Session, task: Task) -> None:
    db.delete(task)
    db.commit()
