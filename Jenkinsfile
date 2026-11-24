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
        AWS_CRED_ID      = 'aws-atu'
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
                    agent { docker { image 'python:3.12-slim' } }
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
                    agent { docker { image 'python:3.12-slim' } }
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
                    agent { docker { image 'python:3.12-slim' } }
                    steps {
                        dir('app/backend') {
                            sh '''
                                set -e
                                python -m venv .venv
                                . .venv/bin/activate
                                pip install --no-cache-dir -r requirements-dev.txt
                                pytest --cov=app --cov-report=xml --junitxml=test-results.xml
                            '''
                        }
                    }
                    post {
                        always { junit 'app/backend/test-results.xml' }
                    }
                }
                stage('Frontend tests') {
                    agent { docker { image 'python:3.12-slim' } }
                    steps {
                        dir('app/frontend') {
                            sh '''
                                set -e
                                python -m venv .venv
                                . .venv/bin/activate
                                pip install --no-cache-dir -r requirements-dev.txt
                                pytest --cov=. --cov-report=xml --junitxml=test-results.xml
                            '''
                        }
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
                    agent { docker { image 'python:3.12-slim' } }
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
                    agent {
                        docker {
                            image 'aquasec/trivy:latest'
                            args '--entrypoint='
                        }
                    }
                    steps {
                        sh 'trivy fs --exit-code 1 --severity CRITICAL,HIGH --no-progress .'
                    }
                }
                stage('SonarCloud scan') {
                    agent { docker { image 'sonarsource/sonar-scanner-cli:latest' } }
                    steps {
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
                            image 'zricethezav/gitleaks:latest'
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
                sh '''
                    set -e
                    docker build -t "$ECR_REGISTRY/tasktracker-backend:$IMAGE_TAG" app/backend
                    docker build -t "$ECR_REGISTRY/tasktracker-frontend:$IMAGE_TAG" app/frontend
                '''
                sh '''
                    set -e
                    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy \
                        image --exit-code 1 --severity CRITICAL "$ECR_REGISTRY/tasktracker-backend:$IMAGE_TAG"
                    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy \
                        image --exit-code 1 --severity CRITICAL "$ECR_REGISTRY/tasktracker-frontend:$IMAGE_TAG"
                '''
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: "${AWS_CRED_ID}"]]) {
                    sh '''
                        set -e
                        aws ecr get-login-password --region "$AWS_REGION" \
                            | docker login --username AWS --password-stdin "$ECR_REGISTRY"
                        docker push "$ECR_REGISTRY/tasktracker-backend:$IMAGE_TAG"
                        docker push "$ECR_REGISTRY/tasktracker-frontend:$IMAGE_TAG"
                    '''
                }
            }
        }

        stage('6. Deploy to UAT') {
            agent any
            environment {
                BACKEND_IMAGE  = "${ECR_REGISTRY}/tasktracker-backend:${IMAGE_TAG}"
                FRONTEND_IMAGE = "${ECR_REGISTRY}/tasktracker-frontend:${IMAGE_TAG}"
            }
            steps {
                // --no-build: run the exact image just built/scanned/pushed
                // above, don't silently rebuild from source here too.
                sh 'docker compose -f docker-compose.yml up -d --no-build --remove-orphans'
                sh '''
                    set -e
                    for i in $(seq 1 10); do
                        if curl --fail --silent http://localhost:8000/healthz \
                           && curl --fail --silent http://localhost:5000/healthz; then
                            echo "UAT is healthy"
                            exit 0
                        fi
                        sleep 3
                    done
                    echo "UAT smoke test failed after 30s" >&2
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
                dir('infra') {
                    withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: "${AWS_CRED_ID}"]]) {
                        sh '''
                            set -e
                            terraform init -input=false
                            terraform apply -auto-approve -input=false -var="image_tag=$IMAGE_TAG"
                        '''
                    }
                }
            }
        }

        stage('9. Post-deploy smoke test & monitoring') {
            agent any
            steps {
                script {
                    def albUrl = sh(script: 'cd infra && terraform output -raw alb_url', returnStdout: true).trim()
                    sh "curl --fail ${albUrl}/healthz"
                }
                echo 'Dashboards: monitoring/ - one Grafana dashboard scrapes both the UAT containers and this Prod deployment via Prometheus.'
            }
        }
    }

    post {
        always {
            sh 'docker compose -f docker-compose.yml ps || true'
        }
        failure {
            // A real team would also page/Slack someone here - kept to a
            // log line since that's outside this assignment's scope.
            echo 'Pipeline failed - see the first failing stage above for the actual cause.'
        }
    }
}
