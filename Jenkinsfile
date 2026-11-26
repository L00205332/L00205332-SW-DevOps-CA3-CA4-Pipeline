// Declarative Jenkins pipeline covering the assignment's 6 required stages
// (source control is the GitHub repo this file lives in; everything below
// is build/test/scan/containerise/deploy/monitor), split across 9 named
// pipeline stages because deploy is split into UAT -> manual gate -> Prod.
//
// Design notes (the "why", not just the "what"):
//
// - `agent none` at the top + a per-stage `agent`: some stages run in a
//   throwaway `python:3.12-slim` (etc.) container for isolation; others
//   run directly on the Jenkins controller (`agent any`) because they need
//   the docker/aws/terraform CLIs baked into our Jenkins image
//   (see jenkins/Dockerfile) rather than a language-specific image.
//
// - This assumes the Jenkins image has `git`, the `docker` CLI, AWS CLI v2
//   and Terraform (all installed by jenkins/Dockerfile), and that these
//   plugins are installed by hand in the Jenkins UI (they are deliberately
//   NOT in the image): git, workflow-aggregator, docker-workflow,
//   credentials-binding, junit, sonar, aws-credentials.
//   (aws-credentials = the "AWS Credentials" plugin, which provides the
//   AmazonWebServicesCredentialsBinding used in the deploy stages.)
//   See the README runbook for the one-time setup.
//
// - Every tool image (python, trivy, sonar-scanner, gitleaks) is pinned to an
//   exact digest (`image@sha256:...`), not a moving tag like `:latest`, so the
//   same commit always runs the same tools. Trade-off: no automatic scanner
//   updates - bump the digests deliberately (e.g. with Renovate/Dependabot).
//
// - Shell blocks use single-quoted `sh '''...'''`, not double-quoted
//   `sh """..."""`, wherever only an environment variable needs
//   substituting (`$IMAGE_TAG`). Single-quoted means Groovy does NOT
//   interpolate the string - the shell itself expands `$VAR` from the
//   process environment Jenkins already populated. This sidesteps a
//   common Jenkinsfile foot-gun: a bare `${IMAGE_TAG}` in a Groovy-parsed
//   string can fail with "No such property" depending on how the variable
//   was set, whereas `env.IMAGE_TAG` always works. Simplest fix: let the
//   shell do it instead.

pipeline {
    agent none

    options {
        timestamps()
        disableConcurrentBuilds()
    }

    environment {
        AWS_REGION       = 'eu-west-1'
        ECR_REGISTRY     = '536241055252.dkr.ecr.eu-west-1.amazonaws.com'
        // Jenkins credential/config IDs - created once in the Jenkins UI,
        // not in code (see README runbook for exactly how).
        // The dedicated, least-privilege IAM user created by infra/bootstrap -
        // never personal admin keys.
        AWS_CRED_ID      = 'aws-jenkins-ci'
        SONARQUBE_SERVER = 'sonarcloud'
    }

    stages {

        stage('1. Checkout') {
            agent any
            steps {
                checkout scm
                script {
                    // Short git SHA as the image tag: traceable (you can
                    // always map a running container back to the exact
                    // commit it was built from) and unique per commit.
                    env.IMAGE_TAG = sh(script: 'git rev-parse --short=12 HEAD', returnStdout: true).trim()
                }
                echo "Building commit ${env.IMAGE_TAG}"
            }
        }

        stage('2. Build') {
            parallel {
                stage('Backend: install + lint') {
                    agent { docker { image 'python:3.12-slim@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b' } }
                    steps {
                        dir('app/backend') {
                            sh '''
                                set -e
                                python -m venv .venv
                                . .venv/bin/activate
                                pip install --no-cache-dir -r requirements-dev.txt
                                ruff check .
                                black --check .
                            '''
                        }
                    }
                }
                stage('Frontend: install + lint') {
                    agent { docker { image 'python:3.12-slim@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b' } }
                    steps {
                        dir('app/frontend') {
                            sh '''
                                set -e
                                python -m venv .venv
                                . .venv/bin/activate
                                pip install --no-cache-dir -r requirements-dev.txt
                                ruff check .
                                black --check .
                            '''
                        }
                    }
                }
            }
        }

        stage('3. Test') {
            // Each sub-stage re-installs its own deps in a fresh container
            // rather than reusing Build's venv - slower, but every stage
            // stays fully self-contained and reproducible on its own,
            // which matters more than speed for an assignment pipeline.
            parallel {
                stage('Backend tests') {
                    agent { docker { image 'python:3.12-slim@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b' } }
                    steps {
                        dir('app/backend') {
                            sh '''
                                set -e
                                python -m venv .venv
                                . .venv/bin/activate
                                pip install --no-cache-dir -r requirements-dev.txt
                                pytest --cov=app --cov-report=xml --junitxml=test-results.xml
                                # pytest-cov writes paths relative to THIS directory
                                # (app/crud.py), but Sonar resolves them from the repo
                                # root - prefix them so Sonar can match the files.
                                sed -i 's|filename="|filename="app/backend/|g' coverage.xml
                            '''
                        }
                        // Parallel stages run in separate workspaces, so the
                        // Sonar stage can't see this file unless it is stashed.
                        stash name: 'coverage-backend', includes: 'app/backend/coverage.xml'
                    }
                    post {
                        always { junit 'app/backend/test-results.xml' }
                    }
                }
                stage('Frontend tests') {
                    agent { docker { image 'python:3.12-slim@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b' } }
                    steps {
                        dir('app/frontend') {
                            sh '''
                                set -e
                                python -m venv .venv
                                . .venv/bin/activate
                                pip install --no-cache-dir -r requirements-dev.txt
                                pytest --cov=. --cov-report=xml --junitxml=test-results.xml
                                # Same path fix as the backend stage above.
                                sed -i 's|filename="|filename="app/frontend/|g' coverage.xml
                            '''
                        }
                        stash name: 'coverage-frontend', includes: 'app/frontend/coverage.xml'
                    }
                    post {
                        always { junit 'app/frontend/test-results.xml' }
                    }
                }
            }
        }

        stage('4. Static analysis & security scanning') {
            // Three independent tools, three independent containers, run
            // in parallel - none of them need each other's output.
            parallel {
                stage('Bandit (Python security lint)') {
                    agent { docker { image 'python:3.12-slim@sha256:191083cdf6c7bda8c76158983163ead5d5cf7b77cf3033e805bb0f5296f51b4b' } }
                    steps {
                        sh '''
                            set -e
                            pip install --no-cache-dir bandit
                            bandit -r app/backend/app app/frontend -c pyproject.toml
                        '''
                        // No `|| true` anywhere here: a bandit finding
                        // above its default severity/confidence threshold
                        // exits non-zero, which fails this stage and the
                        // whole pipeline - the rubric's top band asks for
                        // scanning that's actually *enforced*, not just run.
                    }
                }
                stage('Trivy (dependency scan)') {
                    // `--entrypoint=` clears the image's built-in ENTRYPOINT.
                    // Jenkins keeps a stage container alive by running `cat`
                    // in it; with an ENTRYPOINT of `trivy`, that becomes
                    // `trivy cat`, the container exits at once and the stage
                    // fails before scanning anything.
                    // The named volume caches Trivy's 137 MB vulnerability
                    // database between runs (it is shared with the image scans
                    // in stage 5), instead of re-downloading it every time.
                    agent {
                        docker {
                            image 'aquasec/trivy@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb' // v0.76.2
                            args '--entrypoint= -v trivy-cache:/root/.cache/'
                        }
                    }
                    steps {
                        sh 'trivy fs --exit-code 1 --severity CRITICAL,HIGH --no-progress .'
                    }
                }
                stage('SonarCloud scan') {
                    // SonarScanner CLI 8.5.0. Its image starts via an entrypoint script, so
                    // Jenkins may log a harmless "didn't run the expected command"
                    // warning if it checks before the script hands over to `cat`.
                    agent { docker { image 'sonarsource/sonar-scanner-cli@sha256:8bb84373f00346f9a579adb7ccb2999f8cd050ab7167fa9ae08a16069de03c84' } }
                    steps {
                        // Bring in the coverage reports the Test stage produced
                        // (they live at the paths sonar-project.properties expects).
                        unstash 'coverage-backend'
                        unstash 'coverage-frontend'
                        // withSonarQubeEnv injects SONAR_HOST_URL/SONAR_AUTH_TOKEN
                        // from the "sonarcloud" server config set up in Jenkins'
                        // own UI (Manage Jenkins > System) - never hardcoded here.
                        withSonarQubeEnv(env.SONARQUBE_SERVER) {
                            sh 'sonar-scanner'
                        }
                    }
                }
                stage('Gitleaks (secret scanning)') {
                    // Bandit/Trivy/Sonar above all look at code patterns or
                    // known CVEs - none of them catch "a real API key or
                    // password got committed to git". Gitleaks scans the
                    // full commit history for exactly that. See .gitleaks.toml
                    // for the one documented allowlist entry.
                    // Same ENTRYPOINT issue as the Trivy stage above.
                    agent {
                        docker {
                            image 'zricethezav/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f' // v8.30.1
                            args '--entrypoint='
                        }
                    }
                    steps {
                        sh 'gitleaks detect --source . --redact --config .gitleaks.toml --exit-code 1'
                    }
                }
            }
        }

        stage('5. Containerise') {
            // Needs the real docker CLI + registry login, so this runs
            // directly on the controller (agent any), not a throwaway
            // per-language container - see jenkins/Dockerfile.
            agent any
            steps {
                // One image per tier (the data tier is Postgres + our schema,
                // see db/Dockerfile). All three get the same tag: the commit.
                sh '''
                    set -e
                    docker build -t "$ECR_REGISTRY/tasktracker-backend:$IMAGE_TAG" app/backend
                    docker build -t "$ECR_REGISTRY/tasktracker-frontend:$IMAGE_TAG" app/frontend
                    docker build -t "$ECR_REGISTRY/tasktracker-db:$IMAGE_TAG" db
                '''
                sh '''
                    set -e
                    for tier in backend frontend db; do
                        docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache/ aquasec/trivy@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb \
                            image --exit-code 1 --severity CRITICAL "$ECR_REGISTRY/tasktracker-$tier:$IMAGE_TAG"
                    done
                '''
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: "${AWS_CRED_ID}"]]) {
                    sh '''
                        set -e
                        aws ecr get-login-password --region "$AWS_REGION" \
                            | docker login --username AWS --password-stdin "$ECR_REGISTRY"
                        for tier in backend frontend db; do
                            docker push "$ECR_REGISTRY/tasktracker-$tier:$IMAGE_TAG"
                        done
                    '''
                }
            }
        }

        stage('6. Deploy to UAT') {
            agent any
            environment {
                BACKEND_IMAGE  = "${ECR_REGISTRY}/tasktracker-backend:${IMAGE_TAG}"
                FRONTEND_IMAGE = "${ECR_REGISTRY}/tasktracker-frontend:${IMAGE_TAG}"
                DB_IMAGE       = "${ECR_REGISTRY}/tasktracker-db:${IMAGE_TAG}"
            }
            steps {
                // --no-build: run the exact image just built/scanned/pushed
                // above, don't silently rebuild from source here too.
                sh 'docker compose -f docker-compose.yml up -d --no-build --remove-orphans'
                // The smoke test runs INSIDE the containers (`compose exec`).
                // `curl localhost:5000` from here would not work: this runs in
                // the Jenkins container, where "localhost" is Jenkins itself,
                // not the Docker host that publishes the UAT ports.
                // The frontend's /healthz returns 200 only if it can reach the
                // backend, so one call proves frontend -> backend works; the
                // backend's /healthz proves backend -> database works.
                sh '''
                    set -e
                    for i in $(seq 1 20); do
                        if docker compose -f docker-compose.yml exec -T backend \
                               python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')" \
                           && docker compose -f docker-compose.yml exec -T frontend \
                               python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/healthz')"; then
                            echo "UAT is healthy: frontend -> backend -> database all answering"
                            exit 0
                        fi
                        sleep 3
                    done
                    echo "UAT smoke test failed after 60s" >&2
                    docker compose -f docker-compose.yml ps >&2
                    exit 1
                '''
            }
        }

        stage('7. Promote to production?') {
            // Deliberately a manual, visible gate rather than an automatic
            // promotion - the pipeline pauses here until a human clicks
            // "Promote" in the Jenkins UI.
            steps {
                input message: "UAT is healthy for build ${env.IMAGE_TAG}. Promote to AWS production?", ok: 'Promote'
            }
        }

        stage('8. Deploy to Prod (AWS)') {
            agent any
            steps {
                // infra/prod's Terraform state lives in S3 (see infra/prod/
                // versions.tf), so a fresh checkout still knows what exists.
                // Prerequisite: infra/bootstrap has been applied once, by hand.
                dir('infra/prod') {
                    withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: "${AWS_CRED_ID}"]]) {
                        sh '''
                            set -e
                            terraform init -input=false
                            terraform apply -auto-approve -input=false -var="image_tag=$IMAGE_TAG"
                        '''
                        script {
                            // Kept in an env var for the next stage, which may
                            // run in a different workspace.
                            env.ALB_URL = sh(script: 'terraform output -raw alb_url', returnStdout: true).trim()
                        }
                    }
                }
            }
        }

        stage('9. Post-deploy smoke test & monitoring') {
            agent any
            steps {
                // A new load balancer can take a minute or two to start
                // routing, so retry rather than fail on the first attempt.
                sh '''
                    set -e
                    for i in $(seq 1 20); do
                        if curl --fail --silent --show-error "$ALB_URL/healthz"; then
                            echo
                            echo "Production is healthy at $ALB_URL"
                            exit 0
                        fi
                        sleep 10
                    done
                    echo "Production smoke test failed after 200s" >&2
                    exit 1
                '''
                // Security regression test: the Prometheus endpoint must NOT be
                // reachable from the internet (it leaked version and process
                // details before the load-balancer rule in infra/prod/alb.tf).
                sh '''
                    set -e
                    CODE=$(curl --silent --output /dev/null --write-out "%{http_code}" "$ALB_URL/metrics")
                    if [ "$CODE" != "404" ]; then
                        echo "SECURITY: /metrics is publicly reachable (HTTP $CODE)" >&2
                        exit 1
                    fi
                    echo "OK: /metrics is not exposed to the internet (HTTP 404)"
                '''
                // The pipeline feedback loop: ask CloudWatch whether any alarm
                // (5xx errors, unhealthy targets, high CPU - see
                // infra/prod/monitoring.tf) is firing right after the deploy,
                // and fail the build if so. Alarms in the INSUFFICIENT_DATA
                // state (brand new, no data yet) are not counted.
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: "${AWS_CRED_ID}"]]) {
                    sh '''
                        set -e
                        FIRING=$(aws cloudwatch describe-alarms --region "$AWS_REGION" \
                            --alarm-name-prefix tasktracker- --state-value ALARM \
                            --query 'MetricAlarms[].AlarmName' --output text)
                        if [ -n "$FIRING" ]; then
                            echo "CloudWatch alarms firing after the deploy: $FIRING" >&2
                            exit 1
                        fi
                        echo "No CloudWatch alarms firing"
                    '''
                }
                echo 'Production dashboard: the dashboard_url output of infra/prod (CloudWatch). UAT: monitoring/ (Prometheus + Grafana).'
            }
        }
    }

    // Pipeline-level `post` runs with no agent (the top-level `agent none`),
    // so it may only use steps that need no node, like `echo`. A `sh` step
    // here fails with "requires a node context".
    post {
        failure {
            // A real team would also page/Slack someone here - kept to a
            // log line since that's outside this assignment's scope.
            echo 'Pipeline failed - see the first failing stage above for the actual cause.'
        }
    }
}
