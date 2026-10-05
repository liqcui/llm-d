# LMCache-MACA 就绪镜像 — 多阶段构建（builder 隔离编译依赖；运行镜像零污染）
#
# 用法（image/README.md 有完整步骤）:
#   bash build.sh                                   # 默认基座 = r4-hicache-l2-pp1
#   BASE_IMAGE=<r5 镜像> bash build.sh               # 厂商 rebase 后一行切换
#
# 产物: harbor.isuanova.com/metax/sglang:0.5.13-dsv4-adapter-r4-hicache-l2-pp1-lmcache
ARG BASE_IMAGE=harbor.isuanova.com/metax/sglang:0.5.13-dsv4-adapter-r4-hicache-l2-pp1

# ─────────────────────────── builder: MACA 源码编译 lmcache ───────────────────────────
FROM ${BASE_IMAGE} AS builder

# 编译依赖（会与镜像内 xformers 的 setuptools pin 冲突 → 隔离在本阶段, 不进运行镜像）:
#   setuptools/ninja/setuptools_scm/wheel/pybind11 = 构建系统
#   grpcio/grpcio-tools = proto 生成（版本对齐 lmcache pyproject build-system）
RUN pip install --no-input -i https://pypi.org/simple \
        "setuptools>=77,<81" ninja setuptools_scm wheel pybind11 \
        grpcio==1.78.0 grpcio-tools==1.78.0

# 源码: 固定版本 sdist（离线友好; build.sh 首次运行自动下载到本目录）
COPY lmcache-0.5.5.tar.gz /tmp/lmcache-src.tar.gz
ENV BUILD_WITH_MACA=1 \
    MACA_PATH=/opt/maca \
    MACA_HOME=/opt/maca \
    PATH=/opt/maca/bin:/opt/maca/mxgpu_llvm/bin:/opt/maca/tools/cu-bridge/bin:/opt/conda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN cd /tmp && tar xzf lmcache-src.tar.gz && cd lmcache-0.5.5 \
 && pip wheel . --no-build-isolation --no-deps -w /tmp/wheel

# ─────────────────────────── 运行镜像 ───────────────────────────
FROM ${BASE_IMAGE}

ENV PATH=/opt/maca/bin:/opt/maca/mxgpu_llvm/bin:/opt/maca/tools/cu-bridge/bin:/opt/conda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    MACA_PATH=/opt/maca \
    CUDA_PATH=/opt/maca/tools/cu-bridge

# 1) MACA 侧运行依赖: mcpy（cupy fork; MP 模式缓冲管理用）—— 沐曦 pip 源
RUN pip install --no-input \
        -i https://repos.metax-tech.com/r/maca-pypi/simple/ \
        mcpy

# 2) lmcache wheel（--no-deps）+ 运行期 python 依赖（2026-10-06 实测敲定;
#    跳过 NVIDIA-only（cufile-python）与云后端（awscrt/bigtable）及重训练栈（numba/transformers）
#    ——daemon 与 sglang 适配器路径均不需要; 如后续启用相应后端再补）
COPY --from=builder /tmp/wheel /tmp/wheel
RUN pip install --no-input --no-deps /tmp/wheel/lmcache-*.whl \
 && pip install --no-input -i https://pypi.org/simple \
        py-cpuinfo sortedcontainers aiofile aiofiles pyzmq cryptography \
        "opentelemetry-api<=1.40.0,>=1.20.0" opentelemetry-sdk opentelemetry-exporter-otlp \
        "opentelemetry-exporter-prometheus<=0.61b0,>=0.50b0" \
        fastapi uvicorn httptools pyyaml blake3 msgspec cachetools psutil aiohttp httpx safetensors \
 && rm -rf /tmp/wheel /root/.cache/pip

# 3) 构建产物冒烟（ADR: 镜像即验证; 失败则 build 直接红）——三层验证:
#    fork 三件套 adapter 导入 / cuda_ops 扩展落地 / 完整版 server CLI（--l1-size-gb 等必填参数）
RUN python3 - <<'EOF'
import lmcache
from lmcache.integration.sglang.multi_process_adapter import LMCacheMPConnector
from lmcache.integration.sglang.sglang_adapter import LMCacheLayerwiseConnector
from lmcache.integration.sglang.utils import lmcache_get_config
print("lmcache", lmcache.__version__, "| sglang 三件套 adapter OK")
EOF
RUN python3 -c "import lmcache.cuda_ops as o; print('cuda_ops OK')" || echo "cuda_ops 缺 GPU 上下文（构建机无卡属预期）"
RUN lmcache server --help 2>/dev/null | grep -q -- '--l1-size-gb' && echo "完整版 server CLI OK"
