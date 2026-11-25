# The data tier as its own image: the official Postgres plus our schema.
#
# Why not just bind-mount init.sql (what docker-compose.yml used to do)?
#  - Inside Jenkins, a relative host-path bind mount points at a path the
#    host's Docker daemon can't see, so Postgres would start without its
#    init script.
#  - ECS Fargate can't bind-mount host files at all.
# Baking the script into the image works identically everywhere: local
# compose, the Jenkins UAT stage, and ECS.
FROM postgres:16-alpine

# The official image runs everything in /docker-entrypoint-initdb.d once,
# on first start against an EMPTY data directory (so it never re-runs
# against existing data).
COPY init.sql /docker-entrypoint-initdb.d/init.sql
