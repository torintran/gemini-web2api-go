#!/usr/bin/env bash
set -euo pipefail

# Mã hoá ADMIN_TOKEN + API_KEY thành SealedSecret (ciphertext an toàn để commit).
# Dùng chung Sealed Secrets controller với repo cloudflared của bạn.
#
# Cách dùng:
#   ./deploy/k3s/scripts/seal-app-secrets.sh
#   ./deploy/k3s/scripts/seal-app-secrets.sh /path/to/app-secrets.env
#
# Nguồn plaintext : deploy/k3s/secrets/app-secrets.env  (gitignored)
# Đích ciphertext : deploy/k3s/overlays/prod/sealed-app-secrets.yaml
#
# Sau khi seal, apply riêng file ciphertext:
#   kubectl apply -f deploy/k3s/overlays/prod/sealed-app-secrets.yaml
# (không nằm trong kustomization để 'kubectl apply -k' vẫn chạy được trước lần seal đầu)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-gemini}"
NAME="${NAME:-gemini-web2api-secrets}"
SRC="${1:-$ROOT/secrets/app-secrets.env}"
OUT="${OUT:-$ROOT/overlays/prod/sealed-app-secrets.yaml}"

command -v kubeseal >/dev/null 2>&1 || { echo "kubeseal không có trong PATH"; exit 1; }
command -v kubectl  >/dev/null 2>&1 || { echo "kubectl không có trong PATH"; exit 1; }
[ -f "$SRC" ] || { echo "Thiếu $SRC — copy từ app-secrets.env.example"; exit 1; }

set -a
# shellcheck disable=SC1090
. "$SRC"
set +a

: "${ADMIN_TOKEN:?ADMIN_TOKEN rỗng}"
: "${API_KEY:?API_KEY rỗng}"

mkdir -p "$(dirname "$OUT")"
umask 077

kubectl create secret generic "$NAME" \
  --namespace "$NS" \
  --from-literal=admin-token="$ADMIN_TOKEN" \
  --from-literal=api-key="$API_KEY" \
  --dry-run=client -o yaml \
| kubeseal \
    --controller-namespace kube-system \
    --controller-name sealed-secrets-controller \
    --format yaml \
> "$OUT"

chmod 644 "$OUT"
echo "Đã ghi $OUT"
echo "Apply: kubectl apply -f $OUT"
