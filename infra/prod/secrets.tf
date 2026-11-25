# Secret management: the database password never appears in the repo, in the
# Jenkinsfile, or in the task definitions.
#
#   Terraform generates a random password
#       -> stores it in AWS Secrets Manager
#       -> ECS fetches it at container start-up and injects it as an
#          environment variable (the task definitions only hold the secret's
#          ARN - a pointer, not the value).
#
# Honest limit: because Terraform generated the value, it is also in
# Terraform's state file. That state lives in the encrypted, private,
# versioned S3 bucket from infra/bootstrap, so it is protected - but it is
# the one other place the secret exists.

resource "random_password" "db" {
  length = 24

  # Letters and digits only: the password is embedded in a connection URL
  # below, where characters like @ : / would need escaping.
  special = false
}

resource "aws_secretsmanager_secret" "db_password" {
  name        = "${var.name_prefix}/db-password"
  description = "Password of the Postgres user (injected into the db container)"

  # Delete immediately on `terraform destroy`. By default Secrets Manager
  # holds a deleted secret for 7-30 days, which would block re-creating it
  # with the same name if the stack is torn down and rebuilt.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db.result
}

# The backend reads ONE variable, DATABASE_URL (see app/backend/app/database.py).
# A task definition can inject a whole secret as a variable but can't stitch
# one together from parts, so the finished URL is stored as its own secret.
resource "aws_secretsmanager_secret" "database_url" {
  name                    = "${var.name_prefix}/database-url"
  description             = "SQLAlchemy connection URL (injected into the backend container)"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "database_url" {
  secret_id = aws_secretsmanager_secret.database_url.id

  # "db.tasktracker.local" is the private DNS name Cloud Map gives the db
  # service (see ecs.tf).
  secret_string = "postgresql+psycopg2://${var.db_user}:${random_password.db.result}@db.${local.namespace}:5432/${var.db_name}"
}
