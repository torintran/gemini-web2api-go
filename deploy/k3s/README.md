# gemini-web2api-go trên k3s — dùng lại Cloudflare Tunnel sẵn có

Bố cục này **bám theo repo `cloudflared` bạn đang chạy**:

- Kustomize với `base/` + `overlays/prod/`
- Image pin trong overlay, không dùng `:latest`
- Secret qua **Sealed Secrets** (dùng chung controller bạn đã cài)
- **Không** tạo thêm cloudflared: tunnel hiện tại (namespace `cloudflare`, 2 replica, PDB) đã đủ. Chỉ cần thêm public hostname trỏ vào service của app.

## Kiến trúc

```text
Internet → Cloudflare Edge → cloudflared (ns cloudflare, ×2) → Service DNS
                                        │
                                        ▼
                        http://gemini-web2api.gemini.svc.cluster.local:8083
                                        │
                                        ▼
                        Deployment/gemini-web2api (ns gemini, 1 pod)
                                        └── PVC local-path (SQLite + tiktoken)
```

Không có Ingress, không có Traefik, không mở port 80/443 trên VPS.

Hai cách đưa client vào, chọn một:

- **Nội bộ (mục 3.A):** không tạo public hostname cho Gemini. New API trong cùng cluster gọi `ClusterIP`. Chỉ New API được public. Admin mở qua Tailscale bằng `port-forward`.
- **Public (mục 3.B):** thêm hostname trên tunnel hiện có, trỏ thẳng service `:8083`.

## Bố cục repo

```text
deploy/k3s/
├── base/                      # namespace, pvc, deployment, service, networkpolicy
│   └── kustomization.yaml
├── overlays/prod/
│   ├── kustomization.yaml     # pin image
│   └── sealed-app-secrets.yaml # do script sinh ra, commit được
├── scripts/seal-app-secrets.sh
├── app-secrets.env.example
└── .gitignore
```

Đường apply production:

```bash
kubectl apply -k deploy/k3s/overlays/prod
```

## Build & push image của bạn (làm một lần)

Repo này đã có sẵn `.github/workflows/docker.yml`: push lên `main` hoặc tag `v*` là GitHub Actions build multi-arch (amd64 + arm64) và đẩy lên GHCR của bạn. Không cần Docker chạy trên máy.

Kết quả mong đợi:

```text
ghcr.io/torintran/gemini-web2api-go:v4.26.0   # từ git tag v*
ghcr.io/torintran/gemini-web2api-go:main      # từ nhánh main
ghcr.io/torintran/gemini-web2api-go:latest    # nhánh mặc định
```

### Bước 1 — bật Actions cho fork

Repo `torintran/gemini-web2api-go` hiện là **fork** và **chưa từng chạy workflow nào**. Fork mặc định tắt Actions.

GitHub → repo → tab **Actions** → bấm **I understand my workflows, go ahead and enable them**.

### Bước 2 — trigger build

Cách gọn nhất là tạo tag để có image bất biến:

```bash
git tag v4.26.0
git push origin v4.26.0
```

Hoặc bấm **Actions → Docker → Run workflow** trên nhánh `main` (ra tag `main` + `latest`).

Theo dõi ở tab **Actions**. Build xong thì kiểm tra từ máy:

```bash
docker manifest inspect ghcr.io/torintran/gemini-web2api-go:v4.26.0
```

Nếu trả về JSON manifest là image đã có. Nếu `denied` thì hoặc build chưa xong, hoặc package đang private.

### Bước 3 — cho k3s pull được image

Package mới trên GHCR mặc định **private** → pod sẽ `ImagePullBackOff`.

**Cách 1 (khuyến nghị)** — để public: GitHub → **Packages** → `gemini-web2api-go` → **Package settings** → **Change visibility** → **Public**. Image chỉ chứa binary app, không có secret.

**Cách 2** — giữ private, tạo pull secret:

```bash
kubectl -n gemini create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=torintran \
  --docker-password='<PAT có read:packages>'
```

Rồi thêm vào `base/deployment.yaml`, dưới `spec.template.spec`:

```yaml
      imagePullSecrets:
        - name: ghcr-pull
```

### Build local (dự phòng)

Nếu không dùng CI:

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u torintran --password-stdin

docker buildx create --use --name gemini 2>/dev/null || true
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t ghcr.io/torintran/gemini-web2api-go:v4.26.0 \
  --push .
```

PAT cần scope `write:packages` + `read:packages`.

> Mỗi lần build lại nên dùng **tag mới** (ví dụ `v4.26.0-2`), vì `imagePullPolicy: IfNotPresent` sẽ không kéo lại khi tag không đổi.

### Kiểm tra trước khi deploy

```bash
docker manifest inspect ghcr.io/torintran/gemini-web2api-go:v4.26.0 > /dev/null && echo "image OK"
```

## 0. Yêu cầu

- k3s đang chạy, `kubectl` hoạt động.
- **Sealed Secrets controller** đã cài (bạn đã có: `kubectl get pods -n kube-system -l name=sealed-secrets-controller`).
- `kubeseal` trong PATH.
- Tunnel trong Zero Trust đang **Healthy**, đã có ít nhất một hostname chạy được.
- StorageClass `local-path`.

Kiểm tra:

```bash
kubectl get nodes -o wide
kubectl get storageclass
kubectl get pods -n cloudflare
```

## 1. Tạo secret cho app

### Cách A — Sealed Secret (khuyến nghị, giống repo cloudflared)

```bash
cp deploy/k3s/app-secrets.env.example deploy/k3s/secrets/app-secrets.env
```

Sinh giá trị rồi điền vào file:

```bash
openssl rand -hex 32                          # ADMIN_TOKEN
echo "sk-gemini-$(openssl rand -hex 24)"      # API_KEY
```

Seal:

```bash
chmod +x deploy/k3s/scripts/seal-app-secrets.sh
./deploy/k3s/scripts/seal-app-secrets.sh
```

Script ghi ra `deploy/k3s/overlays/prod/sealed-app-secrets.yaml` — ciphertext, commit được. File plaintext nằm trong `deploy/k3s/secrets/` (đã gitignore).

> File sealed **không** nằm trong `kustomization.yaml` để `apply -k` vẫn chạy được trước lần seal đầu tiên. Apply riêng nó.

### Cách B — kubectl create secret (nhanh, không commit)

```bash
kubectl create namespace gemini

kubectl -n gemini create secret generic gemini-web2api-secrets \
  --from-literal=admin-token="$(openssl rand -hex 32)" \
  --from-literal=api-key="sk-gemini-$(openssl rand -hex 24)"
```

Cách này secret chỉ nằm trong cluster, mất cluster là mất key (vẫn lấy lại được từ `kubectl get secret` nếu còn).

### Lấy lại key

Hai giá trị khác nhau. Ô đăng nhập admin nhận `admin-token`. Client và kênh New API nhận `api-key` (`sk-gemini-...`).

```bash
kubectl -n gemini get secret gemini-web2api-secrets \
  -o jsonpath='{.data.admin-token}' | base64 -d; echo

kubectl -n gemini get secret gemini-web2api-secrets \
  -o jsonpath='{.data.api-key}' | base64 -d; echo
```

`install.sh` cũng ghi cả hai vào `deploy/k3s/secrets/app-secrets.env` (`ADMIN_TOKEN`, `API_KEY`). File này đã gitignore.

## 2. Deploy

```bash
kubectl apply -f deploy/k3s/overlays/prod/sealed-app-secrets.yaml   # nếu dùng cách A
kubectl apply -k deploy/k3s/overlays/prod
```

Theo dõi:

```bash
kubectl -n gemini get pods,pvc
kubectl -n gemini rollout status deploy/gemini-web2api --timeout=180s
kubectl -n gemini logs deploy/gemini-web2api --tail=100
```

Kỳ vọng: pod `1/1 Running`, PVC `Bound`.

Lần boot đầu, app tải `cl100k_base` (~3MB) vào `/data/tiktoken`. Nếu egress 443 bị chặn, log sẽ báo `[tokenizer] init failed` và app vẫn chạy với ước lượng chars/4.

## 3. Đưa traffic tới app

Service là `ClusterIP`. Cổng 8083 chỉ có trong cluster (`gemini-web2api.gemini.svc.cluster.local`). Pod nghe 8083 trong network namespace của nó. Trên host, kể cả IP Tailscale, không có process nào lắng `8083`. `ss -lntp | grep 8083` trên node không ra dòng nào là đúng.

NetworkPolicy của app chỉ siết **egress**. Pod khác trong cluster (New API) gọi được service mà không cần sửa policy.

### 3.A. Không public Gemini — New API trong cluster

Dùng khi client đi qua New API (hoặc One API) và Gemini không có hostname riêng.

1. Cài New API **trong cùng k3s**. DNS `*.svc.cluster.local` chỉ phân giải được trong cluster. New API đặt ngoài VPS thì không tới Service này.
2. Public hostname trên tunnel trỏ vào Service của New API (cổng mặc định `3000`), không trỏ vào `:8083`.
3. Trong New API: Kênh → thêm kênh, loại OpenAI.

| Field | Giá trị |
|---|---|
| Base URL | `http://gemini-web2api.gemini.svc.cluster.local:8083` |
| Key | `api-key` trong secret (`sk-gemini-...`) |
| Models | `gemini-3.6-flash` (đúng tên upstream) |

Không ghi `/v1` ở cuối Base URL. New API tự nối `/v1/chat/completions`. Thêm `/v1` thành `/v1/v1/...` và test kênh fail.

Client đang gửi tên OpenAI thì điền model mapping, ví dụ `{"gpt-4o": "gemini-3.6-flash"}`. Thêm ChatGPT sau này là thêm một kênh nữa. Client vẫn một base URL và một token của New API.

Cookie không nhập trên New API. New API không proxy `/admin`. Làm mục 6, rồi bấm test kênh.

### 3.B. Public hostname trên tunnel hiện có

Zero Trust → **Networks** → **Tunnels** → tunnel của bạn → **Public Hostname** → **Add a public hostname**:

| Field | Value |
|---|---|
| Subdomain | `gemini` (tuỳ bạn) |
| Domain | domain của bạn |
| Path | để trống |
| Type | `HTTP` |
| URL | `gemini-web2api.gemini.svc.cluster.local:8083` |

Đúng quy ước bạn đang dùng: `http://<service>.<namespace>.svc.cluster.local:<port>`.

Vài điểm cần biết:

- Hostname được quản lý **remote** trong dashboard, không cần sửa manifest, không cần restart cloudflared.
- Cloudflared resolve DNS qua CoreDNS nên dùng được tên `.svc.cluster.local`.
- **Quyết định: dùng chung tunnel** với n8n/grafana. Một token, một chỗ cấu hình hostname, không thêm secret tunnel nào cho app này.
  - Hệ quả: xoay token hoặc tunnel down thì mọi hostname cùng ảnh hưởng.
  - Bù lại: xoay token **không** cần chạm vào app — không có gì trong `deploy/k3s` phụ thuộc token tunnel.
- (Không chọn) Tunnel riêng: nếu sau này cần tách blast radius, tạo tunnel mới trong Zero Trust rồi dùng lại repo `cloudflared` với namespace `cloudflare-gemini` — đừng copy manifest cloudflared sang repo này.
- Nếu sau này bạn bật default-deny ingress cho namespace `gemini`, phải cho phép ingress từ namespace `cloudflare` vào port 8083.

## 4. Cấu hình Cloudflare

Chỉ khi đi đường 3.B (Gemini có public hostname). Đường 3.A bỏ cả mục này. Admin không ra internet. Rate limit và cache áp cho hostname của New API nếu hostname đó đi qua Cloudflare.

### 4.1 Access cho /admin (bắt buộc ở đường 3.B)

Admin của app mặc định **không có mật khẩu** nếu `ADMIN_TOKEN` rỗng. Ở đây đã set qua Secret, nhưng vẫn nên có lớp Access.

1. Zero Trust → **Access** → **Applications** → **Add an application** → **Self-hosted**.
2. Domain: `gemini.example.com`, Path: `admin`.
3. Policy: `Allow` + `Emails` → email của bạn.
4. Session duration: 24h.

Nếu tách hostname admin riêng: bảo vệ toàn bộ hostname đó, và thêm WAF rule chặn `/admin` trên hostname API.

### 4.2 WAF rate limit

Security → **WAF** → **Rate limiting rules**:

- Expression: `(http.host eq "gemini.example.com" and starts_with(http.request.uri.path, "/v1/"))`
- Rate: 60 req / 1 phút / IP
- Action: Block, 1 phút

Đây chỉ là lớp ngoài. App đã giới hạn theo **exit IP** (mặc định 5 concurrent / 30 RPM / 80 RPH).

### 4.3 Cache, bot, TLS

- Cache Rule: **Bypass** cho `gemini.example.com/*`.
- **Bot Fight Mode**: tắt cho hostname này (tránh challenge SDK).
- **Under Attack Mode**: tắt.
- SSL/TLS: `Full` (origin là HTTP trong cluster), bật Always Use HTTPS, Minimum TLS 1.2.

## 5. Test

Đường 3.B, gọi thẳng hostname Gemini. Đường 3.A thì bấm test kênh trong New API sau khi cookie đã **正常** (mục 6). Request dưới đây dùng `api-key`, không dùng `admin-token`.

```bash
curl -fsS https://gemini.example.com/

export GEMINI_API_KEY="$(kubectl -n gemini get secret gemini-web2api-secrets -o jsonpath='{.data.api-key}' | base64 -d)"

curl -fsS https://gemini.example.com/v1/models \
  -H "Authorization: Bearer $GEMINI_API_KEY" | jq .
```

Streaming:

```bash
curl -N https://gemini.example.com/v1/chat/completions \
  -H "Authorization: Bearer $GEMINI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemini-3.6-flash",
    "stream": true,
    "messages": [{"role": "user", "content": "Viết logline 3 câu cho phim ngắn về người giữ đèn biển."}]
  }'
```

Thấy `data: {...}` ra từng đoạn là ổn.

> Request non-stream mà quá ~100s không có byte đầu → Cloudflare trả **524**. Với chat/kịch bản luôn dùng `stream: true`.

## 6. Cookie Google + cấu hình cho script

Chưa có cookie thì `/v1/models` vẫn trả lời, nhưng chat báo model không dùng được vì thiếu tài khoản Google. Dùng tài khoản Google **phụ**.

### 6.1. Mở admin

**Đường 3.A (không public).** Trên node, buộc `port-forward` vào IP Tailscale của chính node đó (ví dụ `100.x.y.z`). Lệnh không có `--address` chỉ bind `127.0.0.1` của node, máy khác trên tailnet vẫn không vào được.

```bash
kubectl -n gemini port-forward --address 100.x.y.z svc/gemini-web2api 8083:8083
```

Giữ cửa sổ này mở. Trên máy bạn: `http://100.x.y.z:8083/admin`. Tắt lệnh là cổng đóng.

**Đường 3.B (đã public).** Mở `https://gemini.example.com/admin` sau khi Access (mục 4.1) cho qua.

Ô token nhận `admin-token`, không nhận `sk-gemini-...`. Lấy lại bằng lệnh ở mục 1.

### 6.2. Xuất cookie bằng Firefox

Dùng Firefox. Chrome gắn phiên với máy (Device Bound Session Credentials). Cookie xuất từ Chrome thường chết sau vài chục phút đến vài giờ, và `__Secure-1PSIDTS` không gia hạn được.

1. Firefox đăng nhập [gemini.google.com](https://gemini.google.com).
2. F12 → **Network** → tải lại trang → chọn một request tới `gemini.google.com`.
3. **Headers** → **Request Headers** → copy nguyên giá trị sau `Cookie:`.

Đó là một dòng `SID=...; HSID=...; SSID=...; APISID=...; SAPISID=...; __Secure-1PSID=...; __Secure-1PSIDTS=...`. Phải còn `SAPISID` và `__Secure-1PSID`. `document.cookie` trong Console bỏ qua cookie HttpOnly, nên thiếu đúng các mục này.

### 6.3. Import trên panel

1. Thanh bên → **Cookie 池** → **+ 导入 Cookie**.
2. Giữ tab **整串粘贴（推荐）**. Ô **标签** ghi email cho dễ nhận, có thể để trống.
3. Dán nguyên dòng cookie. Bấm **导入**. Thiếu `SAPISID` thì panel từ chối.
4. Dòng mới ở trạng thái **待检测**. Bấm **检测**.

`✓` và trạng thái **正常** là đăng nhập còn sống. `✗` hoặc **疑似失效** thì xuất lại từ Firefox và import lại. Panel không gửi ngược cookie đầy đủ về trình duyệt. Danh sách chỉ hiện số cookie, vài mục chính, và 4 ký tự cuối của `SAPISID`.

Runtime config gợi ý cho kịch bản:

| Cấu hình | Giá trị | Lý do |
|---|---|---|
| `default_model` | `gemini-3.6-flash` | nhanh, đủ tốt |
| `multi_turn` | `true` | giữ history phía Gemini |
| `request_timeout_sec` | `180` | kịch bản dài |
| `anon_first` | `false` | ưu tiên account đã có cookie |
| `strict_model` | `true` nếu account trả phí | tránh bị âm thầm downgrade |
| `retention_days` | `30` | chỉ log metadata |

Giới hạn thật:

- Một IP exit chịu ~80–180 request trước khi Google chặn tạm (~2 giờ). Một người dùng thì 80 RPH là rất thoải mái.
- Prompt vượt ~130KB sẽ bị wall → chia cảnh hoặc dùng `multi_turn`.
- `temperature`, `top_p`, `max_tokens` bị bỏ qua.
- Qua Tunnel, egress IP vẫn là IP VPS — Cloudflare không đổi IP này.

## 7. Client

```python
from openai import OpenAI

client = OpenAI(base_url="https://gemini.example.com/v1", api_key="sk-gemini-...")

resp = client.chat.completions.create(
    model="gemini-3.6-flash",
    messages=[
        {"role": "system", "content": "Bạn là biên kịch phim ngắn."},
        {"role": "user", "content": "Viết outline 5 cảnh cho phim 10 phút về người giữ đèn biển."},
    ],
    stream=True,
)
for chunk in resp:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
```

Với LobeChat/Open WebUI/Chatbox: provider `OpenAI Compatible`, base URL `https://gemini.example.com/v1`, model `gemini-3.6-flash`.

Đường 3.A thì client không gọi Gemini. Base URL là `https://<hostname-new-api>/v1`, API key là token tạo trong New API. Key `sk-gemini-...` chỉ nằm trong cấu hình kênh.

Client hardcode `gpt-4o`: project không map tên OpenAI. Đổi model trong client, hoặc dùng model mapping của New API (mục 3.A).

## 8. Vận hành

```bash
# Log
kubectl -n gemini logs -f deploy/gemini-web2api
kubectl -n cloudflare logs -l app.kubernetes.io/name=cloudflared --tail=50

# Restart
kubectl -n gemini rollout restart deploy/gemini-web2api
```

### Nâng cấp image

Sửa `overlays/prod/kustomization.yaml`:

```yaml
images:
  - name: ghcr.io/torintran/gemini-web2api-go
    newTag: v4.26.0   # đổi tag ở đây
```

Rồi:

```bash
kubectl apply -k deploy/k3s/overlays/prod
kubectl -n gemini rollout status deploy/gemini-web2api
```

### Backup

`local-path` trên single-node là hostPath, nên backup trực tiếp từ host:

```bash
PV=$(kubectl -n gemini get pvc gemini-web2api-data -o jsonpath='{.spec.volumeName}')
HOSTPATH=$(kubectl get pv "$PV" -o jsonpath='{.spec.hostPath.path}')
sudo tar czf /root/gemini-$(date +%F-%H%M).tgz -C "$HOSTPATH" .
```

Giữ luôn `deploy/k3s/secrets/app-secrets.env` ở nơi an toàn (hoặc chỉ cần secret còn trong cluster).

Restore:

```bash
kubectl -n gemini scale deploy/gemini-web2api --replicas=0
# giải nén vào đúng HOSTPATH
kubectl -n gemini scale deploy/gemini-web2api --replicas=1
```

### Xoá

```bash
kubectl delete -k deploy/k3s/overlays/prod
kubectl delete namespace gemini
```

Xoá namespace là xoá PVC. Backup trước.

## 9. Troubleshooting

| Triệu chứng | Nguyên nhân | Xử lý |
|---|---|---|
| Pod `Init:CrashLoopBackOff` | Init container không chown được volume | `kubectl -n gemini logs pod/... -c fix-data-permissions` |
| `unable to open database file (14)` | Volume thuộc root, app chạy uid 65532 | Init container phải chown; kiểm tra hostPath |
| `CreateContainerConfigError` | Thiếu Secret `gemini-web2api-secrets` | Apply sealed secret; kiểm tra `kubectl -n gemini get secret` |
| Tailscale IP `:8083` từ chối kết nối | Service là `ClusterIP`, host không lắng 8083 | `port-forward --address <ip-tailscale>` (mục 6.1). `ss -lntp \| grep 8083` trống là đúng |
| Admin báo token sai | Đang dán `api-key` (`sk-gemini-...`) | Dán `admin-token` (mục 1) |
| Import cookie báo thiếu `SAPISID` | Copy từ `document.cookie` hoặc copy thiếu | Lấy header `Cookie` của request thật trong Firefox (mục 6.2) |
| Kênh New API `/v1/v1/...` | Base URL đã có hậu tố `/v1` | Base URL dừng ở `:8083` (mục 3.A) |
| New API không resolve được service | New API không nằm trong cluster | Cài New API vào cùng k3s |
| Secret không xuất hiện sau khi apply SealedSecret | Seal bằng key của cluster khác | Seal lại: `kubeseal --fetch-cert` từ cluster này |
| Cloudflare 502 | cloudflared không tới được service | Kiểm tra URL hostname, pod Ready, DNS trong cluster |
| Cloudflare 524 | origin không trả byte đầu trong 100s | Dùng `stream: true` |
| 401 invalid_api_key | Key sai hoặc đang bị lock bởi env | Lấy lại từ Secret |
| 429 | Rate limit theo exit IP | Chờ ~2h, giảm tần suất |
| `model ... unavailable without a Google account cookie` | Chưa có cookie / cookie chết | Thêm cookie trong admin |
| Streaming ra một cục | Cache/compression hoặc client buffer | Bypass cache, test `curl -N` |
| Tunnel unhealthy | Egress UDP 7844 (QUIC) bị chặn | Kiểm tra firewall; log cloudflared ở ns `cloudflare` |
| `tiktoken init failed` | Không tải được cache | Kiểm tra egress 443 + `TIKTOKEN_CACHE_DIR` |
| Pod OOMKilled | Ảnh/video base64 lớn | Tăng limit lên 2Gi hoặc chỉ dùng text |
| PVC Pending | Thiếu StorageClass `local-path` | `kubectl get sc` |

## 10. Checklist

- [ ] `ADMIN_TOKEN` 32 bytes hex, không nằm trong git.
- [ ] `API_KEY` set qua Secret (bị lock, đổi bằng rollout restart).
- [ ] Sealed secret đã commit, plaintext `.env` không commit.
- [ ] Đường 3.A: New API cùng cluster, base URL không có `/v1`, hostname public không trỏ Gemini.
- [ ] Đường 3.B: Access bảo vệ `/admin`, WAF rate limit `/v1/*`, cache bypass, tắt Bot Fight Mode.
- [ ] Cookie pool đã **检测** ra **正常** (Firefox, không phải `document.cookie`).
- [ ] Container nonroot, read-only root FS, drop ALL caps.
- [ ] NetworkPolicy chặn egress private/link-local.
- [ ] Tunnel có 2 connector; không phụ thuộc 1 pod.
- [ ] Tài khoản Google riêng, không phải tài khoản chính.
- [ ] Backup định kỳ.
- [ ] Pin tag image; không dùng `latest`.

## 11. Về rủi ro

- **SSRF**: app tự fetch URL ảnh/video đầu vào. NetworkPolicy chặn `10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `127/8`, `100.64/10`. Nếu cluster dual-stack, thêm `ipBlock: "::/0"` với `except: fc00::/7, fe80::/10, ::1/128`.
- **ToS Google**: tự động hoá Gemini web bằng cookie có thể vi phạm ToS và bị khoá account. Dùng account phụ.
- **ToS Cloudflare**: gói free hạn chế phân phối video/file lớn. Text kịch bản thì ổn.
- **Không bán lại API** này cho người khác.

## 12. Tóm tắt

```bash
# 1. Secret (cách A)
cp deploy/k3s/app-secrets.env.example deploy/k3s/secrets/app-secrets.env
# ... điền ADMIN_TOKEN + API_KEY ...
./deploy/k3s/scripts/seal-app-secrets.sh
kubectl apply -f deploy/k3s/overlays/prod/sealed-app-secrets.yaml

# 2. App
kubectl apply -k deploy/k3s/overlays/prod
kubectl -n gemini get pods,pvc

# 3.A Không public — New API trong cùng cluster, kênh trỏ
#    http://gemini-web2api.gemini.svc.cluster.local:8083
#    (không thêm /v1). Hostname public chỉ trỏ New API.
# 3.B Hoặc public thẳng Gemini:
#    gemini.example.com → http://gemini-web2api.gemini.svc.cluster.local:8083

# 4. Admin: port-forward --address <ip-tailscale> rồi nhập admin-token.
#    Cookie 池 → + 导入 Cookie → dán header Cookie từ Firefox → 检测.

# 5. Test (đường public). Đường 3.A thì test kênh trong New API.
curl -fsS https://gemini.example.com/v1/models -H "Authorization: Bearer $API_KEY"
```
