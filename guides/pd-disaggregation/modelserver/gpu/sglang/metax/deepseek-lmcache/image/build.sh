#!/usr/bin/env bash
# 构建并推送 LMCache-MACA 镜像（幂等; 厂家 rebase 后用 BASE_IMAGE= 参数一行切换基座）。
#
# 用法:
#   bash build.sh                     # 默认基座 r4-hicache-l2-pp1 → 构建 + 本地 tag
#   BASE_IMAGE=<新镜像> bash build.sh  # 基座切换
#   PUSH=1 bash build.sh              # 构建后推送 harbor
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

BASE_IMAGE="${BASE_IMAGE:-harbor.isuanova.com/metax/sglang:0.5.13-dsv4-adapter-r4-hicache-l2-pp1}"
TAG="${TAG:-${BASE_IMAGE##*:}-lmcache}"
IMAGE="harbor.isuanova.com/metax/sglang:${TAG}"
LMCACHE_VERSION="${LMCACHE_VERSION:-0.5.5}"
SDIST="lmcache-${LMCACHE_VERSION}.tar.gz"

# 1) 预下载 sdist（离线友好; 已存在则跳过）
if [[ ! -f "$SDIST" ]]; then
  echo "[build] 下载 LMCache ${LMCACHE_VERSION} sdist …"
  curl -sL "https://files.pythonhosted.org/packages/source/l/lmcache/${SDIST}" -o "$SDIST" \
    || python3 - "$LMCACHE_VERSION" "$SDIST" <<'EOF'
import json, sys, urllib.request
ver, out = sys.argv[1], sys.argv[2]
data = json.load(urllib.request.urlopen(f"https://pypi.org/pypi/lmcache/{ver}/json"))
url = next(u["url"] for u in data["urls"] if u["packagetype"] == "sdist")
urllib.request.urlretrieve(url, out)
EOF
fi
ls -la "$SDIST"

# 2) 构建（本机镜像构建一律用 docker —— podman 3.4.4 有 OCI↔Docker 转换 bug）
echo "[build] BASE_IMAGE=$BASE_IMAGE"
echo "[build] IMAGE=$IMAGE"
sudo docker build --build-arg "BASE_IMAGE=$BASE_IMAGE" -t "$IMAGE" .

# 3) 可选推送
if [[ "${PUSH:-0}" == "1" ]]; then
  echo "[build] push $IMAGE"
  sudo docker push "$IMAGE"
fi
echo "[build] done: $IMAGE"
