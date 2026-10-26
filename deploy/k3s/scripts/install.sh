#!/usr/bin/env bash
# Cài gemini-web2api lên k3s một lần: secret, manifest, chờ pod Ready.
#
# Trên node k3s (hoặc máy đã có KUBECONFIG trỏ vào cluster):
#   bash deploy/k3s/scripts/install.sh
#
# Chạy lại an toàn: secret đã có thì giữ nguyên, không xoay key.
# Muốn tạo key mới: xoá secret rồi chạy lại
#   kubectl -n gemini delete secret gemini-web2api-secrets
#
# Biến có thể ghi đè:
#   KUBECTL          lệnh kubectl (mặc định tự tìm kubectl hoặc k3s kubectl)
#   NS               namespace
#   ENV_FILE         file plaintext gitignored, để lấy lại key
#   ROLLOUT_TIMEOUT  thời gian chờ pod Ready

set -euo pipefail

NS="${NS:-gemini}"
SECRET_NAME="${SECRET_NAME:-gemini-web2api-secrets}"
DEPLOY_NAME="${DEPLOY_NAME:-gemini-web2api}"
STORAGE_CLASS="${STORAGE_CLASS:-local-path}"
SERVICE_PORT="${SERVICE_PORT:-8083}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
ADMIN_TOKEN_RAND_BYTES="${ADMIN_TOKEN_RAND_BYTES:-32}"
API_KEY_RAND_BYTES="${API_KEY_RAND_BYTES:-24}"
API_KEY_PREFIX="${API_KEY_PREFIX:-sk-gemini-}"
SECRET_KEY_ADMIN="admin-token"
SECRET_KEY_API="api-key"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="$ROOT/overlays/prod"
ENV_FILE="${ENV_FILE:-$ROOT/secrets/app-secrets.env}"

log() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

is_placeholder() {
  local value="$1"
  [[ -z "$value" || "$value" == *REPLACE_WITH* || "$value" == *" "* ]]
}

read_env_value() {
  local key="$1" file="$2" line value
  line="$(grep -E "^${key}=" "$file" | tail -n 1 || true)"
  value="${line#*=}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

pick_kubectl() {
  if [[ -n "${KUBECTL:-}" ]]; then
    # shellcheck disable=SC2206
    KUBECTL_CMD=($KUBECTL)
    return
  fi
  if command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
    KUBECTL_CMD=(kubectl)
    return
  fi
  if command -v k3s >/dev/null 2>&1 && k3s kubectl get nodes >/dev/null 2>&1; then
    KUBECTL_CMD=(k3s kubectl)
    return
  fi
  if command -v k3s >/dev/null 2>&1 && sudo -n k3s kubectl get nodes >/dev/null 2>&1; then
    KUBECTL_CMD=(sudo -n k3s kubectl)
    return
  fi
  die "Không nối được cluster. Chạy trên node k3s, hoặc export KUBECONFIG / KUBECTL."
}

k() { "${KUBECTL_CMD[@]}" "$@"; }

require_tools() {
  command -v openssl >/dev/null 2>&1 || die "openssl không có trong PATH"
  command -v grep >/dev/null 2>&1 || die "grep không có trong PATH"
  [[ -d "$OVERLAY" ]] || die "Thiếu overlay: $OVERLAY"
}

require_storage_class() {
  k get storageclass "$STORAGE_CLASS" >/dev/null 2>&1 \
    || die "Thiếu StorageClass ${STORAGE_CLASS}. k3s mặc định có local-path; kiểm tra: kubectl get storageclass"
}

load_or_create_env() {
  local admin="" api=""
  if [[ -f "$ENV_FILE" ]]; then
    admin="$(read_env_value ADMIN_TOKEN "$ENV_FILE")"
    api="$(read_env_value API_KEY "$ENV_FILE")"
  fi
  if is_placeholder "$admin" || is_placeholder "$api"; then
    admin="$(openssl rand -hex "$ADMIN_TOKEN_RAND_BYTES")"
    api="${API_KEY_PREFIX}$(openssl rand -hex "$API_KEY_RAND_BYTES")"
    umask 077
    mkdir -p "$(dirname "$ENV_FILE")"
    cat >"$ENV_FILE" <<EOF
ADMIN_TOKEN=${admin}
API_KEY=${api}
EOF
    chmod 600 "$ENV_FILE"
    log "Đã sinh secret và ghi $ENV_FILE"
  else
    log "Dùng key có sẵn trong $ENV_FILE"
  fi
  ADMIN_TOKEN="$admin"
  API_KEY="$api"
}

ensure_secret() {
  k apply -f "$ROOT/base/namespace.yaml"
  if k -n "$NS" get secret "$SECRET_NAME" >/dev/null 2>&1; then
    log "Secret ${NS}/${SECRET_NAME} đã có, giữ nguyên"
    return
  fi
  load_or_create_env
  k -n "$NS" create secret generic "$SECRET_NAME" \
    --from-literal="${SECRET_KEY_ADMIN}=${ADMIN_TOKEN}" \
    --from-literal="${SECRET_KEY_API}=${API_KEY}" \
    --dry-run=client -o yaml \
    | k apply -f -
  log "Đã tạo secret ${NS}/${SECRET_NAME}"
}

apply_manifests() {
  log "Apply $OVERLAY"
  k apply -k "$OVERLAY"
}

wait_ready() {
  if k -n "$NS" rollout status "deploy/${DEPLOY_NAME}" --timeout="$ROLLOUT_TIMEOUT"; then
    return
  fi
  log "Pod chưa Ready. Trạng thái hiện tại:"
  k -n "$NS" get pods,pvc || true
  k -n "$NS" describe "deploy/${DEPLOY_NAME}" || true
  exit 1
}

print_summary() {
  local admin api image
  admin="$(k -n "$NS" get secret "$SECRET_NAME" -o "jsonpath={.data['${SECRET_KEY_ADMIN}']}" | base64 -d)"
  api="$(k -n "$NS" get secret "$SECRET_NAME" -o "jsonpath={.data['${SECRET_KEY_API}']}" | base64 -d)"
  image="$(k -n "$NS" get deploy "$DEPLOY_NAME" -o 'jsonpath={.spec.template.spec.containers[0].image}')"
  k -n "$NS" get pods,pvc
  log ""
  log "Đã cài xong."
  log "Image:    ${image}"
  log "Service:  http://${DEPLOY_NAME}.${NS}.svc.cluster.local:${SERVICE_PORT}"
  log "Admin:    http://${DEPLOY_NAME}.${NS}.svc.cluster.local:${SERVICE_PORT}/admin"
  log "ADMIN_TOKEN=${admin}"
  log "API_KEY=${api}"
  log ""
  log "Tunnel (Zero Trust → Public Hostname → HTTP):"
  log "  ${DEPLOY_NAME}.${NS}.svc.cluster.local:${SERVICE_PORT}"
}

pick_kubectl
require_tools
require_storage_class
ensure_secret
apply_manifests
wait_ready
print_summary
