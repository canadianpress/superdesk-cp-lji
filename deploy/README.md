# Superdesk CMS Deployment Runbook
This is a step-by-step guide to deploy CP Superdesk LJI. Use this to provision environments, perform deployments, or verify system health.

---

## 1. System Architecture
* **Frontend:** The web app.
* **Backend:** Python server.
* **Nginx:** Manage web traffic.
* **MongoDB & Redis:** Stores content, application states, and cache.
* **Elasticsearch:** Filtering and retrieval of articles and assets.

---

## 2. Prerequisites & Preparation Checklist
* [ ] **Server:** A server instance running **Ubuntu 22**.
* [ ] **Access Credentials:** **SSH Terminal access** to the server with administrative privileges (`sudo`).
* [ ] **Scripts:** The two automation files uploaded to the server: `setup-cms-system.sh` and `cms.sh`.
* [ ] **Env files:** Variables can be added to `deploy.env` to adjust the `setup-cms-system.sh` and `cms.sh`.
---

## 3. Step-by-Step Run Steps
The deployment is split into two phases: **System Provisioning** (done once per server) and **Application Deployment** (done every time code changes).

### Phase 1: One-Time Server Preparation
This phase installs the underlying software infrastructure (Python, Nginx).

1. Log into your server terminal via SSH.
2. Execute the environment preparation script using administrative access:
   `sudo ./setup-cms-system.sh`

### Phase 2: Start Application
This phase installs application dependencies and starts the cms service.

1. Execute the environment preparation script:
   `./cms.sh`

## 4. Rollback steps
This outlines the steps needed to do a rollback

1. Adjust the `REPO_REF` variable in `deploy.env` to the last working branch or release tag
2. Execute the environment preparation script:
   `/cms.sh`