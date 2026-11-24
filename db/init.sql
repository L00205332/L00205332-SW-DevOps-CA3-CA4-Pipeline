-- Runs once, automatically, when the postgres container starts against an
-- empty data directory (official postgres image convention: anything in
-- /docker-entrypoint-initdb.d executes on first boot only).
--
-- The backend also creates this table itself on startup via SQLAlchemy
-- (Base.metadata.create_all, see app/backend/app/main.py) using
-- `CREATE TABLE IF NOT EXISTS` semantics, so the two never conflict. This
-- script exists so the data-tier schema is reviewable on its own, and so
-- the table + seed data exist even if something queries the database
-- before the backend container has started.

CREATE TABLE IF NOT EXISTS tasks (
    id VARCHAR(36) PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    description VARCHAR(2000),
    status VARCHAR(20) NOT NULL DEFAULT 'todo'
        CHECK (status IN ('todo', 'in_progress', 'done')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks (status);

INSERT INTO tasks (id, title, description, status) VALUES
    ('00000000-0000-0000-0000-000000000001', 'Set up the CI/CD pipeline', 'Jenkins + Docker + Terraform', 'in_progress'),
    ('00000000-0000-0000-0000-000000000002', 'Write the README runbook', 'Document every command for the demo', 'todo')
ON CONFLICT (id) DO NOTHING;
