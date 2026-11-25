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

# Security hardening, prompted by the pipeline's Trivy image scan:
# the upstream image ships `gosu`, a small Go tool whose only job is to let
# the container start as root and then drop to the `postgres` user. Its
# bundled Go standard library had a CRITICAL CVE (CVE-2025-68121, crypto/tls),
# which failed the build. Rather than ignore the finding, we remove the need
# for the tool: the container starts directly as `postgres` (uid 70), so the
# official entrypoint never calls gosu, and the binary can be deleted.
# Side benefit: the database now runs as non-root, like the other two tiers.
# Data directories already belong to uid 70 (the image's own data dir, the
# compose named volume copied from it, and the EFS access point in prod).
RUN rm -f /usr/local/bin/gosu

USER postgres
