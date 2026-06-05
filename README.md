# OpenShift Deployment Pack — Onboarding Portal (air-gapped)

Deploy the Onboarding Portal to an **OpenShift cluster with no internet access**.
The same two images used by `docker-compose` are reused as-is; OpenShift objects
(Deployment/Service/Route/PVC/Secret/ConfigMap) replace the compose file.

> Local `docker-compose` is unaffected — you can still run `docker compose up`
> on your dev machine. The only image change for OpenShift is an `chmod g+w` on
> the frontend web root so config.js can be written under a random UID.

---

## What you carry into the air-gapped environment

| Artifact | How to produce | Contains |
|---|---|---|
| `onboarding-backend-<tag>.tar` | `openshift\build-images.ps1` | Node 24, all backend npm deps, **compiled** better-sqlite3, generated Prisma client, migration scripts |
| `onboarding-frontend-<tag>.tar` | `openshift\build-images.ps1` | nginx-unprivileged 1.27, the **built** Vite bundle |
| `openshift/manifests.yaml` | in this repo | all OpenShift objects |

Nothing else is needed on the cluster — **no npm install, no base-image pull, no
internet**. Everything is baked into the two tarballs.

---

## Step 1 — Build & export the images (on an internet-connected Windows machine)

From the repository root:

```powershell
.\openshift\build-images.ps1 -Tag 1.0
```

This builds both images for **linux/amd64** (the cluster arch — important because
`better-sqlite3` is a native binary) and writes:

```
openshift\images\onboarding-backend-1.0.tar
openshift\images\onboarding-frontend-1.0.tar
```

Copy the `openshift\` folder (tars + `manifests.yaml`) to the air-gapped admin host.

---

## Step 2 — Load the images into the OpenShift internal registry

On the air-gapped admin box (logged in with `oc`). Two options:

**A. With `skopeo` (no Docker needed):**
```bash
# Expose & log in to the internal registry once (cluster-admin):
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type merge -p '{"spec":{"defaultRoute":true}}'
REG=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
skopeo login -u $(oc whoami) -p $(oc whoami -t) $REG --tls-verify=false

oc new-project onboarding   # or: oc project onboarding

skopeo copy --dest-tls-verify=false \
  docker-archive:onboarding-backend-1.0.tar \
  docker://$REG/onboarding/onboarding-backend:1.0
skopeo copy --dest-tls-verify=false \
  docker-archive:onboarding-frontend-1.0.tar \
  docker://$REG/onboarding/onboarding-frontend:1.0
```

**B. With Docker:**
```bash
docker load -i onboarding-backend-1.0.tar
docker load -i onboarding-frontend-1.0.tar
docker login -u $(oc whoami) -p $(oc whoami -t) $REG
docker tag  onboarding-backend:1.0  $REG/onboarding/onboarding-backend:1.0
docker push $REG/onboarding/onboarding-backend:1.0
docker tag  onboarding-frontend:1.0 $REG/onboarding/onboarding-frontend:1.0
docker push $REG/onboarding/onboarding-frontend:1.0
```

Pods pull via the in-cluster registry DNS
(`image-registry.openshift-image-registry.svc:5000/...`), which is what
`manifests.yaml` references — no external pull happens.

---

## Step 3 — Fill in the placeholders & set secrets

Edit `manifests.yaml` (or `sed`) to replace:

| Placeholder | Example |
|---|---|
| `__NAMESPACE__` | `onboarding` |
| `__APPS_DOMAIN__` | `apps.ocp.mycorp.local` |
| `__TAG__` | `1.0` |

```bash
sed -i 's/__NAMESPACE__/onboarding/g; s/__APPS_DOMAIN__/apps.ocp.mycorp.local/g; s/__TAG__/1.0/g' manifests.yaml
```

Set the two secrets (do **not** commit real values):
```bash
# either edit the Secret stringData in manifests.yaml, or after applying:
oc create secret generic onboarding-secrets -n onboarding \
  --from-literal=OTP_HASH_SECRET=$(openssl rand -hex 32) \
  --from-literal=SESSION_TOKEN_SECRET=$(openssl rand -hex 32) \
  --dry-run=client -o yaml | oc apply -f -
```

---

## Step 4 — Deploy

```bash
oc apply -n onboarding -f manifests.yaml
oc get pods -n onboarding -w     # wait for both pods Running/Ready
oc get route -n onboarding       # note the two hostnames
```

---

## Step 5 — Verify

```bash
# Backend health (via its Route):
curl -k https://onboarding-api.apps.ocp.mycorp.local/health
# expect: {"status":"ok", ... "database":{"status":"up"} ...}

# Frontend got the right backend URL:
curl -k https://onboarding.apps.ocp.mycorp.local/config.js
# expect: API_BASE_URL: "https://onboarding-api.apps.ocp.mycorp.local"
```

Then open `https://onboarding.<apps-domain>/` and run the flow. Retrieve the OTP
(mock SMS) from the backend logs:

```bash
oc logs -n onboarding deploy/onboarding-backend | grep "OTP generated"
```

---

## Key decisions (and why)

- **Backend `replicas: 1`, strategy `Recreate`.** SQLite is single-writer and
  verified session tokens are single-use DB rows; a second replica would corrupt
  locking and split session state. The RWO PVC also can't attach to two pods, so
  rolling updates use `Recreate`. Horizontal scaling needs SQLite→Postgres.
- **Backend has its own Route.** The browser calls the API **directly** (nginx
  does not proxy it), so `APP_API_BASE_URL` (frontend) and `CORS_ALLOWED_ORIGINS`
  (backend) are set to the Route hostnames.
- **Random-UID safe.** Verified locally running both images as `uid=<random> gid=0`:
  the backend writes only to the mounted `data`/`uploads`/`logs` volumes (made
  group-writable by OpenShift `fsGroup`), and the frontend writes `config.js`
  thanks to the `chmod g+w` on the web root.
- **`ENABLE_OTP_DIAGNOSTICS=true`** logs OTP codes (mock SMS) so testers can read
  them. Acceptable for SIT / UAT-with-mocks; **set `"false"` for real production.**

## Not production-ready as-is

Same blockers as the other environments: all gateways are **mock** (enforced in
`backend/src/config/env.js`), OTP diagnostics are on, and storage is SQLite. A
real production deployment needs real gateway adapters, OTP logging off, and
SQLite→Postgres with backups.

## Files in this pack

- `manifests.yaml` — all OpenShift objects (placeholders marked `>>> REPLACE`)
- `build-images.ps1` — build + export the two image tarballs on Windows
- `README.md` — this runbook
