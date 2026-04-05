# Release Orchestration — Investigation & Plan

> Created: 2026-03-08
> Purpose: Track findings, open questions, and strategy for automating the OneLens release process across repos.

---

## Repo Inventory

| Repo | Path | Default Branch | Latest Tag | Public? |
|---|---|---|---|---|
| onelens-installation-scripts | `/Users/mangesh/Dev/Projects/onelens-installation-scripts` | master | v2.1.2 | Yes (public) |
| onelens-agent | `/Users/mangesh/Dev/Projects/onelens-agent` | main | v2.1.2 | No (private) |
| Orchestration repo (NEW) | TBD | TBD | N/A | No (private) |

---

## Current State of Published Helm Charts (gh-pages)

### onelens-agent (public umbrella chart)
- Latest stable: **2.1.2** ✅
- Also stable: 2.0.1, 1.9.0, 1.8.0, 1.7.0, 1.6.0, 1.5.0, 1.4.1, 1.4.0, 1.3.0, 1.1.0
- Missing stable: 2.1.0, 2.1.1 (RC PRs were never merged for these)

### onelensdeployer
- Latest stable: **2.0.1** ← this is what customers get without --version
- RC only (never promoted): 2.1.2-rc, 2.1.1-rc, 2.1.0-rc
- Missing stable: 2.1.0, 2.1.1, 2.1.2

### Customer impact
- `helm install onelensdeployer` without `--version` → Helm picks latest **stable** (excludes pre-release/rc) → **2.0.1**
- Deployer chart 2.0.1 → Docker image v2.0.1 → baked install.sh with RELEASE_VERSION=2.0.1 → installs onelens-agent 2.0.1
- **v2.1.x features/fixes are NOT reaching new customers**
- Existing clusters: backend can push updated patching.sh via API (confirmed by user: backend handles both)

---

## What Changed in v2.0.1 → v2.1.2 (from actual code diffs, not PR titles)

### Customer-affecting changes (runs inside their cluster):

1. **Resource sizing — 1.6x memory, 1.2x CPU bump across all tiers**
   - All components: Prometheus, OpenCost, OneLens Agent, KSM
   - In both install.sh (new installs) and patching.sh (daily updates)
   - Directly addresses OOM issues documented in oom-issues.md

2. **patching.sh — "never-decrease" resource logic (NEW)**
   - Helper functions _max_cpu, _max_memory compare patching values vs current running values
   - Takes the HIGHER of (computed, existing) — prevents resource downgrade
   - Fixes real bug: patching could shrink resources on manually-scaled clusters

3. **Label injection — new feature**
   - globals.labels + per-resource labels in all deployer templates
   - DEPLOYMENT_LABELS env var flows from chart → install.sh → applied to all pods
   - Also labels the namespace

4. **Toleration handling fix**
   - operator=Exists no longer requires a value (was a bug — blocked dedicated node deployments)

5. **Namespace handling fix**
   - No longer force-creates namespace; checks existence first, conditionally passes --create-namespace

6. **OpenCost image source change**
   - FROM: quay.io/kubecost1/kubecost-cost-model (Kubecost fork)
   - TO: ghcr.io/opencost/opencost:1.119.1 (upstream OpenCost)
   - Different container image in customer clusters

7. **Deployer job/cronjob resource bump**
   - Job: CPU 400m→600m, memory 250Mi→400Mi

### CI/CD only changes (does NOT affect customers):

8. **Docker cache busting** — CACHE_BUST=${{ github.sha }} ARG in Dockerfile
9. **Trivy scan made non-blocking** — exit-code 1→0, build-and-push no longer gated on scan
10. **Helm workflow** — minor comment cleanup, removed some validation comments

---

## Version Chain Verification (end-to-end, verified from code at v2.0.1 tag)

```
Customer command: helm install onelensdeployer onelens/onelensdeployer (no --version)
  ↓ Helm picks latest stable
  onelensdeployer chart: 2.0.1
    ↓ values.yaml
    Docker image: public.ecr.aws/w7k6q5m9/onelens-deployer:v2.0.1
      ↓ Dockerfile: COPY install.sh /install.sh (baked at build time)
      ↓ entrypoint.sh: if deployment_type=job → runs local ./install.sh
        install.sh line 37: RELEASE_VERSION:=2.0.1 (hardcoded default)
        install.sh line 501: helm install onelens-agent --version 2.0.1
          ↓
          onelens-agent chart: 2.0.1
```

**Confirmed: fully hardcoded, no dynamic version resolution for new installs.**

**Patching path (daily CronJob) is different:**
- entrypoint.sh: if deployment_type=cronjob → fetches patching.sh from API (POST /v1/kubernetes/patching-script)
- Does NOT use baked-in patching.sh — downloads fresh from backend
- Backend can push v2.1.2 patching logic to existing 2.0.1 clusters (confirmed by user)

---

## onelens-agent Repo State

- v2.0.1 and v2.1.2 tags point to the **exact same commit** (42eed92)
- Zero code changes between these tags
- The v2.1.2 tag was created purely for version alignment with onelens-installation-scripts
- Contains: agent/ (Go code), helm-chart/ (onelens-agent-base), manifests/, docker-compose.yml
- Workflows: 3 workflows (see Question 3 findings below)

---

## Release Process (from PDF + workflow code analysis)

### Current process (documented in PDF, partially broken):

1. Cut branch, make changes, merge to master/main in both repos
2. `git tag vX.Y.Z && git push origin vX.Y.Z` in both repos
3. **onelens-agent repo**: tag push → releases Docker image + helm chart (onelens-agent-base to private ECR)
4. **onelens-installation-scripts repo**: tag push triggers:
   - `build-onelens-deployer.yml` → builds Docker image → pushes to public ECR
   - `helm-package-release.yml` → packages both charts:
     - onelens-agent: version X.Y.Z (stable, no -rc)
     - onelensdeployer: version X.Y.Z-rc (RC suffix)
   - Creates PR to gh-pages branch → must be manually merged
5. **MISSING STEP (this is where it broke)**: Create GitHub Release on the tag
   - This triggers `helm-package-release.yml` again with `release: [published]` event
   - Sets onelensdeployer version to X.Y.Z (no -rc, stable)
   - Creates another PR to gh-pages → must be manually merged

### What went wrong:
- Step 5 was never executed for v2.1.0, v2.1.1, v2.1.2
- For v2.1.0 and v2.1.1: even Step 4's RC PRs were never merged
- For v2.1.2: RC PR was merged (onelens-agent 2.1.2 stable + onelensdeployer 2.1.2-rc), but no GitHub Release created
- Root cause: asymmetric workflow design (PR #85) + manual step that's easy to forget

---

## Open Questions (answering one by one)

### Question 1: What actually changed in v2.1.x? ✅ ANSWERED
- See "What Changed in v2.0.1 → v2.1.2" section above
- Material customer-affecting changes: OOM fix, resource downgrade prevention, toleration fix, OpenCost image change, label injection, namespace handling

### Question 2: Is deployer version hardcoded or dynamic? ✅ ANSWERED
- New installs: HARDCODED. Deployer 2.0.1 → image v2.0.1 → install.sh RELEASE_VERSION=2.0.1 → onelens-agent 2.0.1
- Daily patching: DYNAMIC. CronJob fetches patching.sh from backend API. Backend handles both (confirmed by user).

### Question 3: onelens-agent repo workflows — what does tag push actually do? ✅ ANSWERED

**Three workflows in onelens-agent:**

1. **agent-test.yaml** — "OneLens Agent Tests"
   - Triggers: PR to main, push to main, manual
   - Runs Python integration tests using k3d (lightweight k8s in CI)

2. **agent.yaml** — "Build and Push Agent Docker Image"
   - Triggers: tag push v*, workflow_run (tests pass on main), manual
   - Pushes to: public.ecr.aws/w7k6q5m9/onelens-agent:<tag>
   - Tag push → image tagged with git tag (e.g., v2.0.1)
   - Merge to main → tests pass → image tagged "latest"

3. **ol-agent-base-chart.yaml** — "Package and Push Helm Chart"
   - Triggers: tag push v*, manual ONLY (NOT on merge to main)
   - Packages helm-chart/onelens-agent-base
   - OVERRIDES version at build time from git tag (Chart.yaml in repo is stale at 1.5.0)
   - Also patches values.yaml image tag at build time via yq
   - Pushes to private ECR: 609916866699.dkr.ecr.ap-south-1.amazonaws.com/helm-charts/

**PDF claim: "pushing a tag releases both helm chart and image"**
→ ✅ CORRECT. Both agent.yaml and ol-agent-base-chart.yaml trigger on tag push.

**PDF claim: "merging to master releases latest tag"**
→ ⚠️ PARTIALLY CORRECT. Docker image gets "latest" tag. Helm chart is NOT published on merge — only on tag push.

### Question 4: onelens-agent-base sub-chart (private ECR) versioning? ✅ ANSWERED

- Chart.yaml in the repo is stale: version 1.5.0, image tag v1.5.0
- CI overrides both version and image tag from git tag at build time
- Tags v2.0.1 and v2.1.2 point to SAME COMMIT (42eed92) — zero code changes
- CI publishes identical code as onelens-agent-base:2.0.1 and onelens-agent-base:2.1.2 to private ECR
- Umbrella chart (onelens-installation-scripts) depends on whichever version is in its Chart.yaml
- VERSION MANAGEMENT ISSUE: repo Chart.yaml (1.5.0) doesn't match published versions (2.0.1, 2.1.2)
- The v2.1.2 tag on onelens-agent was created purely for version alignment, not for code changes

### Question 5: Who are the consumers of the orchestration repo?
- Status: NOT YET ASKED — waiting for user input

### Question 6: docker-compose.yml in onelens-agent — existing local testing? ✅ ANSWERED

- Minimal dev setup: builds agent Docker image, runs with host network mode
- Image tag v0.0.1-beta.4 — ancient, unmaintained
- No Prometheus, KSM, OpenCost, or k8s cluster — just the agent process
- Real testing story is in CI: agent-test.yaml uses k3d for integration tests
- NOT a full local testing environment

### Question 7: Existing customers on older versions — does onelensupdater handle upgrades? ✅ ANSWERED (with open sub-question)

**patching.sh CAN change the chart version** — uses `helm upgrade --version=X.Y.Z --reuse-values`.

BUT the reference copy in the repo is STALE:
- v2.0.1 patching.sh: `--version=1.7.0` (way behind)
- v2.1.2 patching.sh: `--version=1.7.0` (same, still stale)
- The actual script is served DYNAMICALLY by backend API (POST /v1/kubernetes/patching-script)
- Cannot verify from code what version the backend currently serves

**What patching CAN do (if backend serves correct version):**
- Upgrade onelens-agent chart version → brings new templates, new defaults
- Apply resource sizing changes via --set overrides
- With v2.1.2 reference copy: "never-decrease" logic prevents resource downgrades

**What patching CANNOT do:**
- Cannot change onelensdeployer chart (only upgrades onelens-agent)
- Deployer-specific changes (label injection in deployer templates, deployer job resources, namespace handling in install.sh) are NEVER applied to existing customers via patching
- These require the customer to manually upgrade their onelensdeployer helm release

**SUB-QUESTION ANSWERED by user:**
Backend tracks release version per cluster in DB. Patching script maintains the SAME installed version — it does NOT upgrade the chart version. Version upgrade only happens when the customer explicitly runs a new helm install/upgrade. So:
- Customers on 2.0.1 stay on 2.0.1 chart forever until they manually upgrade
- Patching only applies resource sizing changes (--set overrides) within the same chart version
- Chart-level changes (OpenCost image, new templates, toleration fix) NEVER reach existing customers through patching
- The ONLY way existing customers get v2.1.x changes is: upgrading their onelensdeployer release (which re-runs install.sh with new RELEASE_VERSION)

### Question 5: Who are the consumers of the orchestration repo? ✅ ANSWERED
- The entire team. Must enable anyone to release correctly with a few commands and PRs.
- No tribal knowledge, no forgotten steps. The repo IS the process.

---

## Orchestration Repo — Proposed Structure (DRAFT, pending all questions answered)

```
onelens-release-orchestration/  (private, astuto-ai org)
├── .github/
│   └── workflows/
│       ├── release.yml          # Full release: bump → tag → build → publish stable
│       └── promote-rc.yml       # If RC step kept: promote RC to stable
├── scripts/
│   ├── bump-versions.sh         # Bumps Chart.yaml + install.sh in both repos
│   ├── tag-repos.sh             # Tags both repos consistently
│   └── validate-release.sh      # Pre-release checks: versions in sync, charts match tags
├── wiki/                        # Moved from internalwiki/
│   ├── architecture.md
│   ├── diagrams.md
│   ├── oom-issues.md
│   └── release-process.md       # Formalized from PDF
├── local-testing/               # TBD — pending Question 6
└── README.md
```

### Key design decisions pending:
1. Remove RC step entirely OR automate it? (leaning: remove — nobody tested RCs)
2. Auto-merge gh-pages PRs or require approval?
3. Pin --version in customer-facing helm commands?
4. How to handle the onelens-agent-base private ECR chart versioning?

---

## Action Items (ordered)

- [ ] Answer remaining open questions (3-7)
- [ ] Decide on RC vs no-RC for deployer
- [ ] Create orchestration repo structure
- [ ] Build release automation scripts/workflows
- [ ] Move internalwiki to orchestration repo
- [ ] Fix current state: either promote v2.1.2 to stable or cut a new release
