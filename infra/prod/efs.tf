# Persistent storage for the database.
#
# A Fargate container's own disk is thrown away whenever the task is
# replaced (every deploy, every crash). Postgres' data must outlive that, so
# it lives on EFS, a network file system that is mounted into whichever
# task is currently running the database.
#
# Trade-off worth stating in the write-up: this is the cheap, simple way to
# keep a containerised database alive. The production-grade answer is a
# managed database (Amazon RDS) - more robust and with backups built in, but
# it costs money 24/7 and is a larger step away from the three-container
# shape used in local UAT.

resource "aws_efs_file_system" "db" {
  encrypted = true # data at rest

  tags = { Name = "${var.name_prefix}-db" }
}

# One mount point per availability zone, so the database can start in either.
resource "aws_efs_mount_target" "db" {
  count = length(aws_subnet.public)

  file_system_id  = aws_efs_file_system.db.id
  subnet_id       = aws_subnet.public[count.index].id
  security_groups = [aws_security_group.efs.id]
}

# An access point pins every file operation to one user and one folder.
# The Postgres image (alpine) runs as uid/gid 70; forcing that here means
# the data directory is created with the right owner and permissions, and the
# container can never see anything else on the file system.
resource "aws_efs_access_point" "db" {
  file_system_id = aws_efs_file_system.db.id

  posix_user {
    uid = 70
    gid = 70
  }

  root_directory {
    path = "/pgdata"

    creation_info {
      owner_uid   = 70
      owner_gid   = 70
      permissions = "0700"
    }
  }

  tags = { Name = "${var.name_prefix}-db" }
}
