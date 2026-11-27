# Engineering log: challenges, decisions and lessons

A running record of what went wrong while building this pipeline, why, how it
was fixed, and what it taught. It is the raw material for the CA4 reflective
analysis (each entry notes the rubric areas it feeds) and doubles as a
"sharing" practice in the DevOps sense: the next person who hits the same
problem finds the answer here instead of rediscovering it.

Format per entry: **Symptom** (what we saw), **Root cause**, **Fix**,
**Lesson**, **Evidence** (where to find proof for the report/demo), and
**CA4** (which report section it supports).

---

## A. Local tooling and environment

### A1. Docker Desktop stuck on "Starting the Docker Engine"
- **Symptom:** Docker Desktop never started; a WSL toast said an HTTP proxy change needed a WSL restart.
- **Root cause:** a leftover `docker-desktop-data` WSL distribution from an earlier install was still registered, but its disk file (`ext4.vhdx`) no longer existed (`Wsl/Service/CreateInstance/MountDisk/ERROR_FILE_NOT_FOUND`). The proxy toast was a red herring: no proxy was configured.
- **Fix:** `wsl --shutdown`, then `wsl --unregister docker-desktop-data`; Docker Desktop recreated a clean one.
- **Lesson:** read the tool's own logs (`%LOCALAPPDATA%\Docker\log\host\com.docker.backend.exe.log`) rather than trusting the most visible UI message; stale state from old installs is a common root cause.
- **Evidence:** screenshots of the "distro installation timeout" dialog.
- **CA4:** challenges and solutions.

### A2. Where Jenkins lives
- **Symptom/decision:** Jenkins' compose file and data were first placed inside the assignment repo.
- **Root cause:** Jenkins is shared tooling, not part of one application.
- **Fix:** live Jenkins moved to `D:\DevOps\jenkins` (reusable by future projects); the repo keeps a documented reference copy under `jenkins/`.
- **Lesson:** separate platform tooling from the products it builds.
- **CA4:** rationale for design; DevOps principles (sharing, reuse).

### A3. Jenkins crash-loop after a one-click upgrade
- **Symptom:** after installing a plugin with "restart when done", Jenkins never came back ("Restarting Jenkins: pending").
- **Root cause:** the Jenkins UI's "upgrade automatically" banner had installed a newer core (2.580) that requires Java 21, inside a `lts-jdk17` image. On restart Jenkins refused to run, and `restart: unless-stopped` retried forever.
- **Fix:** switched to `jenkins/jenkins:lts-jdk21`; upgrade policy documented in the compose file: upgrade by bumping the image tag, never in the UI.
- **Lesson:** in containers, the image is the unit of change (immutable infrastructure). In-place upgrades are invisible to the config and lost or inconsistent on recreate.
- **Evidence:** log line `Running with Java 17 ... older than the minimum required version (Java 21)`.
- **CA4:** challenges; alternatives/best practice (immutable infrastructure).

### A4. What survives a container recreate?
- **Symptom/question:** a new image and container kept all Jenkins configuration; why?
- **Root cause:** Jenkins' state lives in `JENKINS_HOME` on a volume; the container holds only software. Corollary: CLIs installed with `docker exec` would be LOST on recreate.
- **Fix:** a small `Dockerfile` bakes git, docker CLI, AWS CLI v2 and Terraform 1.17.1 into the Jenkins image; plugins stay a hands-on UI step (persisted in the volume).
- **Lesson:** separate state (volumes) from software (images).
- **CA4:** rationale; DevOps principles (automation, reproducibility).

### A5. Jenkins took 15+ minutes to start
- **Symptom:** "Jenkins is getting ready to work" for 15+ minutes; the log showed 15 minutes just to list plugins.
- **Root cause:** `jenkins_home` was a bind mount from the Windows D: drive. Docker Desktop reaches Windows drives through a slow file-sharing layer. **Measured:** 300 file metadata lookups took **4,589 ms** on the D: mount vs **14 ms** on the container's own disk (about 300x).
- **Fix:** moved `jenkins_home` to a Docker named volume and copied the data in. Afterwards: **57 ms** for the same test, **about 8 s** boot.
- **Lesson:** measure before deciding; storage location matters on Docker Desktop. It also corrected an earlier wrong assumption that a bind mount was required.
- **Evidence:** the timings above, and the boot log timestamps before and after.
- **CA4:** challenges (strong example: diagnosis by measurement); DevOps principles (measurement).

### A6. Plugin names vs plugin IDs
- **Symptom:** searching "CloudBees AWS Credentials" in the plugin manager found nothing.
- **Root cause:** the plugin (`aws-credentials`) is now titled just "AWS Credentials".
- **Lesson:** identify plugins and dependencies by their IDs, not display names.
- **CA4:** minor challenge.

---

## B. Code quality, tests and Git workflow

### B1. Lint and format failures on the first local run
- **Symptom:** ruff `E501` (line too long) and `black --check` failures; ruff would also have flagged FastAPI's `Depends(...)` (bugbear B008), `datetime.timezone.utc` (UP017) and import order (our `app` package not recognised as first-party).
- **Fix:** ran `black`; configured ruff instead of silencing it (`extend-immutable-calls = ["fastapi.Depends"]`, `src` paths); used `datetime.UTC`.
- **Lesson:** run the same checks locally as CI runs (shift-left); configure linters to understand a framework's idioms rather than disabling rules.
- **CA4:** DevOps principles (automation); best practice.

### B2. A wrong test, caught by running it
- **Symptom:** one frontend test failed: "backend unreachable" did not show the friendly error.
- **Root cause:** the test raised Python's built-in `ConnectionError`; the app deliberately catches `requests.RequestException`, and the built-in is not a subclass. The app was right; the test was wrong.
- **Fix:** the test now raises `requests.exceptions.ConnectionError`.
- **Lesson:** tests are code and can be wrong; a failing test is information, not just a red mark.
- **CA4:** challenges.

### B3. Deprecated framework API
- **Symptom:** pytest warned that FastAPI's `on_event("startup")` is deprecated.
- **Fix:** replaced with a `lifespan` handler (same behaviour, test-friendly design kept).
- **CA4:** improvements and maintenance.

### B4. Git commands run from the wrong folder
- **Symptom:** `git add app/frontend/app.py` failed with "pathspec did not match"; commits were empty; the pushed branch equalled `main`; `gh pr create` said "No commits between main and fix/pipeline-scanners".
- **Root cause:** the terminal was still in `app\frontend`, so repo-root-relative paths didn't exist.
- **Fix:** `cd` to the repo root and redo; nothing was lost.
- **Lesson:** check `git status` and the current directory before committing; small slips cascade.
- **It happened again** (from `infra\bootstrap`, after the Terraform step). The habit that prevents it: start every git block with `cd (git rev-parse --show-toplevel)`, which jumps to the repo root from any subfolder. A repeated mistake is a signal to change the process, not just to try harder.
- **CA4:** challenges (honest, relatable).

### B5. `gh` returned "HTTP 401: Bad credentials"
- **Symptom:** `gh repo create` failed with 401 despite a valid login.
- **Diagnosis:** checked for token environment variables (none), then confirmed the same token worked on GitHub's REST and GraphQL APIs. A retry succeeded, so it was transient.
- **Lesson:** diagnose before changing things (no needless re-login or token reset).
- **CA4:** challenges (method).

### B6. Professional Git workflow
- 5 meaningful initial commits (chore, backend, frontend, build, ci), then **feature branches and pull requests** for every change: #1 Sonar config, #2 scanner fixes, #3 AWS infrastructure, and the db CVE fix.
- **Evidence:** `git log --oneline --graph`; the PR list on GitHub.
- **CA4:** DevOps principles (collaboration, sharing); source control marks.

---

## C. Pipeline (Jenkins) and security scanning

### C1. SonarCloud set-up details
- Automatic Analysis must be OFF for CI-driven analysis; the organization and project keys are required in `sonar-project.properties`.
- A personal token was used; Sonar recommends **scoped organization tokens** (not tied to a person). Noted as an improvement.
- **CA4:** rationale; improvements.

### C2. Build #1: a real Bandit finding
- **Symptom:** Bandit `B104` (CWE-605): `app.run(host="0.0.0.0")` in the Flask dev entry point.
- **Fix:** bind the dev server to `127.0.0.1` (production uses gunicorn inside the container, where 0.0.0.0 is intended).
- **Lesson:** the gate works only because it is enforced (no `|| true`).
- **Evidence:** build #1 log; PR #2.
- **CA4:** DevSecOps; challenges.

### C3. Build #1: Trivy and Gitleaks stages died instantly
- **Symptom:** both stages failed in under a second without scanning.
- **Root cause:** Jenkins keeps a stage container alive by running `cat` in it; those images define an `ENTRYPOINT`, so the command became `trivy cat` and `gitleaks cat`, and the containers exited at once. (SonarCloud's image has no entrypoint, which is why it passed.)
- **Fix:** `args '--entrypoint='` on both docker agents.
- **Lesson:** understand how the orchestrator runs your containers; it corrected an earlier wrong assumption.
- **Evidence:** build #1 vs build #2 stage view; PR #2.
- **CA4:** challenges (strong technical example).

### C4. Coverage never reached SonarCloud
- **Symptom:** Sonar warned `No report was found for sonar.python.coverage.reportPaths`.
- **Root cause:** parallel stages run in separate workspaces (`ca3-pipeline@2`), so the Sonar stage never saw `coverage.xml`; pytest-cov also writes paths relative to each app folder.
- **Fix:** `stash`/`unstash` the reports and prefix their paths; removed `sonar.sources`/`sonar.tests` (Sonar reported them as having no effect) and set `sonar.python.version=3.12`.
- **CA4:** challenges; measurement.

### C5. Trivy downloaded its 137 MB database on every run
- **Fix:** a named cache volume shared by every Trivy run, saving about 35 s per run.
- **CA4:** improvements and efficiency.

### C6. "Requires a node context" at the end of every failed build
- **Root cause:** a `sh` step in the pipeline-level `post` block, while the pipeline uses `agent none`.
- **Fix:** removed it; `post` now only uses node-free steps.
- **CA4:** challenges (minor).

### C7. The UAT smoke test could never have passed
- **Root cause:** it ran `curl localhost:8000` inside the **Jenkins container**, where `localhost` is Jenkins itself, not the Docker host that publishes the UAT ports (a Docker-outside-of-Docker networking subtlety).
- **Fix:** run the checks inside the app containers with `docker compose exec`. The frontend's `/healthz` proves frontend to backend; the backend's `/healthz` proves backend to database.
- **Lesson:** caught by reasoning through the topology before it failed.
- **CA4:** challenges.

### C8. Build #3: CRITICAL CVE in the official Postgres image
- **Symptom:** the image scan failed Stage 5 with `CVE-2025-68121` (CRITICAL, status "fixed"; *"crypto/tls: Incorrect certificate validation during TLS session resumption"*) in `/usr/local/bin/gosu` of `postgres:16-alpine`. The binary was built with Go stdlib v1.24.6, fixed in 1.24.13 / 1.25.7 / 1.26.0-rc.3. The backend, frontend and Alpine OS packages were all clean (0).
- **Options weighed:** documented `.trivyignore` exception (gosu never opens TLS connections, so it is arguably unreachable), waiting for upstream to rebuild, or removing the need for the component.
- **Fix chosen:** start the container as the `postgres` user so the entrypoint never calls gosu, then delete the binary. The fix removes the vulnerable code entirely, and the database now also runs non-root.
- **Lesson:** base images carry supply-chain risk you didn't write. Prefer reducing attack surface over suppressing findings, and fail the build rather than ship.
- **Evidence:** **screenshot of build #3's red Stage 5 with the CVE line**; PR #4.
- **Verified in build #4:** all three images 0 vulnerabilities; the db container runs as `postgres`; `/usr/local/bin/gosu` no longer exists; UAT healthy end to end.
- **CA4:** challenges (headline example); DevSecOps; best practice.

### C9. Build #7: an "ENTRYPOINT" warning, and pinning the tool images
- **Symptom:** build #7 logged `ERROR: The container started but didn't run the expected command. Please double check your ENTRYPOINT...` for the SonarScanner container; the scan nevertheless ran normally. Builds #5 and #6 had no such line.
- **First hypothesis, wrong:** "the `:latest` image changed". Checked: no build pulled the image; it was the same local image every time.
- **Actual cause:** Jenkins runs `docker top` a split second after starting the container to confirm the process is `cat`. This image starts via an entrypoint script that then hands over to `cat`, so the check is a timing race: usually passed, occasionally caught mid-handover. Intermittent and harmless here.
- **Still worth fixing:** all tool images used `:latest` (or a floating tag), so the pipeline's behaviour *could* change on any pull with no commit. All five uses are now pinned to exact digests (python 3.12-slim, Trivy v0.76.2, SonarScanner CLI 8.5.0, Gitleaks v8.30.1). Trade-off: no automatic scanner updates; bump digests deliberately (Renovate/Dependabot).
- **Lesson:** test the first explanation against evidence before acting on it; reproducible builds need pinned inputs, not just pinned code.
- **CA4:** challenges (honest wrong hypothesis); best practice (reproducibility, supply chain); improvements (automated dependency bumps).

### C10. SonarQube Cloud: 0% coverage, a failing quality gate, and 17 findings to triage
- **Symptom:** the project page showed **coverage 0.0%**, **quality gate ERROR** (new security rating C, new coverage 0%) and **17 "vulnerabilities"**. Worse, the README and the CA4 draft claimed all four scanners *fail the build*, but nothing in the pipeline waited for Sonar's verdict: it only reported.
- **Coverage root cause:** Sonar logged `Cannot resolve the file path 'app/backend/__init__.py'`. Two bugs in my earlier fix (C4): the backend prefix was one folder short (`app/backend/` instead of `app/backend/app/`), and the reports' `<source>` still named the *test* stage's workspace (`ca3-pipeline@2`). **Fix:** correct prefix; rewrite `<source>` to the Sonar stage's workspace with Jenkins `readFile`/`writeFile` (no dependency on tools inside the scanner image).
- **Enforcement, a deliberate decision NOT to block:** SonarQube Cloud stays **advisory**. It reports quality, coverage and findings, but never fails the pipeline; Bandit, Trivy and Gitleaks are the blocking security gates. Reasoning: Sonar's default gate judges "new code" against rules and thresholds set outside the project (it flagged ten infrastructure trade-offs as vulnerabilities on its first run), so making it blocking would turn every new rule into a stopped release. Its findings are triaged by hand instead. The README and report were corrected, because they had claimed all four scanners block. If needed later, `sonar.qualitygate.wait=true` makes the scanner wait for the verdict and fail on a red gate (Jenkins' `waitForQualityGate` needs a webhook a localhost Jenkins can't receive).
- **Triage of the 17, fixed in code (6):**
  - `curl` without `--proto =https` (3, `jenkins/Dockerfile`): now HTTPS-only and TLS 1.2+.
  - pip could run package setup scripts (2): `--only-binary :all:` (every dependency already installs from wheels).
  - A password inside the default `DATABASE_URL` in `database.py` (1): the default is now a password-free local SQLite file.
  - The Terraform state bucket allowed non-HTTPS requests (1, `infra/bootstrap`): a Deny-unless-`aws:SecureTransport` bucket policy.
- **Accepted with a written justification (10), as a conscious risk decision rather than a silenced warning:**
  - pip installs not hash-locked (2): versions are pinned exactly; hash-locking is in the backlog.
  - The UAT compose DB password (2): a throwaway credential for a local-only database; production uses Secrets Manager.
  - Access logging off on the ALB and S3 (2) and 7-day log retention (1): cost, for a short-lived demo system.
  - The HTTP listener (1): no domain for a certificate (documented; HTTPS is in the backlog).
  - CSRF not enabled in Flask (1): the app has no login, session or cookies, so a cross-site request gains nothing that a direct request couldn't.
  - SNS topic without KMS (1): encrypting with AWS's own SNS key would stop CloudWatch alarms publishing to it (CloudWatch needs a customer-managed key policy); a customer-managed key is in the backlog.
- **Verified (build #9, `Finished: SUCCESS`, PR #8):** SonarQube Cloud coverage rose from **0.0% to 91.8%**; **11 findings closed as FIXED**, including the password-bearing default in `database.py`, curl HTTPS-only (3), wheels only (2) and the TLS-only state bucket. The 10 remaining open findings are exactly the accept list above, including the two UAT compose-password findings. All three images scanned clean (0); production healthy; `/metrics` 404; no alarms. Three of the ten were then marked Accepted in SonarQube Cloud (7 still show as open there); the written justification for all ten is this list, which is the record of the risk decision.
- **Lesson:** be precise about which tools are gates and which are advisors; documentation had overclaimed. Triage, meaning fixing what's cheap and justifying what's accepted, is the real DevSecOps work, not getting to "zero findings" at any cost.
- **CA4:** DevSecOps; challenges; benefits and drawbacks (alert fatigue, false positives); best practice (risk acceptance with justification).

---

## D. Infrastructure and deployment (AWS)

### D1. Chicken-and-egg ordering
- **Problem:** the pipeline pushes images (Stage 5) before it applies Terraform (Stage 8), but the ECR repositories and the remote-state bucket must exist first.
- **Fix:** split Terraform into `infra/bootstrap` (applied once by hand; local state) and `infra/prod` (applied by Jenkins; S3 remote state with S3-native locking).
- **Follow-up (Friday, optional):** migrate the bootstrap state into the S3 bucket. Caveat: then migrate it back before ever destroying bootstrap.
- **CA4:** rationale; alternatives (local vs remote state).

### D2. Jenkins must not use personal admin keys
- **Fix:** a dedicated IAM user `tasktracker-jenkins-ci` with a least-privilege policy:
  - ECR push only to the project's 3 repos
  - S3 only for the `prod/` state
  - project services only in `eu-west-1`
  - IAM only for `tasktracker-*` roles
  - PassRole only to ECS tasks

  The access key was created in the console, so the secret never enters Terraform state.
- **Honest limit:** service-level wildcards within one region (VPC creation can't be resource-scoped up front); Route 53 needs a global exception for Cloud Map.
- **CA4:** DevSecOps; best practice (least privilege); improvements (OIDC/short-lived credentials).

### D3. No startup ordering on ECS
- **Problem:** docker-compose has `depends_on`; ECS services start independently, so the backend could crash-loop until Postgres is ready.
- **Fix:** the backend retries table creation (30 x 2 s), with two unit tests.
- **CA4:** challenges; alternatives (compose vs orchestrator semantics).

### D4. Host-path bind mounts don't travel
- **Problem:** `./db/init.sql` bind-mounted in compose is invisible to the host daemon when compose runs from Jenkins, and impossible on Fargate.
- **Fix:** bake `init.sql` into a `tasktracker-db` image; identical everywhere.
- **CA4:** challenges; DevOps principles (environment parity).

### D6. Build #4: "the specified KMS key could not be found" (first-use race)
- **Symptom:** the first production `terraform apply` (Stage 8) created 41 resources, then failed on `aws_efs_file_system.db`: `BadRequest: The request was rejected because the specified KMS key could not be found [NotFoundException]`.
- **Diagnosis, step by step:**
  1. The message suggests a missing key or permission, so we checked the facts rather than trusting the wording.
  2. The AWS-managed key `alias/aws/elasticfilesystem` **did** exist, but its creation time was **23:33:30 the same day**, the exact moment of the failed request. `aws/secretsmanager` dated from 31 October.
  3. The Jenkins user has **zero** KMS permissions, yet Secrets Manager encrypted both secrets in the same run. So AWS-managed keys work "via the service" without extra IAM permissions.
- **Root cause:** this was the first encrypted EFS file system in the account and region. AWS creates its managed EFS key on first use, and our request raced that creation (eventual consistency). Terraform printed the error 3 minutes later, only after the load balancer it was creating in parallel finished.
- **Fix:** re-run the pipeline with no code change. Terraform's remote state meant it resumed and created only the missing resources. (Do not use Jenkins' "Restart from Stage 8": it skips Stage 1, where `IMAGE_TAG` is set.)
- **Lesson:** an error message names a symptom, not necessarily a cause; gather evidence (creation timestamps) before changing code or widening permissions. Remote state also made a half-finished apply safe to resume.
- **CA4:** challenges (strong: evidence-based diagnosis); best practice (idempotent IaC, remote state).

### D8. Build #5: green, but "3 destroyed" on a first deploy (perpetual diff)
- **Symptom:** the successful apply reported `14 added, 0 changed, 3 destroyed`. Nothing should be destroyed on a first deploy.
- **Root cause:** after removing the deprecated `failure_threshold`, the Cloud Map services kept an empty `health_check_custom_config {}` block. AWS returns nothing for it, so every refresh looked like "block missing", and because it can only be set at creation, Terraform planned a destroy-and-recreate of all three DNS services on **every** apply. On later deploys that would also have forced replacement of the ECS services that reference them, causing downtime on every release.
- **Fix:** `lifecycle { ignore_changes = [health_check_custom_config] }` on `aws_service_discovery_service.app`.
- **Verified:** a local `terraform plan` against the live production state reported **"No changes. Your infrastructure matches the configuration."**
- **Lesson:** a green build is not the end of the check. Read the plan or apply summary: unexpected "destroyed" counts are a smell. Fixing a deprecation warning can introduce a subtler problem.
- **CA4:** challenges (subtle IaC behaviour); measurement (reading plan output); best practice (idempotent applies, no-op plans).

### D9. Build #6: Stage 8 "takes too long" (about 9 minutes per release)
- **Observation:** a normal release (new commit `e894b61`) spent about 9 minutes in Stage 8. ECS events: db 00:16:14 to 00:18:58, backend 00:18:55 to 00:22:24, frontend to 00:24:03.
- **Why:** the plan was `3 to add, 3 to change, 3 to destroy`, which is the normal shape of a deploy: ECS task definitions are immutable, so a new image tag means a new revision (old ones "destroyed"), and the three services are updated in place. The services roll **one after another** (`depends_on` chain plus `wait_for_steady_state`); each new task must pull its image and pass health checks (the frontend also the ALB's), then the old task drains for 30 s.
- **Result:** `Finished: SUCCESS`; zero-downtime rolling deploy for the frontend and backend; no alarms.
- **Improvement (documented, not built):** deploy the services in parallel after the first creation, and tune health-check intervals. Estimated Stage 8 of about 3 to 4 minutes.
- **CA4:** measurement (timings from ECS events); improvements.

### D10. Every release restarts the database (a design limitation found by observing a deploy)
- **Observation:** build #6 changed only Terraform, yet the **db** service was redeployed too.
- **Root cause:** every commit tags **all three** images with the commit SHA, so the db task definition changes on every release. The db service is deliberately stop-first (two Postgres must never share the EFS data directory), so each release causes about **2.7 minutes** in which the backend cannot reach the database. The web tiers stay up (the frontend shows its "backend unreachable" banner or the API errors).
- **Improvements (documented, not built):** tag the db image by a hash of `db/` so it only changes when the schema image changes; or move the data tier to Amazon RDS, which keeps the database out of the application release cycle entirely (and adds backups and failover).
- **Lesson:** "zero downtime" has to be checked per tier; stateful components need a different release strategy from stateless ones.
- **CA4:** challenges; benefits and drawbacks of CI/CD (deploying everything on every commit); improvements; comparison with best practice (stateful vs stateless services).

### D11. Production `/metrics` was readable from the internet
- **How it was found:** while questioning *why* we monitor UAT, we checked whether production's metrics were reachable. `GET http://<alb>/metrics` returned **HTTP 200**, exposing the exact Python version (3.12.16), process memory and request counters.
- **Risk:** information disclosure that helps an attacker fingerprint the stack (CWE-200). Low severity, trivial to exploit.
- **Fix:** an ALB listener rule (`aws_lb_listener_rule.block_metrics`, `infra/prod/alb.tf`) answers 404 for `/metrics` before the request reaches a container; metrics stay reachable inside the VPC for an in-VPC Prometheus. A **security regression test** was added to the Jenkinsfile's Stage 9: every deploy now fails if `/metrics` answers anything but 404 from the internet.
- **Verified (build #7, `Finished: SUCCESS`):** `GET /metrics` from the internet now returns `Not Found` (HTTP 404), while `/healthz` and the UI still return 200; Stage 9 logged `OK: /metrics is not exposed to the internet (HTTP 404)`.
- **Lesson:** observability endpoints are part of the attack surface; "it's just metrics" is not a reason to expose them.
- **CA4:** DevSecOps; challenges; improvements.

### D7. Provider lock file only had Windows checksums
- **Symptom:** in Jenkins, `terraform init` printed "Terraform has made some changes to the provider dependency selections recorded in the .terraform.lock.hcl file".
- **Root cause:** the committed lock file was generated by `terraform init` on Windows, so it held provider checksums for `windows_amd64` only; Jenkins runs on Linux.
- **Fix:** `terraform providers lock -platform=linux_amd64 -platform=windows_amd64` in each stack, then commit, so every machine verifies the same pinned providers. Terraform confirmed: "Additional checksums for this platform [linux_amd64] are now tracked in the lock file".
- **CA4:** best practice (reproducible builds across platforms).

### D5. Terraform deprecation caught by `validate`
- `failure_threshold` in Cloud Map's health config is deprecated (AWS always uses 1); removed.
- **CA4:** minor; best practice (validate in CI).

---

## E. Deliberate trade-offs (for "comparison with alternatives")

| Choice made | Alternative | Why this one (here) |
|---|---|---|
| Jenkins (self-hosted, in Docker) | GitHub Actions | The brief's example and a hands-on goal; full control; but more ops burden (upgrades, plugins, storage). |
| ECS Fargate | EKS (Kubernetes) | No cluster to run, far less IaC, lower cost; the rubric accepts an "equivalent orchestration platform". |
| Postgres container + EFS | Amazon RDS | Keeps the same 3-container shape as UAT and costs little; RDS is the production-grade answer (backups, failover). |
| Public subnets + strict security groups | Private subnets + NAT / VPC endpoints | NAT costs about $32/month on its own; security groups still allow each tier only from the tier in front. |
| HTTP on the ALB | HTTPS (ACM certificate) | Needs a domain; documented as the next step. |
| Terraform | CloudFormation / CDK / Pulumi | Cloud-agnostic and widely used; plan/apply review step; remote state and locking. |
| Mutable ECR tags | Immutable tags | Lets a pipeline re-run push the same commit tag; immutable is stricter. |
| Poll SCM every 5 min | GitHub webhook | GitHub can't reach `localhost`; a tunnel or a hosted Jenkins would enable webhooks. |
| Personal Sonar token | Scoped organization token | Faster to set up; org tokens are better practice. |
| Prometheus + Grafana for **UAT**; CloudWatch dashboard + alarms for **prod** | Prometheus inside the VPC (e.g. Amazon Managed Prometheus + Managed Grafana) scraping prod through Cloud Map | UAT monitoring tests the dashboards and alert rules themselves, supports a data-backed decision at the promotion gate, and allows safe incident rehearsal; prod gets AWS-native metrics and alarms at near-zero cost. Gap: app-level metrics (per-endpoint latency) are not collected in prod; closing it costs money and time. |

## F. Improvement backlog (for "suggestions for improvement")

- Short-lived credentials (GitHub/Jenkins OIDC to AWS) instead of a long-lived IAM access key.
- HTTPS with ACM; private subnets with VPC endpoints; RDS instead of Postgres on EFS.
- IaC security scanning in CI (`trivy config` or Checkov on `infra/`).
- Image signing and an SBOM (cosign, syft); immutable ECR tags with a re-run guard.
- Database migrations with Alembic instead of `create_all` at startup.
- Jenkins Configuration as Code (JCasC) so the controller set-up is versioned too; dedicated build agents.
- SonarCloud quality-gate enforcement (`waitForQualityGate`).
- Branch protection on `main`; release tags (`v1.0.0`).
- DORA metrics (deployment frequency, lead time, change failure rate, MTTR) from the pipeline history.
- Bootstrap state migrated to S3 (planned Friday).
- Only redeploy the database when `db/` changes (content-hash image tag), or move to RDS, removing the 2.7-minute database restart on every release (D10).
- Deploy the ECS services in parallel and tune health checks, cutting Stage 8 from about 9 to about 3-4 minutes (D9).
- Collect app-level metrics in production with Prometheus inside the VPC (Amazon Managed Prometheus/Grafana).
- Automate the promotion gate: after UAT, query Prometheus for error rate and latency and refuse to promote on a regression.
- Pin the application Dockerfiles' base images (`python:3.12-slim`, `postgres:16-alpine`) by digest too, with Renovate/Dependabot opening PRs for updates (C9).
- Hash-locked Python dependencies (`pip-compile --generate-hashes`, `pip install --require-hashes`); a customer-managed KMS key for the SNS alerts topic; ALB and S3 access logging (C10).
- Once findings are triaged and the gate is tuned to the project, make the SonarQube Cloud quality gate blocking (`sonar.qualitygate.wait=true`) (C10).

## G. Evidence to capture (screenshots/logs for the report and demo)

Captured screenshots are stored outside this public repo (they show a personal browser bookmarks bar), in `..\CA4-evidence\`, with an index (`00-evidence-index.md`) mapping each file to the entries above.

- [x] Docker Desktop "distro installation timeout" dialog (A1), already taken
- [ ] Jenkins boot-time log before/after the volume move (A5)
- [ ] Build #1 stage view: Bandit/Trivy/Gitleaks red (C2, C3)
- [ ] Build #2 stage view: Stage 4 all green (C3 fixed)
- [x] **Build #3 Stage 5 red with CVE-2025-68121** (C8): two screenshots taken, (1) the stage view and report summary (`Total: 1 (CRITICAL: 1)`), (2) the CVE row with installed/fixed versions and `script returned exit code 1`
- [ ] First fully green build through production: **build #5**, `Finished: SUCCESS`, URL `http://tasktracker-alb-1089024514.eu-west-1.elb.amazonaws.com` (screenshot the stage view and the live app)
- [ ] SonarCloud dashboard with coverage
- [ ] `git log --oneline --graph` and the GitHub PR list (B6)
- [ ] AWS console: ECS services, ALB target health, CloudWatch alarms, Secrets Manager entry (value hidden)
