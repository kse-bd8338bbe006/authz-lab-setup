#!/bin/bash
# Setup Keycloak Authorization Services for Lecture 6.
#
# This script adds the documents-api client (with Authorization Services),
# realm roles, and demo users (alice, bob) to an EXISTING api-security realm.
# It uses the Keycloak Admin API - nothing is deleted, existing config is
# left untouched.
#
# Prerequisites:
#   - Lab cluster running, Keycloak accessible
#   - api-security realm already exists (from previous lectures)
#   - curl, python3 available
#
# Usage:
#   chmod +x keycloak-authz-setup.sh
#   ./keycloak-authz-setup.sh
#
# If you prefer to start fresh (destructive - deletes the realm and lets
# Keycloak re-import from the updated realm-configmap.yaml), see the
# alternative approach at the bottom of this script.

set -euo pipefail

KC_URL="${KC_URL:-https://keycloak.192.168.50.10.nip.io}"
REALM="${REALM:-api-security}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"

# ---------------------------------------------------------------------------
# Helper: get an admin token for the master realm
# ---------------------------------------------------------------------------
admin_token() {
  curl -sk "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d grant_type=password \
    -d client_id=admin-cli \
    -d username="$ADMIN_USER" \
    -d password="$ADMIN_PASS" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

# ---------------------------------------------------------------------------
# Helper: call the Admin API
# ---------------------------------------------------------------------------
kc_api() {
  local method="$1"; shift
  local path="$1"; shift
  curl -sk -X "$method" \
    -H "Authorization: Bearer $(admin_token)" \
    -H "Content-Type: application/json" \
    "$@" \
    "$KC_URL/admin/realms/$REALM/$path"
}

echo "=== Step 1: Create realm roles ==="

for role in document-viewer document-editor document-admin; do
  echo "  Creating role: $role"
  kc_api POST "roles" -d "{\"name\":\"$role\"}" > /dev/null || echo "    (may already exist)"
done

# Set up role hierarchy: document-editor includes document-viewer,
# document-admin includes document-editor.
# The API: POST to roles-by-id/{parent_id}/composites with the child role.
echo "  Setting up role hierarchy..."
VIEWER_ID=$(kc_api GET "roles/document-viewer" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
EDITOR_ID=$(kc_api GET "roles/document-editor" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
ADMIN_ID=$(kc_api GET "roles/document-admin" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# document-editor includes document-viewer
kc_api POST "roles-by-id/$EDITOR_ID/composites" \
  -d "[{\"id\":\"$VIEWER_ID\"}]" > /dev/null 2>&1 || echo "    editor->viewer composite (may already exist)"

# document-admin includes document-editor
kc_api POST "roles-by-id/$ADMIN_ID/composites" \
  -d "[{\"id\":\"$EDITOR_ID\"}]" > /dev/null 2>&1 || echo "    admin->editor composite (may already exist)"

echo ""
echo "=== Step 2: Create the documents-api client ==="

kc_api POST "clients" -d '{
  "clientId": "documents-api",
  "name": "Documents API (Lecture 6 resource server)",
  "enabled": true,
  "publicClient": false,
  "bearerOnly": false,
  "standardFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": true,
  "authorizationServicesEnabled": true,
  "secret": "documents-api-secret-lab-2026",
  "protocol": "openid-connect"
}' > /dev/null || echo "  Client may already exist"

CLIENT_UUID=$(kc_api GET "clients?clientId=documents-api" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
echo "  Client UUID: $CLIENT_UUID"

echo ""
echo "=== Step 3: Create authorization scopes ==="

for scope in "document:view" "document:edit" "document:delete"; do
  echo "  Creating scope: $scope"
  kc_api POST "clients/$CLIENT_UUID/authz/resource-server/scope" \
    -d "{\"name\":\"$scope\"}" > /dev/null || echo "    (may already exist)"
done

echo ""
echo "=== Step 4: Create the Document resource ==="

kc_api POST "clients/$CLIENT_UUID/authz/resource-server/resource" -d '{
  "name": "Document",
  "displayName": "Document",
  "type": "urn:authz-demo:resources:document",
  "ownerManagedAccess": false,
  "scopes": [
    {"name": "document:view"},
    {"name": "document:edit"},
    {"name": "document:delete"}
  ]
}' > /dev/null || echo "  Resource may already exist"

echo ""
echo "=== Step 5: Create role-based policies ==="

# We need the role IDs (not names) for policy config.
VIEWER_ID=$(kc_api GET "roles/document-viewer" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
EDITOR_ID=$(kc_api GET "roles/document-editor" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
ADMIN_ID=$(kc_api GET "roles/document-admin" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

echo "  Creating viewer-role-policy (role: document-viewer)"
kc_api POST "clients/$CLIENT_UUID/authz/resource-server/policy" -d "{
  \"name\": \"viewer-role-policy\",
  \"description\": \"Caller has the document-viewer role\",
  \"type\": \"role\",
  \"logic\": \"POSITIVE\",
  \"decisionStrategy\": \"UNANIMOUS\",
  \"config\": {
    \"roles\": \"[{\\\"id\\\":\\\"$VIEWER_ID\\\",\\\"required\\\":false}]\"
  }
}" > /dev/null || echo "    (may already exist)"

echo "  Creating editor-role-policy (role: document-editor)"
kc_api POST "clients/$CLIENT_UUID/authz/resource-server/policy" -d "{
  \"name\": \"editor-role-policy\",
  \"description\": \"Caller has the document-editor role\",
  \"type\": \"role\",
  \"logic\": \"POSITIVE\",
  \"decisionStrategy\": \"UNANIMOUS\",
  \"config\": {
    \"roles\": \"[{\\\"id\\\":\\\"$EDITOR_ID\\\",\\\"required\\\":false}]\"
  }
}" > /dev/null || echo "    (may already exist)"

echo "  Creating admin-role-policy (role: document-admin)"
kc_api POST "clients/$CLIENT_UUID/authz/resource-server/policy" -d "{
  \"name\": \"admin-role-policy\",
  \"description\": \"Caller has the document-admin role\",
  \"type\": \"role\",
  \"logic\": \"POSITIVE\",
  \"decisionStrategy\": \"UNANIMOUS\",
  \"config\": {
    \"roles\": \"[{\\\"id\\\":\\\"$ADMIN_ID\\\",\\\"required\\\":false}]\"
  }
}" > /dev/null || echo "    (may already exist)"

echo ""
echo "=== Step 6: Create scope-based permissions ==="

echo "  Creating View Document Permission"
kc_api POST "clients/$CLIENT_UUID/authz/resource-server/permission" -d '{
  "name": "View Document Permission",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["Document"],
  "scopes": ["document:view"],
  "policies": ["viewer-role-policy"]
}' > /dev/null || echo "    (may already exist)"

echo "  Creating Edit Document Permission"
kc_api POST "clients/$CLIENT_UUID/authz/resource-server/permission" -d '{
  "name": "Edit Document Permission",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["Document"],
  "scopes": ["document:edit"],
  "policies": ["editor-role-policy"]
}' > /dev/null || echo "    (may already exist)"

echo "  Creating Delete Document Permission"
kc_api POST "clients/$CLIENT_UUID/authz/resource-server/permission" -d '{
  "name": "Delete Document Permission",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["Document"],
  "scopes": ["document:delete"],
  "policies": ["admin-role-policy"]
}' > /dev/null || echo "    (may already exist)"

echo ""
echo "=== Step 7: Create demo users and assign roles ==="

for user in alice bob; do
  echo "  Creating user: $user"
  # Capitalize first letter portably (avoid ${user^}, which needs bash 4+).
  first_name="$(echo "${user:0:1}" | tr '[:lower:]' '[:upper:]')${user:1}"
  kc_api POST "users" -d "{
    \"username\": \"$user\",
    \"enabled\": true,
    \"email\": \"$user@example.com\",
    \"firstName\": \"$first_name\",
    \"lastName\": \"User\",
    \"credentials\": [{\"type\":\"password\",\"value\":\"$user\",\"temporary\":false}]
  }" > /dev/null || echo "    (may already exist)"
done

echo "  Assigning document-admin role to alice"
ALICE_ID=$(kc_api GET "users?username=alice" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
ADMIN_ROLE=$(kc_api GET "roles/document-admin" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)))")
kc_api POST "users/$ALICE_ID/role-mappings/realm" -d "[$ADMIN_ROLE]" > /dev/null || echo "    (may already be assigned)"

echo "  Assigning document-viewer role to bob"
BOB_ID=$(kc_api GET "users?username=bob" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
VIEWER_ROLE=$(kc_api GET "roles/document-viewer" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)))")
kc_api POST "users/$BOB_ID/role-mappings/realm" -d "[$VIEWER_ROLE]" > /dev/null || echo "    (may already be assigned)"

echo ""
echo "=== Done! ==="
echo ""
echo "Verify in the Keycloak admin console:"
echo "  1. Clients -> documents-api -> Authorization tab (Resources, Scopes, Policies, Permissions)"
echo "  2. Realm roles (document-viewer, document-editor, document-admin)"
echo "  3. Users (alice with document-admin, bob with document-viewer)"
echo ""
echo "Test with the Evaluate tool:"
echo "  Clients -> documents-api -> Authorization -> Evaluate"
echo "  User: alice, Roles: document-admin -> all PERMIT"
echo "  User: bob, Roles: document-viewer -> view PERMIT, edit/delete DENY"
echo "  User: student, no roles -> all DENY"

# ---------------------------------------------------------------------------
# Alternative: destructive realm re-import (if you prefer a clean slate)
# ---------------------------------------------------------------------------
# This approach DELETES the api-security realm and lets Keycloak re-import
# it from the updated realm-configmap.yaml. Use only if you have no custom
# changes in the realm that you want to keep.
#
# 1. Update your kse-labs-deployment fork with the latest realm-configmap.yaml:
#      cd kse-labs-deployment
#      git pull origin main  # or merge upstream changes
#
# 2. Delete the existing realm:
#      curl -sk -X DELETE \
#        -H "Authorization: Bearer $(admin_token)" \
#        "$KC_URL/admin/realms/api-security"
#
# 3. Restart Keycloak so it re-imports the realm:
#      kubectl -n keycloak rollout restart deployment/keycloak
#
# 4. Wait for Keycloak to be ready, then verify the realm is back with all
#    the lecture 6 configuration.
