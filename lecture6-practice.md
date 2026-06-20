# Lecture 6 - Practice: Authorization with Keycloak Authorization Services

## Prerequisites

Before starting, make sure you have:

- Local Kubernetes lab running ([setup guide](https://github.com/kse-bd8338bbe006/lab-env-setup/blob/main/local-k8s/docs/setup-lab.md))
- Keycloak accessible at `https://keycloak.192.168.50.10.nip.io`
- `authz-demo` deployed at `https://authz-demo.192.168.50.10.nip.io`
- OpenFGA deployed at `https://openfga.192.168.50.10.nip.io`

---

## Part 0: Setup (do this once before the practice)

The `api-security` realm from previous lectures only has the `spa-token-demo` client and a `student` user, and neither OpenFGA nor `authz-demo` is deployed yet. Getting ready for this practice has a few steps that **must be done in this order**:

1. **Point the deployment repo at your org** (0.1) - sync your `kse-labs-deployment` fork and rewrite the course org name to your own, so ArgoCD pulls images you can actually access.
2. **Fork and build `authz-demo`** (0.2) - so your own container image lands in *your* GHCR and the build pushes the new image tag back into `kse-labs-deployment`.
3. **Create the databases** (0.3) - OpenFGA and authz-demo each need a Postgres DB + Vault secret.
4. **Configure Keycloak Authorization Services** (0.4).

Steps 0.1 and 0.2 are coupled: the `authz-demo` build only updates the deployment repo if 0.1 has already renamed the org. Do them in order, or the build goes green without deploying anything (explained in 0.2).

The two setup scripts (for 0.3 and 0.4) live in a dedicated repo, [`kse-bd8338bbe006/authz-lab-setup`](https://github.com/kse-bd8338bbe006/authz-lab-setup). Clone it once and run the scripts from there:

```bash
git clone https://github.com/kse-bd8338bbe006/authz-lab-setup.git
```

> Run the scripts from an interactive terminal - `openfga-db-setup.sh` uses `multipass exec` to reach the haproxy VM.

### 0.1 Sync the deployment repo and point it at your org

The latest `kse-labs-deployment` manifests include OpenFGA (`infra/openfga/`) and `authz-demo` (`applications/authz-demo/`). Sync your fork so you have them:

```bash
cd kse-labs-deployment
git pull origin main          # or: git fetch upstream && git merge upstream/main
git push origin main
```

If you see merge conflicts in files you have customized (e.g., `infra/keycloak/realm-configmap.yaml`), keep your version - the Keycloak authorization config is added via the Admin API in step 0.4, not through the configmap.

**Then rewrite the course org name to your own.** The synced manifests reference the course org `kse-bd8338bbe006` everywhere - including the image line `image: ghcr.io/kse-bd8338bbe006/authz-demo:...`. Your cluster **cannot pull from the course org's GHCR**, so repoint every reference at your own org (example org below: `kse-jdoe`):

```bash
# still in kse-labs-deployment; BSD/macOS sed
grep -rl "kse-bd8338bbe006" . | xargs sed -i '' 's/kse-bd8338bbe006/<your-org>/g'
git add -A && git commit -m "Point deployment at my org" && git push
```

> On Linux (GNU sed) drop the empty argument: `sed -i 's/kse-bd8338bbe006/<your-org>/g'`.

This rename is also what lets the `authz-demo` build update this repo later (0.2): its workflow rewrites `image: ghcr.io/<your-org>/authz-demo:...`, so if the org is still `kse-bd8338bbe006` the rewrite matches nothing and commits nothing.

ArgoCD picks up the new `infra/openfga` and `applications/authz-demo` directories and deploys them. The pods start but stay `CrashLoopBackOff`/`Pending`/`ErrImagePull` until your own image exists in your GHCR (0.2) and their database credentials exist (0.3).

### 0.2 Fork and build your own `authz-demo` image

The deployment pulls the authz-demo container from a GHCR package. The course package lives under `kse-bd8338bbe006`, and **your team cannot pull from it** - the pod comes up `ErrImagePull`. You need your own image, in your own org's GHCR. This is the step that is easy to forget.

1. **Fork [`kse-bd8338bbe006/authz-demo`](https://github.com/kse-bd8338bbe006/authz-demo) into your GitHub organization** - the same org you used in 0.1 (e.g. `kse-jdoe`). Use an **org**, not a personal account: the build's "make package public" step calls the org packages API, and the deploy step pushes to `<your-org>/kse-labs-deployment`.

2. **Enable GitHub Actions on the fork.** Forks ship with Actions disabled: open the fork's **Actions** tab and click **"I understand my workflows, go ahead and enable them."**

3. **Add the `DEPLOYMENT_PAT` secret to the `authz-demo` fork.** The build's last job (`update-deployment`) checks out *your* `kse-labs-deployment` and pushes the new image tag to it; that cross-repo push needs a token (the built-in `GITHUB_TOKEN` cannot write to another repo).
   - Create a **classic** PAT: GitHub **Settings -> Developer settings -> Personal access tokens -> Tokens (classic) -> Generate new token (classic)**.
   - Scope: check **`repo`** (full control of private repositories; this auto-selects `repo:status`, `repo_deployment`, `public_repo`, `repo:invite`, `security_events`).
   - In the **authz-demo** fork: **Settings -> Secrets and variables -> Actions -> New repository secret**. Name it exactly **`DEPLOYMENT_PAT`** (the workflow reads `secrets.DEPLOYMENT_PAT`) and paste the token.

4. **Trigger the build.** The workflow (`Main Build`) runs on **push to `main`**. From a local clone of your `authz-demo` fork, an empty commit is enough to kick it off:

   ```bash
   # from a local clone of your authz-demo fork
   git commit --allow-empty -m "ci: trigger build"
   git push
   ```

   (Or re-run it from the **Actions** tab.) The pipeline:
   - builds arm64 + amd64 images, pushes them to **`ghcr.io/<your-org>/authz-demo`**, and stitches a multi-arch manifest tagged with the commit SHA (this creates the GHCR package),
   - makes that package **public** so the cluster can pull it without a pull secret, and
   - in the final `update-deployment` job, rewrites `image: ghcr.io/<your-org>/authz-demo:<sha>` in `applications/authz-demo/deployment.yaml` of your `kse-labs-deployment` fork, then commits and pushes it.

> **Why a green build can still deploy nothing.** The deploy job only commits when the rewrite actually changed a line (`git diff --cached --quiet || (git commit && git push)`). If you skipped the org rename in 0.1, the file still reads `ghcr.io/kse-bd8338bbe006/authz-demo` while the workflow searches for `ghcr.io/<your-org>/authz-demo` - no match, no diff, no commit. The run is **green, but nothing is deployed**. This is why 0.1 must come first.

After the build finishes, confirm the deploy commit landed and the image tag is yours:

```bash
git -C kse-labs-deployment pull origin main   # expect a "deploy: authz-demo <sha>" commit
grep -n "image: ghcr.io" kse-labs-deployment/applications/authz-demo/deployment.yaml
kubectl -n applications get pods -l app.kubernetes.io/name=authz-demo
```

If the pod stays `ErrImagePull`: either the deploy job never committed (the tag in `deployment.yaml` does not exist in your GHCR - re-check 0.1 and the `DEPLOYMENT_PAT`), or the package is still private (re-run the build so its "make package public" step runs).

### 0.3 Create the databases

OpenFGA and authz-demo each need a Postgres database on the shared instance on the haproxy VM (`192.168.50.10:5432`). From the cloned repo:

```bash
cd authz-lab-setup
./openfga-db-setup.sh
```

**What the script does:**

| Step | What happens |
|------|-------------|
| 1 | Creates Postgres role `openfga` + database `openfga` |
| 2 | Creates Postgres role `authz_demo` + database `authz_demo` |
| 3 | Stores credentials in Vault at `secret/api-security/openfga-db` and `secret/api-security/authz-demo-db` |
| 4 | Forces External Secrets Operator to resync the Kubernetes Secrets |

The script is idempotent - re-running it reuses any password already stored in Vault. If OpenFGA or authz-demo started before the Secret existed, restart them so they pick up the credentials:

```bash
kubectl -n openfga rollout restart deployment/openfga
kubectl -n applications rollout restart deployment/authz-demo
```

> **Troubleshooting:** If OpenFGA stays in CrashLoopBackOff, check that the `openfga-db-credentials` Secret exists:
> ```bash
> kubectl -n openfga get secret openfga-db-credentials
> ```
> If it is missing, the ExternalSecret may have synced before you stored the Vault secret. Force a resync:
> ```bash
> kubectl -n openfga annotate externalsecret openfga-db-credentials \
>   force-sync="$(date +%s)" --overwrite
> ```
> Same for authz-demo:
> ```bash
> kubectl -n applications annotate externalsecret authz-demo-db \
>   force-sync="$(date +%s)" --overwrite
> ```

Verify OpenFGA and authz-demo are running:

```bash
kubectl -n openfga get pods
curl -sk https://openfga.192.168.50.10.nip.io/stores | python3 -m json.tool

kubectl -n applications get pods -l app.kubernetes.io/name=authz-demo
curl -sk https://authz-demo.192.168.50.10.nip.io/api/health
```

### 0.4 Configure Keycloak Authorization Services

```bash
cd authz-lab-setup
./keycloak-authz-setup.sh
```

It uses the Keycloak Admin API to add realm roles, the `documents-api` client with Authorization Services enabled, resources, scopes, policies, permissions, and demo users (`alice`, `bob`) - all without deleting your existing realm.

**What the script does:**

| Step | What is created |
|------|----------------|
| 1 | Realm roles: `document-viewer`, `document-editor` (composite, includes viewer), `document-admin` (composite, includes editor) |
| 2 | Confidential client `documents-api` with Authorization Services enabled |
| 3 | Authorization scopes: `document:view`, `document:edit`, `document:delete` |
| 4 | Resource `Document` (type `urn:authz-demo:resources:document`) with the three scopes |
| 5 | Role policies: `viewer-role-policy`, `editor-role-policy`, `admin-role-policy` |
| 6 | Scope-based permissions binding each policy to its scope |
| 7 | Users `alice` (document-admin) and `bob` (document-viewer), both with password same as username |

**Alternative (destructive):** If you prefer a clean slate, you can delete the realm and let Keycloak re-import it from the updated `realm-configmap.yaml`. See the comments at the bottom of `keycloak-authz-setup.sh`.

After the script completes, verify in the Keycloak admin console (`https://keycloak.192.168.50.10.nip.io`, user `admin` / `admin`, realm `api-security`):

- **Clients** -> `documents-api` -> Authorization tab shows Resources, Scopes, Policies, Permissions
- **Realm roles** shows `document-viewer`, `document-editor`, `document-admin`
- **Users** shows `alice` (with `document-admin` role) and `bob` (with `document-viewer` role)

### 0.5 Verify the full setup

Before moving to Part 1, verify everything is in place:

```bash
# 1. Keycloak authz config
KC_URL="https://keycloak.192.168.50.10.nip.io"
ADMIN_TOKEN=$(curl -sk "$KC_URL/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Check the documents-api client exists and has authz enabled
curl -sk "$KC_URL/admin/realms/api-security/clients?clientId=documents-api" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | python3 -c "import sys,json; c=json.load(sys.stdin)[0]; print('authz enabled:', c.get('authorizationServicesEnabled'))"

# 2. OpenFGA stores
curl -sk https://openfga.192.168.50.10.nip.io/stores | python3 -c "import sys,json; d=json.load(sys.stdin); print('stores:', len(d.get('stores',[])))"

# 3. authz-demo health
curl -sk https://authz-demo.192.168.50.10.nip.io/api/health
```

**Checkpoint:** Keycloak has the `documents-api` client with Authorization Services, OpenFGA is running, and `authz-demo` responds to health checks. You are ready for the practice.

---

## Overview

In Lectures 3-5 you authenticated users and validated tokens. Now you work with the next layer: **authorization** - what an authenticated user is allowed to do.

The lab ships a pre-configured Keycloak realm (`api-security`) with a `documents-api` client that has **Authorization Services** enabled. A Spring Boot app (`authz-demo`) exposes the same documents API through two different PDPs:

| Path | Decision point (PDP) | Model |
|------|----------------------|-------|
| `/kc/documents/**` | Keycloak Authorization Services | RBAC (roles + scopes) |
| `/fga/documents/**` | OpenFGA | ReBAC (relationships) |

In this practice you will:

1. Explore the Keycloak Authorization Services configuration (resources, scopes, policies, permissions) through the admin console
2. Test authorization decisions in the built-in **Evaluate** tool
3. Call the `/kc/documents` API with different users and observe how role-based policies grant or deny access
4. Trace the UMA flow that Keycloak uses to make per-request decisions
5. Compare with the OpenFGA-based `/fga/documents` endpoints to understand the RBAC-vs-ReBAC tradeoff

---

## Part 1: Explore the Keycloak Authorization Configuration

The `api-security` realm already has everything configured. Your first task is to understand what was set up and why.

### 1.1 Log in to Keycloak

Open `https://keycloak.192.168.50.10.nip.io` in your browser. Log in with:

- Username: `admin`
- Password: `admin`

Switch to the `api-security` realm (dropdown, top left).

### 1.2 Inspect the `documents-api` client

Go to **Clients** -> `documents-api`. This is a **confidential** client with Authorization Services enabled. Look at these tabs and answer the questions:

**Settings tab:**
- Is this a public or confidential client? How can you tell?
- What flows are enabled? Why is the Standard flow off?
- What does `Service accounts roles` being ON enable?

**Authorization tab** (appears only when Authorization is enabled):
- This is where resources, scopes, policies, and permissions live. We will explore each sub-tab next.

> **From lecture (slide: Keycloak as a Policy Decision Point):** A confidential client becomes a **resource server** when Authorization is enabled. It defines what is protected (resources), what actions exist (scopes), who is allowed (policies), and how they combine (permissions). The resource server then asks Keycloak to decide - Keycloak is the PDP.

### 1.3 Inspect the Resources

Go to **Authorization** -> **Resources**. You should see one resource: **Document**.

Click on it and note:

| Field | Value | Meaning |
|-------|-------|---------|
| Name | `Document` | How policies and permissions reference it |
| Type | `urn:authz-demo:resources:document` | Groups instances - one permission covers all documents of this type |
| URIs | (empty) | Would map HTTP paths for the policy enforcer adapter |
| Scopes | `document:view`, `document:edit`, `document:delete` | The actions that can be authorized on this resource |

> **Question to answer:** Why use a typed resource instead of creating a separate resource for each document ID? What would happen if you had 10,000 documents and each was a separate Keycloak resource?

### 1.4 Inspect the Scopes

Go to **Authorization** -> **Scopes**. You should see three scopes: `document:view`, `document:edit`, `document:delete`.

Scopes in Keycloak Authorization Services are **separate from OAuth scopes** (the ones in the `scope` claim of the access token). These are the actions that permissions protect.

**Why scopes are needed here.** A resource says *what* is protected; a scope says *which action* on it. The Keycloak docs define a scope as "a bounded extent of access that is possible to perform on a resource" - usually an action like view, edit, or delete (it can also stand for access to specific information a resource exposes). Without scopes, a permission on the `Document` resource would be all-or-nothing: a user could either reach the resource or not, with no way to say "viewers may read but only admins may delete."

Scopes give per-action granularity on a single resource. The one `Document` resource carries three scopes, and each scope is gated by its own permission and policy:

| HTTP call | Scope checked | Permission | Required policy |
|-----------|---------------|------------|-----------------|
| `GET /kc/documents` | `document:view` | View Document Permission | `viewer-role-policy` |
| `PUT /kc/documents/{id}` | `document:edit` | Edit Document Permission | `editor-role-policy` |
| `DELETE /kc/documents/{id}` | `document:delete` | Delete Document Permission | `admin-role-policy` |

That is why the lab uses **scope-based** permissions instead of a single resource-based one. A resource-based permission protects the whole resource (every action at once); a scope-based permission protects a specific action. So Bob (viewer) passes `document:view` but is denied `document:edit` and `document:delete` - all against the same `Document` resource. The scope is also part of the decision request the backend sends to Keycloak: the UMA call carries `permission=Document#document:view` (the `resource#scope` form - you will see this in Part 4).

> **From lecture (slide: Resources and Scopes):** "A resource is what you protect; a scope is an action on it." Scopes enumerate the actions that can be authorized. (slide: Permissions) A resource-based permission protects the whole resource/type; a scope-based permission protects a specific action.

> **Do not confuse** these resource scopes with the **Client Scope** policy type from the lecture's Policy Types slide. That policy type decides based on OAuth client scopes present on the token - a different concept from the action scopes you protect here.

### 1.5 Inspect the Policies

Go to **Authorization** -> **Policies**. You should see six entries. Three are role policies, three are scope-based permissions (Keycloak lists permissions under Policies).

**Role policies** (type: `role`):

| Policy name | Required role | Logic |
|-------------|--------------|-------|
| `viewer-role-policy` | `document-viewer` | Positive |
| `editor-role-policy` | `document-editor` | Positive |
| `admin-role-policy` | `document-admin` | Positive |

Click on `editor-role-policy` and look at its configuration:
- The `Roles` field contains `document-editor` with `Required: false`
- `Required: false` means the role is not mandatory - but since it is the only role in the policy, the policy effectively requires it
- Logic: **Positive** means the policy grants access when the condition is true (as opposed to Negative, which would deny)

> **Question to answer:** The `document-editor` role is a **composite** role that includes `document-viewer`. What does this mean for a user who has `document-editor`? Which policies will pass for them?

### 1.6 Inspect the Permissions

The remaining three entries are **scope-based permissions** (type: `scope`):

| Permission name | Protects scope | Applies to resource | Required policies |
|-----------------|---------------|---------------------|-------------------|
| `View Document Permission` | `document:view` | `Document` | `viewer-role-policy` |
| `Edit Document Permission` | `document:edit` | `Document` | `editor-role-policy` |
| `Delete Document Permission` | `document:delete` | `Document` | `admin-role-policy` |

Click on `Edit Document Permission`:
- **Decision strategy:** Unanimous (all policies must pass)
- **Apply Policies:** `editor-role-policy`

> **From lecture (slide: Permissions):** A permission binds policies to resources and scopes. "To edit a document, the editor-role-policy must pass." The same policy can be reused across many permissions - change the policy once and every permission that references it updates.

### 1.7 Inspect the Realm Roles and Users

Go to **Realm roles** (left sidebar). You should see three roles:

| Role | Composite? | Includes |
|------|-----------|----------|
| `document-viewer` | No | - |
| `document-editor` | Yes | `document-viewer` |
| `document-admin` | Yes | `document-editor` (and transitively `document-viewer`) |

Go to **Users**. You should see three users with different roles:

| User | Password | Realm roles |
|------|----------|-------------|
| `student` | `student` | (none) |
| `alice` | `alice` | `document-admin` |
| `bob` | `bob` | `document-viewer` |

> **Question to answer:** What happens when `student` tries to view a document? Which policy check fails?

**Checkpoint:** You can explain each piece of the Keycloak authz configuration: the resource, its scopes, the role policies, the scope-based permissions, and which users have which roles.

---

## Part 2: Test Decisions in the Evaluate Tool

Keycloak has a built-in testing tool that lets you simulate authorization decisions without writing code.

### 2.1 Open the Evaluate tool

Go to **Clients** -> `documents-api` -> **Authorization** -> **Evaluate** tab.

### 2.2 Test: Alice (admin) viewing a document

1. **Identity Information:**
   - User: `alice`
2. **Roles:**
   - Under **Realm Roles**, select `document-admin`
   - Click **Add**
3. Click **Evaluate**

Look at the results. You should see three permissions evaluated:

| Permission | Result |
|------------|--------|
| `View Document Permission` | **PERMIT** |
| `Edit Document Permission` | **PERMIT** |
| `Delete Document Permission` | **PERMIT** |

Click on `View Document Permission` to expand it. You should see:
- **Scopes:** `document:view`
- **Policies:** `viewer-role-policy` -> **PERMIT**

> Alice has `document-admin`, which includes `document-editor`, which includes `document-viewer`. The `viewer-role-policy` checks for `document-viewer` - Alice has it transitively, so the policy passes.

### 2.3 Test: Bob (viewer) editing a document

1. Clear previous selections (click the X next to each selection)
2. User: `bob`
3. Realm Roles: `document-viewer`
4. Click **Evaluate**

Look at the results:

| Permission | Result |
|------------|--------|
| `View Document Permission` | **PERMIT** |
| `Edit Document Permission` | **DENY** |
| `Delete Document Permission` | **DENY** |

Click on `Edit Document Permission` to expand:
- **Policies:** `editor-role-policy` -> **DENY**
- Bob has `document-viewer` but not `document-editor`, so the editor-role-policy fails

### 2.4 Test: Student (no roles) viewing a document

1. Clear previous selections
2. User: `student`
3. Do **not** add any realm roles
4. Click **Evaluate**

All three permissions should show **DENY**. Student has no document roles, so no role policy passes.

### 2.5 Test with a specific resource instance

The Evaluate tool can also test access to a specific resource instance (object-level). Try this:

1. User: `alice`, Roles: `document-admin`
2. Under **Resource**, select `Document` and enter an ID: `Document-4711`
3. Click **Evaluate**

The result should still be PERMIT for all three - the role-based policies do not depend on the specific instance ID. This is both the strength and the limitation of RBAC: it is simple and auditable, but it cannot express "Alice may edit document 4711 but not document 4712" without creating separate resources and permissions for each document.

> **Question to answer:** If you needed to express "Alice may edit only documents she owns" in Keycloak, what policy type would you use instead of a role policy? (Hint: look at the policy types listed in the lecture slides.)

**Checkpoint:** You have tested three users with different roles and can explain why each permission was granted or denied. Take screenshots of the Evaluate results for Alice (all PERMIT), Bob (view only), and Student (all DENY).

---

## Part 3: Call the API with Different Users

The `authz-demo` app exposes `/kc/documents/**` endpoints that delegate authorization to Keycloak. You will call them with tokens from different users and observe how the role-based policies translate to HTTP responses.

### 3.1 Get tokens for each user

Use the password grant to get access tokens for all three users:

```bash
KC_URL="https://keycloak.192.168.50.10.nip.io"
REALM="api-security"
CLIENT="spa-token-demo"

# Get tokens and save them
TOKEN_STUDENT=$(curl -sk "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
  -d "client_id=$CLIENT" -d "username=student" -d "password=student" \
  -d "grant_type=password" -d "scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

TOKEN_BOB=$(curl -sk "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
  -d "client_id=$CLIENT" -d "username=bob" -d "password=bob" \
  -d "grant_type=password" -d "scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

TOKEN_ALICE=$(curl -sk "$KC_URL/realms/$REALM/protocol/openid-connect/token" \
  -d "client_id=$CLIENT" -d "username=alice" -d "password=alice" \
  -d "grant_type=password" -d "scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
```

### 3.2 Decode the tokens

Decode each token's payload to see the realm roles:

```bash
decode_payload() {
  # Decode the JWT payload (base64url, padding-tolerant) and pretty-print it.
  echo "$1" | cut -d. -f2 | python3 -c "import sys,base64,json; s=sys.stdin.read().strip(); s+='='*(-len(s)%4); print(json.dumps(json.loads(base64.urlsafe_b64decode(s)), indent=2))"
}

echo "=== Alice's token ==="
decode_payload "$TOKEN_ALICE" | grep -E '"sub"|"preferred_username"|"realm_access"'

echo "=== Bob's token ==="
decode_payload "$TOKEN_BOB" | grep -E '"sub"|"preferred_username"|"realm_access"'

echo "=== Student's token ==="
decode_payload "$TOKEN_STUDENT" | grep -E '"sub"|"preferred_username"|"realm_access"'
```

Look at the `realm_access.roles` claim:
- Alice: `["document-editor", "document-viewer", "document-admin"]`
- Bob: `["document-viewer"]`
- Student: `[]` (no document roles)

> **Question to answer:** The `realm_access.roles` claim contains the user's realm roles. How does Keycloak Authorization Services know about these roles when evaluating policies? Does it read them from the token or from its internal database?

### 3.3 Test: Alice (admin) - full access

```bash
API="https://authz-demo.192.168.50.10.nip.io"

# List documents
echo "=== Alice list ==="
curl -sk "$API/kc/documents" -H "Authorization: Bearer $TOKEN_ALICE" | python3 -m json.tool

# Get a specific document
echo "=== Alice get doc 1 ==="
curl -sk "$API/kc/documents/1" -H "Authorization: Bearer $TOKEN_ALICE" | python3 -m json.tool

# Edit a document
echo "=== Alice edit doc 1 ==="
curl -sk -X PUT "$API/kc/documents/1" \
  -H "Authorization: Bearer $TOKEN_ALICE" \
  -H "Content-Type: application/json" \
  -d '{"title":"Q3 Roadmap (updated)","content":"Updated by alice."}' | python3 -m json.tool

# Delete a document
echo "=== Alice delete doc 3 ==="
curl -sk -o /dev/null -w "HTTP %{http_code}" -X DELETE "$API/kc/documents/3" \
  -H "Authorization: Bearer $TOKEN_ALICE"
echo ""
```

All operations should succeed (200/204). Alice has `document-admin`, which passes all three role policies.

> **Note:** The DELETE above removes document 3 from the shared documents table. The `/kc` and `/fga` endpoints read the same data, and Part 5 uses document 3 to demonstrate object-level access. You will reset the demo data at the start of Part 5 (step 5.0), so this delete does not break the later comparison.

### 3.4 Test: Bob (viewer) - view only

```bash
# List documents
echo "=== Bob list ==="
curl -sk "$API/kc/documents" -H "Authorization: Bearer $TOKEN_BOB" | python3 -m json.tool

# Get a specific document
echo "=== Bob get doc 1 ==="
curl -sk "$API/kc/documents/1" -H "Authorization: Bearer $TOKEN_BOB" | python3 -m json.tool

# Try to edit (should fail)
echo "=== Bob edit doc 1 (expect 403) ==="
curl -sk -o /dev/null -w "HTTP %{http_code}" -X PUT "$API/kc/documents/1" \
  -H "Authorization: Bearer $TOKEN_BOB" \
  -H "Content-Type: application/json" \
  -d '{"title":"hacked","content":"try"}'
echo ""

# Try to delete (should fail)
echo "=== Bob delete doc 1 (expect 403) ==="
curl -sk -o /dev/null -w "HTTP %{http_code}" -X DELETE "$API/kc/documents/1" \
  -H "Authorization: Bearer $TOKEN_BOB"
echo ""
```

GET and list should succeed (Bob has `document-viewer`). PUT and DELETE should return **403 Forbidden** - the `editor-role-policy` and `admin-role-policy` fail.

### 3.5 Test: Student (no roles) - no access

```bash
# Try to list documents
echo "=== Student list (expect 403) ==="
curl -sk -o /dev/null -w "HTTP %{http_code}" "$API/kc/documents" \
  -H "Authorization: Bearer $TOKEN_STUDENT"
echo ""

# Try to get a document
echo "=== Student get doc 1 (expect 403) ==="
curl -sk -o /dev/null -w "HTTP %{http_code}" "$API/kc/documents/1" \
  -H "Authorization: Bearer $TOKEN_STUDENT"
echo ""
```

All requests should return **403 Forbidden**. Student has no document roles, so even the `viewer-role-policy` fails.

> **Question to answer:** Student has a valid access token (authenticated). Why does the API return 403 and not 401? What is the difference between these two status codes in the context of authorization?

**Checkpoint:** You have tested all three users against the `/kc/documents` API and observed the role-based access control in action. Alice can do everything, Bob can only view, Student is denied entirely.

---

## Part 4: Trace the UMA Decision Flow

The `/kc/documents` endpoints do not just check the token's `realm_access.roles` claim locally. They call back to Keycloak on every request using the **UMA 2.0 grant**. This section traces that flow.

### 4.1 Read the source code

Read the two files that implement the Keycloak-side authorization in `authz-demo`. The source is at:

- [KeycloakAuthzService.java](https://github.com/kse-bd8338bbe006/authz-demo/blob/main/backend/src/main/java/com/example/authzdemo/authz/KeycloakAuthzService.java)
- [KeycloakDocumentController.java](https://github.com/kse-bd8338bbe006/authz-demo/blob/main/backend/src/main/java/com/example/authzdemo/controller/KeycloakDocumentController.java)

For each file, answer:

| File | Questions |
|------|-----------|
| `KeycloakAuthzService.java` | What grant type is used? What parameters are sent in the token request? What does `response_mode=decision` do? What happens when Keycloak returns 403? |
| `KeycloakDocumentController.java` | Where in the request lifecycle is the authorization check called? What is the `RESOURCE` constant? How does the `require()` method work? |

### 4.2 Understand the UMA flow

The `KeycloakAuthzService` makes this HTTP call to Keycloak on every request:

```
POST /realms/api-security/protocol/openid-connect/token
Authorization: Bearer <user's access token>
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:uma-ticket
&audience=documents-api
&permission=Document#document:view
&response_mode=decision
```

Keycloak then:
1. Validates the user's access token (authentication)
2. Looks up the `documents-api` client's authorization configuration
3. Evaluates the policies attached to the `Document` resource and `document:view` scope
4. Returns `{"result": true}` if allowed, or `403` with `{"error":"access_denied"}` if denied

> **From lecture (slide: How a Decision Flows):** This is the UMA 2.0 flow. The resource server (PEP) asks Keycloak (PDP) for a decision. The user's own access token identifies the requesting party. No client secret is needed - the decision is about the user, not the client.

### 4.3 Observe the decision call indirectly

You cannot see the backend's call to Keycloak from the outside, but you can infer it from the response times and error messages. Try this:

```bash
# A successful request - the backend called Keycloak and got {"result": true}
echo "=== Bob GET (expect 200) ==="
curl -sk -w "\nHTTP %{http_code}, time: %{time_total}s\n" \
  "$API/kc/documents/1" -H "Authorization: Bearer $TOKEN_BOB"

# A denied request - the backend called Keycloak and got 403
echo "=== Bob DELETE (expect 403) ==="
curl -sk -w "\nHTTP %{http_code}, time: %{time_total}s\n" \
  -X DELETE "$API/kc/documents/1" -H "Authorization: Bearer $TOKEN_BOB"
```

Both requests take roughly the same time - the backend makes the UMA call either way. The difference is only in Keycloak's answer.

> **Question to answer:** The UMA decision call happens on **every request**. What is the latency implication of this? How could you reduce the per-request overhead while keeping decisions fresh?

### 4.4 Compare with local-only RBAC

Think about an alternative: the backend could check `realm_access.roles` from the JWT locally, without calling Keycloak at all.

| Approach | Pros | Cons |
|----------|------|------|
| **Local JWT role check** | No network call, fast | Roles are baked into the token at issuance time; role changes take effect only when the token expires |
| **UMA callback to Keycloak** | Decisions reflect current roles/policies; auditable in one place | Extra network call per request; Keycloak becomes a runtime dependency |

> **Question to answer:** If an admin revokes Bob's `document-viewer` role, how long does it take for the change to take effect with each approach?

### 4.5 How the decision is delivered: three response modes

The `uma-ticket` grant can return three different things, selected by the `response_mode` parameter. The lecture's "How a Decision Flows (UMA + RPT)" diagram and this lab use different modes, so it is worth being precise:

| `response_mode` | Keycloak returns | Who enforces | Calls Keycloak per request? |
|-----------------|------------------|--------------|-----------------------------|
| *(omitted)* - **RPT** | a Requesting Party Token: an access token (JWT) with an `authorization.permissions` claim | the resource server validates the RPT locally (or via token introspection) | No - reuse the RPT until it expires |
| **`decision`** | `{"result": true}`, or HTTP 403 on deny | Keycloak makes the decision; the service just reads allow/deny | Yes - one call per check |
| **`permissions`** | the list of granted resources + scopes | the service matches the returned list | Yes - one call per check |

**What this lab uses:** `authz-demo` uses **`response_mode=decision`** (see `KeycloakAuthzService`). It calls Keycloak on every request and reads `{"result": true}`. Nothing is added to a token that the app forwards - the user's plain access token is all that travels. That is why you will not find an RPT or a `permissions` claim anywhere in this lab.

**The slide's RPT flow is the alternative.** In RPT mode the decision is evaluated once at Keycloak, packed into the RPT, and the resource server then checks the RPT locally without calling back. That cuts per-request IdP calls, but the permissions go stale until the RPT is refreshed - the same freshness-vs-latency tradeoff as in 4.4. So "Keycloak is not called per request" is true for the RPT mode shown on the slide, but **not** for this lab's `decision` mode.

> **Question to answer:** This lab calls Keycloak on every request. If you switched to RPT mode to cut that load, what would you give up? When would each mode be the right choice?

**Checkpoint:** You can explain the UMA flow: what the backend sends to Keycloak, what Keycloak evaluates, and what comes back. You can name the three `response_mode` variants (RPT, `decision`, `permissions`), say which one this lab uses, and explain the tradeoff between local JWT role checks and per-request UMA callbacks.

---

## Part 5: Compare with OpenFGA (ReBAC)

The `authz-demo` app also exposes `/fga/documents/**` endpoints that use OpenFGA instead of Keycloak for authorization. This section compares the two models side by side.

### 5.0 Reset the demo data

In Part 3 you edited document 1 and deleted document 3 through the `/kc` API. Both `/kc` and `/fga` read the same documents table, so document 3 no longer exists - and Part 5 needs it (it is Alice's private document). Restart `authz-demo` to re-seed the demo documents. The seed runs on every boot with idempotent `INSERT ... WHERE NOT EXISTS` guards, so it re-inserts any missing rows without touching rows that are still present:

```bash
kubectl -n applications rollout restart deployment/authz-demo
kubectl -n applications rollout status deployment/authz-demo --timeout=120s
```

The OpenFGA relationship tuples are seeded separately by the app on startup and were not affected by the `/kc` operations, so only the document rows needed restoring. Verify all three documents are back:

```bash
API="https://authz-demo.192.168.50.10.nip.io"
curl -sk "$API/kc/documents" -H "Authorization: Bearer $TOKEN_ALICE" | python3 -m json.tool
```

You should see documents 1, 2, and 3. (If `$TOKEN_ALICE` has expired, re-run the token command from step 3.1.)

### 5.1 Understand the OpenFGA model

Read the FGA authorization model (DSL form, from the [README](https://github.com/kse-bd8338bbe006/authz-demo)):

```
type user
type team
  relations
    define member: [user]
type document
  relations
    define owner: [user]
    define editor: [user, team#member] or owner
    define viewer: [user, team#member] or editor
```

The demo seeds these relationship tuples:

| Tuple | Meaning |
|-------|---------|
| `user:bob, member, team:eng` | Bob is a member of the engineering team |
| `user:alice, owner, document:1` | Alice owns document 1 |
| `team:eng#member, viewer, document:1` | Engineering team members can view document 1 |
| `user:bob, owner, document:2` | Bob owns document 2 |
| `user:alice, editor, document:2` | Alice can edit document 2 |
| `user:alice, owner, document:3` | Alice owns document 3 (private) |

### 5.2 Test the OpenFGA endpoints

```bash
API="https://authz-demo.192.168.50.10.nip.io"

# Alice: should see all documents she has a relationship to
echo "=== Alice /fga list ==="
curl -sk "$API/fga/documents" -H "Authorization: Bearer $TOKEN_ALICE" | python3 -m json.tool

# Bob: should see documents 1 and 2, but NOT 3
echo "=== Bob /fga list ==="
curl -sk "$API/fga/documents" -H "Authorization: Bearer $TOKEN_BOB" | python3 -m json.tool

# Bob tries to access document 3 directly (BOLA test)
echo "=== Bob /fga get doc 3 (expect 403) ==="
curl -sk -o /dev/null -w "HTTP %{http_code}" "$API/fga/documents/3" \
  -H "Authorization: Bearer $TOKEN_BOB"
echo ""

# Bob tries to edit document 1 (he is a viewer via team, not editor)
echo "=== Bob /fga edit doc 1 (expect 403) ==="
curl -sk -o /dev/null -w "HTTP %{http_code}" -X PUT "$API/fga/documents/1" \
  -H "Authorization: Bearer $TOKEN_BOB" \
  -H "Content-Type: application/json" \
  -d '{"title":"hacked","content":"try"}'
echo ""

# Student has no relationship to any document
echo "=== Student /fga list (expect 200 and []) ==="
curl -sk -w "\nHTTP %{http_code}\n" "$API/fga/documents" \
  -H "Authorization: Bearer $TOKEN_STUDENT"
```

> **Note the difference for Student:** on `/kc`, listing returns **403** (no `document-viewer` role, so the function-level role check fails). On `/fga`, listing returns **200 with an empty array** - Student is authenticated and allowed to call the endpoint, but `list-objects` finds no documents Student has a relationship to. ReBAC filters by relationship rather than rejecting the call outright.

### 5.3 Compare the two models

Fill in this table based on what you observed:

| Scenario | `/kc` (Keycloak RBAC) | `/fga` (OpenFGA ReBAC) |
|----------|----------------------|------------------------|
| Alice lists documents | 3 docs (she is admin) | ? |
| Bob lists documents | 3 docs (viewer role -> all docs) | ? |
| Bob GET document 3 | ? | ? |
| Bob edits document 1 | ? | ? |
| Student lists documents | ? | ? |

> **Key difference:** The `/kc` endpoints use **role-based** authorization. Bob has `document-viewer`, so he can view **every** document - the role does not distinguish between document 1, 2, or 3. The `/fga` endpoints use **relationship-based** authorization. Bob can view document 1 (via team membership) and document 2 (he is the owner), but not document 3 (no relationship exists). Change the ID in the URL and OpenFGA checks that specific relationship - BOLA is prevented by design.

### 5.4 Read the OpenFGA controller code

Read [FgaDocumentController.java](https://github.com/kse-bd8338bbe006/authz-demo/blob/main/backend/src/main/java/com/example/authzdemo/controller/FgaDocumentController.java) and compare with `KeycloakDocumentController.java`:

| Aspect | Keycloak controller | OpenFGA controller |
|--------|-------------------|--------------------|
| Authorization check | `keycloak.isAllowed(token, "Document", "document:view")` | `fga.check("user:alice", "viewer", "document:1")` |
| What is checked | Does the user have the right role? | Does the user have a relationship to **this specific object**? |
| List endpoint | Returns all documents (role covers all) | Uses `list-objects` to return only documents the user has a relationship to |
| BOLA protection | None (role-based, not object-based) | Full (every access checks the specific object) |

> **From lecture (slide: Keycloak Authz vs OpenFGA):** Not mutually exclusive. A common architecture: Keycloak for authentication, roles, and scopes at the edge; OpenFGA for fine-grained object-level decisions inside services. Coarse at the door, relationship-based in the room.

**Checkpoint:** You can explain the difference between role-based access control (Keycloak `/kc`) and relationship-based access control (OpenFGA `/fga`), and why ReBAC prevents BOLA while pure RBAC does not.

---

## Part 6: The Authorization Pipeline in One Request

This part connects the practice back to the lecture's big picture: the full authorization pipeline from edge to object.

### 6.1 Map the layers to the lab

For a request to `GET /fga/documents/1` with Alice's token, trace each layer:

| Layer | What runs | Where in the lab |
|-------|-----------|-----------------|
| **Authentication** | JWT signature + issuer + expiry validation | Spring Security resource server |
| **Coarse-grained** | (not enforced on /fga, but could be) | Would be scope check at the gateway |
| **Object-level** | `fga.check("user:alice", "viewer", "document:1")` | OpenFgaService -> OpenFGA API |

### 6.2 Answer the synthesis questions

1. **Authentication vs authorization:** The `/kc/documents` endpoint returns 403 for Student, not 401. What does 401 mean? What does 403 mean? Why is Student's response 403 and not 401?

2. **Function-level vs object-level:** The `/kc` endpoints check function-level authorization (may the user call this endpoint at all?). The `/fga` endpoints add object-level authorization (may the user touch this specific document?). Which OWASP API risk does each missing check correspond to?

3. **PEP and PDP:** In the `/kc` flow, which component is the PEP and which is the PDP? What about in the `/fga` flow?

4. **Model choice:** When would you use Keycloak Authorization Services (RBAC) vs OpenFGA (ReBAC) for a given authorization requirement? Give a concrete example of each.

**Checkpoint:** You can trace a request through the full authorization pipeline and explain which layer prevents which class of attack.

---

## Deliverables

For grading, demonstrate:

1. **Keycloak authz configuration** - screenshots of the `documents-api` client showing: the Settings tab (client type, flows), the Authorization tab with Resources, Scopes, Policies, and Permissions sub-tabs, the realm roles, and the three users with their role assignments

2. **Evaluate tool results** - screenshots showing: Alice (all PERMIT), Bob (view PERMIT, edit/delete DENY), Student (all DENY). For at least one, expand a permission to show which policy passed or failed.

3. **API test with three users** - terminal output showing:
   - Alice: successful GET, PUT, DELETE (200/204)
   - Bob: successful GET (200), rejected PUT and DELETE (403)
   - Student: rejected GET (403)

4. **OpenFGA comparison** - terminal output showing Bob's `/fga/documents` list (only docs 1 and 2) and Bob's attempt to GET `/fga/documents/3` (403). Explain why the result differs from `/kc/documents`.

5. **UMA flow explanation** - written answer describing what the backend sends to Keycloak (grant type, parameters), what Keycloak evaluates, and what the response looks like for allow vs deny

6. **Source code analysis** - written answers to the questions from Parts 1.2, 1.3, 1.5, 1.7, 2.5, 3.2, 3.5, 4.3, and 4.4

7. **Synthesis questions** - written answers to the four questions in Part 6.2

8. **Comparison table** - the completed table from Part 5.3, plus the comparison from Part 5.4
