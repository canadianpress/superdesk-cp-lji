# Superdesk CMS Deployment Runbook

This runbook describes the automated deployment in
`.github/workflows/deploy.yml`, the configuration it requires, and how to
validate it safely. The GitHub Actions workflow uses AWS Systems Manager (SSM)
to run deployment commands on an Ubuntu server; it does not deploy directly
from the GitHub runner.

## Deployment at a glance

The workflow runs on GitHub Actions when:

- Code is pushed to the `test-ci-cd` branch; or
- A pull request targeting `test-ci-cd` is closed and merged.

Closing a pull request without merging does not deploy. For a merged pull
request, the workflow's job condition explicitly requires `merged == true`.
Every push to the deployment branch can trigger a deployment, including a push
that updates a merged pull request.

The workflow then:

1. Requests temporary AWS credentials using GitHub's OIDC identity and the
   configured IAM role.
2. Sends an `AWS-RunShellScript` command to the configured EC2 instance through
   SSM.
3. On the instance, prepares a working directory and checks out the configured
   repository reference.
4. Retrieves the environment file from AWS Systems Manager Parameter Store.
5. Runs `deploy/hosts/setup-cms-system.sh` with `sudo`.
6. Runs `deploy/services/cms.sh` as the configured deployment user.
7. Polls SSM for completion and fails the Actions job unless the final status
   is `Success`.

The remote deployment sequence is protected by a host-wide lock, so overlapping
workflow runs wait rather than performing system setup and application
activation concurrently. Direct `cms.sh` runs use the same lock.

The remote command delivery timeout and script execution timeout default to 60
minutes each. The workflow polls for up to 125 minutes by default, with a
10-second interval, to allow for delivery plus execution. The host lock is
waited on for up to 5 minutes. If `MAX_POLL_TIME` is configured below the
command's possible run time, the Actions job can stop waiting while the remote
command continues.

## Configure GitHub Actions

Set these **repository or environment secrets**:

| Secret | Purpose |
| --- | --- |
| `IAM_ROLE` | AWS IAM role ARN that GitHub Actions assumes through OIDC. |
| `AWS_REGION` | AWS region containing the instance and Parameter Store value. |
| `INSTANCE_ID` | EC2 instance ID that receives the SSM command. |

Set these **repository or environment variables**:

| Variable | Purpose |
| --- | --- |
| `TARGET_DIR` | Directory on the instance for the checkout containing the deployment scripts and `deploy.env`. |
| `REPO_URL` | Git repository URL to clone or update. |
| `REPO_REF` | Branch to deploy. The existing-checkout workflow path fetches and resets to `origin/$REPO_REF`. |
| `SSM_ENV_PARAM_NAME` | Name of the Parameter Store parameter whose value becomes `deploy/deploy.env`. |
| `TARGET_USER` | Linux account that owns the checkout and runs `cms.sh`; defaults to `ubuntu`. |
| `MAX_POLL_TIME` | Maximum seconds the Actions step waits for SSM; defaults to `7500`. |
| `POLL_INTERVAL` | Seconds between SSM status checks; defaults to `10`. |

Configure an AWS IAM OIDC provider and role trust policy that permits this
repository/workflow to assume `IAM_ROLE`. The role needs the permissions
required to send SSM commands to the intended instance and read their status.
The instance must be online and managed by Systems Manager (including a
working SSM Agent and instance profile permissions). The instance also needs
network access to the repository and to any package/image registries used by
the setup.

The instance-side AWS identity must be able to read the configured Parameter
Store parameter. Store application configuration and credentials in that
parameter (normally as a `SecureString`), not in the workflow YAML or ordinary
GitHub variables. The workflow writes the parameter value to
`$TARGET_DIR/deploy/deploy.env` and sets its mode to `600`.
Optionally set `APP_HEALTH_URL` in that environment file to a local endpoint
that returns a 2xx response when the application is ready.

### Important directory distinction

`TARGET_DIR` is the checkout from which the workflow invokes the deployment
scripts. `cms.sh` has a separate `DEPLOY_DIR` setting (default
`/var/www/app/cms`) that holds a Git source checkout, versioned releases, and
the `current` symlink used by the service. These paths can be different, but
make sure `deploy.env` is present under the `TARGET_DIR` checkout and sets
`DEPLOY_DIR` to the intended application directory if the default is not
appropriate. The deployment user's account must be able to access both paths.

The workflow invokes `cms.sh` as `TARGET_USER`; `cms.sh` also checks that the
current account matches `APP_USER` (which defaults to `ubuntu`). If you change
`TARGET_USER`, set `APP_USER` consistently in `deploy.env`.

## What the server scripts do

### System preparation

`setup-cms-system.sh` is invoked with `sudo` on each workflow deployment. It
targets Ubuntu 22.04 and installs or configures system packages, Python and its
native build dependencies, Nginx, Docker Engine/Compose, swap, and system
limits/kernel tuning. The script installs missing packages and configures
system settings; operating system upgrades are intentionally not run during
application deployments. Schedule host package upgrades separately and test
them on staging.

### Application deployment

`cms.sh` runs as the deployment user. Each run creates an isolated Git
worktree under `DEPLOY_DIR/releases` and a new Python virtual environment for
that release, then builds the frontend. The service and Nginx use the stable
`DEPLOY_DIR/current` symlink; it is switched only after preparation succeeds.
The script restarts the application and waits for systemd to report it active;
when `APP_HEALTH_URL` is configured, it also requires a successful HTTP
readiness response after restarting Nginx. Activation failures restore the
previous release and previous Nginx configuration, then verify the restored
service. Failed candidate releases are removed, and the current release plus
two previous releases are retained. Redis/MongoDB/Elasticsearch are started
from the deployment Compose file as before.

Application rollback switches code and dependencies only. Database
initialization or schema/data changes are not automatically reversed, so
database migrations must remain compatible with the previous release or be
protected by an independently managed backup and recovery process.

The Compose file starts Redis, MongoDB, and Elasticsearch; it is not by itself
a complete test or deployment of the application.

## Rollback

The workflow's existing-instance checkout currently resets to
`origin/$REPO_REF`, so `REPO_REF` should be a branch available on the remote.
To roll back, point the deployment configuration at a known-good rollback
branch, then trigger a deployment and verify it on staging before production.
The `cms.sh` script can check out a tag, but the workflow's preceding
existing-checkout step assumes a remote branch; tag or exact-commit rollback
requires updating that workflow checkout logic as well.

After rollback, verify the application, Nginx, and dependency services, and
confirm the running checkout is the intended version. Keep the previous
working branch or release available until the rollback has been validated.
