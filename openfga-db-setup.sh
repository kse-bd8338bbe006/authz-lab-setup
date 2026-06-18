#!/bin/bash
# Create the Postgres databases and Vault secrets for OpenFGA and authz-demo.
#
# OpenFGA (infra/openfga) and authz-demo (applications/authz-demo) each need a
# Postgres database on the shared instance running on the haproxy VM
# (192.168.50.10:5432). This script creates the roles + databases and stores
# the credentials in Vault, where External Secrets Operator syncs them into the
# Kubernetes Secrets that the two Deployments mount.
#
# The script is idempotent: re-running it reuses any password already stored in
# Vault (so the database role, the Vault secret, and the running pods stay in
# sync) and only generates a new one the first time.
#
# Every external call (multipass exec, kubectl, kubectl exec) is wrapped in a
# hard wall-clock timeout and surfaces its errors, so the script can never hang
# silently the way it could before: if the cluster API, the VM, or Postgres
# stalls, you get a clear error and a non-zero exit instead of a frozen
# terminal. Tunable via the env vars below.
#
# Prerequisites:
#   - Lab cluster running (haproxy VM with Postgres, Vault unsealed)
#   - multipass and kubectl available and pointed at the lab
#   - openssl available
#
# Usage:
#   chmod +x openfga-db-setup.sh
#   ./openfga-db-setup.sh
#
# Env knobs:
#   VM=haproxy          name of the multipass VM hosting Postgres
#   OP_TIMEOUT=30       hard timeout (seconds) for any single external call
#   KUBE_TIMEOUT=15s    kubectl per-request timeout
#   RETRIES=3           retries for reading the Vault root token
#   OPENFGA_PASS / AUTHZ_DEMO_PASS   override the generated passwords

set -euo pipefail

VM="${VM:-haproxy}"
OP_TIMEOUT="${OP_TIMEOUT:-30}"
KUBE_TIMEOUT="${KUBE_TIMEOUT:-15s}"
RETRIES="${RETRIES:-3}"

kubectl_cmd=(kubectl --request-timeout="$KUBE_TIMEOUT")

echo "=== Lecture 6: OpenFGA + authz-demo database setup ==="
echo ""

# ---------------------------------------------------------------------------
# Portable hard timeout. macOS ships no `timeout`/`gtimeout` and `multipass
# exec` has no timeout flag, so we run the command in the background and kill it
# if it overruns. stdout is left on the function's stdout so callers can still
# capture it with $(...). The watchdog's own fds go to /dev/null so it never
# keeps a command-substitution pipe open after the real command has finished.
# Returns the command's exit code, or 124 if it was killed for timing out.
# ---------------------------------------------------------------------------
with_timeout() {
  local secs="$1"; shift
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null; sleep 2; kill -KILL "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  local killer_pid=$!
  local rc=0
  wait "$cmd_pid" 2>/dev/null || rc=$?
  if kill -0 "$killer_pid" 2>/dev/null; then
    # command finished on its own; stop the watchdog
    kill "$killer_pid" 2>/dev/null || true
    wait "$killer_pid" 2>/dev/null || true
  else
    # watchdog already fired -> the command was killed for timing out
    rc=124
  fi
  return "$rc"
}

# Run a SQL statement as the postgres superuser over the local socket on the VM
# (peer auth - no password). stdout is returned; stderr is captured and only
# printed on failure, so the harmless "could not change directory to
# /home/ubuntu" warning sudo emits (postgres can't enter the invoking user's
# home) stays out of the way while real SQL errors still surface.
psql_admin() {
  local err out rc=0
  err="$(mktemp)"
  out="$(with_timeout "$OP_TIMEOUT" multipass exec "$VM" -- \
    sudo -u postgres psql -v ON_ERROR_STOP=1 -tAc "$1" </dev/null 2>"$err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    grep -v 'could not change directory to' "$err" >&2 || true
  fi
  rm -f "$err"
  printf '%s' "$out"
  return "$rc"
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 0: preflight - fail fast (and loudly) if anything is unreachable
# ---------------------------------------------------------------------------
echo "=== Step 0: preflight ==="
command -v multipass >/dev/null || die "multipass not found on PATH."
command -v kubectl   >/dev/null || die "kubectl not found on PATH."
command -v openssl   >/dev/null || die "openssl not found on PATH."

echo "  -> multipass VM '$VM' reachable ..."
with_timeout "$OP_TIMEOUT" multipass exec "$VM" -- true </dev/null 2>/dev/null \
  || die "cannot exec into VM '$VM' within ${OP_TIMEOUT}s. Is it Running?  multipass list"

echo "  -> postgres on '$VM' reachable ..."
psql_admin "SELECT 1;" >/dev/null 2>&1 \
  || die "postgres not reachable on '$VM' via local socket within ${OP_TIMEOUT}s."

echo "  -> kubernetes API reachable ..."
with_timeout "$OP_TIMEOUT" "${kubectl_cmd[@]}" get --raw='/healthz' >/dev/null 2>&1 \
  || die "kubernetes API not reachable. context=$(kubectl config current-context 2>/dev/null || echo '<none>')"

echo "  -> vault-0 pod present ..."
with_timeout "$OP_TIMEOUT" "${kubectl_cmd[@]}" -n vault get pod vault-0 >/dev/null 2>&1 \
  || die "vault-0 pod not found in namespace 'vault'."
echo "  preflight ok."
echo ""

# ---------------------------------------------------------------------------
# Read the Vault root token (with retries; surfaces the real error on failure)
# ---------------------------------------------------------------------------
read_root_token() {
  local i raw token
  for i in $(seq 1 "$RETRIES"); do
    raw=$(with_timeout "$OP_TIMEOUT" "${kubectl_cmd[@]}" -n vault get secret vault-unseal-key \
      -o jsonpath='{.data.root-token}' 2>/dev/null || true)
    if [ -n "$raw" ]; then
      token=$(printf '%s' "$raw" | base64 -d 2>/dev/null || true)
      if [ -n "$token" ]; then printf '%s' "$token"; return 0; fi
    fi
    if [ "$i" -lt "$RETRIES" ]; then sleep 2; fi
  done
  return 1
}

echo "=== Reading Vault root token ==="
ROOT_TOKEN=$(read_root_token) || die \
"could not read the Vault root token after ${RETRIES} tries.
  Try: kubectl -n vault get secret vault-unseal-key -o jsonpath='{.data.root-token}' | base64 -d
  (Is Vault unsealed and vault-0 Ready?)"
echo "  ok."
echo ""

# ---------------------------------------------------------------------------
# Passwords: reuse what is already in Vault, otherwise generate (alphanumeric,
# no pipe-to-head so set -o pipefail can't trip on SIGPIPE).
# ---------------------------------------------------------------------------
vault_get_password() {
  with_timeout "$OP_TIMEOUT" "${kubectl_cmd[@]}" exec -n vault vault-0 -- sh -c \
    "VAULT_TOKEN=$ROOT_TOKEN vault kv get -field=password $1" 2>/dev/null || true
}

gen_password() {
  local p
  p=$(openssl rand -base64 24)
  p=${p//[^a-zA-Z0-9]/}
  printf '%s' "${p:0:24}"
}

OPENFGA_PASS="${OPENFGA_PASS:-$(vault_get_password secret/api-security/openfga-db)}"
[ -n "$OPENFGA_PASS" ] || OPENFGA_PASS="$(gen_password)"

AUTHZ_DEMO_PASS="${AUTHZ_DEMO_PASS:-$(vault_get_password secret/api-security/authz-demo-db)}"
[ -n "$AUTHZ_DEMO_PASS" ] || AUTHZ_DEMO_PASS="$(gen_password)"

# ---------------------------------------------------------------------------
# Helper: ensure a (role, database) pair exists. Idempotent and free of any
# dollar-quoting (which an extra sudo/shell layer can mangle): each object is
# checked with a SELECT, then created or altered with a plain statement.
# ---------------------------------------------------------------------------
ensure_db() {
  local role="$1" db="$2" pass="$3"
  echo "  -> ensuring role '$role' ..."
  if [ "$(psql_admin "SELECT 1 FROM pg_roles WHERE rolname = '$role';")" = "1" ]; then
    psql_admin "ALTER ROLE $role LOGIN PASSWORD '$pass';" >/dev/null \
      || die "altering role '$role' failed or timed out (${OP_TIMEOUT}s).
  Check: multipass exec $VM -- sudo -u postgres psql -c '\\du'"
  else
    psql_admin "CREATE ROLE $role LOGIN PASSWORD '$pass';" >/dev/null \
      || die "creating role '$role' failed or timed out (${OP_TIMEOUT}s).
  Check: multipass exec $VM -- sudo -u postgres psql -c '\\du'"
  fi

  echo "  -> ensuring database '$db' ..."
  if [ "$(psql_admin "SELECT 1 FROM pg_database WHERE datname = '$db';")" = "1" ]; then
    echo "     database '$db' already exists."
  else
    psql_admin "CREATE DATABASE $db OWNER $role;" >/dev/null \
      || die "creating database '$db' failed or timed out (${OP_TIMEOUT}s).
  A common cause is an open connection to template1. Check:
  multipass exec $VM -- sudo -u postgres psql -c \"SELECT datname,pid,state FROM pg_stat_activity WHERE datname='template1';\""
  fi
  echo "  $role role + database ready."
}

# ---------------------------------------------------------------------------
# Step 1 + 2: roles + databases
# ---------------------------------------------------------------------------
echo "=== Step 1: openfga role + database ==="
ensure_db openfga openfga "$OPENFGA_PASS"
echo ""

echo "=== Step 2: authz_demo role + database ==="
ensure_db authz_demo authz_demo "$AUTHZ_DEMO_PASS"
echo ""

# ---------------------------------------------------------------------------
# Step 3: store credentials in Vault
# ---------------------------------------------------------------------------
vault_put() {
  with_timeout "$OP_TIMEOUT" "${kubectl_cmd[@]}" exec -n vault vault-0 -- sh -c \
    "VAULT_TOKEN=$ROOT_TOKEN vault kv put $1" >/dev/null
}

echo "=== Step 3: store credentials in Vault ==="
vault_put "secret/api-security/openfga-db username=openfga password='$OPENFGA_PASS'" \
  || die "writing secret/api-security/openfga-db failed or timed out (${OP_TIMEOUT}s)."
echo "  wrote secret/api-security/openfga-db"

vault_put "secret/api-security/authz-demo-db username=authz_demo password='$AUTHZ_DEMO_PASS'" \
  || die "writing secret/api-security/authz-demo-db failed or timed out (${OP_TIMEOUT}s)."
echo "  wrote secret/api-security/authz-demo-db"
echo ""

# ---------------------------------------------------------------------------
# Step 4: force External Secrets Operator to resync (non-fatal if absent)
# ---------------------------------------------------------------------------
echo "=== Step 4: force External Secrets Operator to resync ==="
SYNC_TS="$(date +%s)"
with_timeout "$OP_TIMEOUT" "${kubectl_cmd[@]}" -n openfga annotate externalsecret openfga-db-credentials \
  force-sync="$SYNC_TS" --overwrite >/dev/null 2>&1 \
  && echo "  resynced openfga-db-credentials" \
  || echo "  ExternalSecret 'openfga-db-credentials' not found yet (ArgoCD will create it)"
with_timeout "$OP_TIMEOUT" "${kubectl_cmd[@]}" -n applications annotate externalsecret authz-demo-db \
  force-sync="$SYNC_TS" --overwrite >/dev/null 2>&1 \
  && echo "  resynced authz-demo-db" \
  || echo "  ExternalSecret 'authz-demo-db' not found yet (ArgoCD will create it)"

echo ""
echo "=== Done ==="
echo ""
echo "If OpenFGA or authz-demo started before the Secret existed, restart them so"
echo "they pick up the database credentials:"
echo "  kubectl -n openfga rollout restart deployment/openfga"
echo "  kubectl -n applications rollout restart deployment/authz-demo"
echo ""
echo "Verify:"
echo "  kubectl -n openfga get pods"
echo "  curl -sk https://openfga.192.168.50.10.nip.io/stores | python3 -m json.tool"
echo "  curl -sk https://authz-demo.192.168.50.10.nip.io/api/health"
