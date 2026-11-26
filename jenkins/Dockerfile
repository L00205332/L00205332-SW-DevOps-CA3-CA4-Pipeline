# REFERENCE COPY - the live Jenkins is built from the same file in the
# shared folder D:\DevOps\jenkins (outside any repo, so other projects can
# reuse it). Keep the two in sync if you change one.
#
# Jenkins controller = the upstream image + the CLIs our pipelines shell out to.
#
# Why this file exists: anything installed inside a running container lives
# only in that container's own layer and is lost whenever the container is
# recreated (e.g. `docker compose up -d` after changing the image). Putting
# the installs here means every rebuild reinstalls them automatically.
# Jenkins' own data (jobs, credentials, plugins) is NOT affected either way:
# it lives in ./jenkins_home on the host (see docker-compose.yml).
#
# Plugins are intentionally NOT installed here - add them by hand in the UI
# (Manage Jenkins > Plugins); they persist in jenkins_home.
#
# Build / rebuild:   docker compose build        (add --pull to refresh the base image)
# Apply:             docker compose up -d
FROM jenkins/jenkins:lts-jdk21

USER root

# Pinned to match the Terraform on the host machine, so `terraform plan`
# behaves the same locally and inside the pipeline.
ARG TERRAFORM_VERSION=1.17.1

# git            - the `checkout scm` pipeline step shells out to a real git.
# docker-ce-cli  - ONLY the CLI, no daemon. With /var/run/docker.sock mounted
#                  (see docker-compose.yml) every `docker ...` command here is
#                  executed by the HOST's Docker Desktop, so containers the
#                  pipeline starts are siblings of Jenkins, not nested in it.
# docker-compose-plugin - provides `docker compose` for the Deploy-to-UAT stage.
# unzip/curl/gnupg/ca-certificates - needed by the installs below.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates curl gnupg unzip \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl --proto '=https' --tlsv1.2 -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# AWS CLI v2 - `aws ecr get-login-password` (Containerise stage) and the
# credentials Terraform uses (Deploy to Prod stage). uname -m gives
# x86_64 / aarch64, which is exactly how AWS names its downloads.
RUN curl --proto '=https' --tlsv1.2 -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# Terraform - provisions/updates the AWS production environment (infra/).
# dpkg's arch names (amd64 / arm64) match HashiCorp's download names.
RUN curl --proto '=https' --tlsv1.2 -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_$(dpkg --print-architecture).zip" -o /tmp/terraform.zip \
    && unzip -q /tmp/terraform.zip -d /usr/local/bin terraform \
    && rm /tmp/terraform.zip

# Back to the image's normal user. (docker-compose.yml overrides this with
# `user: root` so the container can use the Docker socket - see the note there.)
USER jenkins
