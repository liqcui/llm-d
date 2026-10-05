# image/ — LMCache-MACA 可运行镜像

多阶段 Dockerfile：`builder` 阶段用 **MACA 工具链源码编译 LMCache wheel**（隔离编译依赖），
运行阶段只装 wheel + 必备运行依赖（`mcpy` 沐曦源 + lmcache 运行 python 依赖）。

## 构建

```bash
bash build.sh                    # 默认基座 r4-hicache-l2-pp1 → tag …-lmcache
PUSH=1 bash build.sh             # 构建并推送 harbor.isuanova.com/metax/sglang
BASE_IMAGE=<r5 镜像> bash build.sh   # 厂商 rebase 后切换基座（解锁路线 A 的第 1 步）
```

- 产物：`harbor.isuanova.com/metax/sglang:0.5.13-dsv4-adapter-r4-hicache-l2-pp1-lmcache`
  **已构建并推送**（2026-10-06；digest `sha256:46a986399019e71addd7e5badfab93108ff58360cee825d27680d84f2d0026c6`；
  本机 image id `692fabae4b67`，32.9GB；部署时节点可直接拉取）
- 源码：PyPI sdist 固定 **LMCache 0.5.5**（`LMCACHE_VERSION=...` 可换；build.sh 自动下载并随目录缓存）
- ⚠ 本机镜像构建一律用 **docker**（podman 3.4.4 有 OCI↔Docker manifest 转换 bug）。

## MACA 编译配方（已在 2026-10-06 实测编译通过）

| 项 | 值 |
|---|---|
| 触发 | `BUILD_WITH_MACA=1`（LMCache MACA profile 的 env_var；不设会被 nvcc shim 误判成 CUDA profile） |
| 探测 | `torch.utils.cpp_extension.MACA_HOME`（本镜像 = `/opt/maca`，MACA 版 torch 自带） |
| 编译器 | `/opt/maca/tools/cu-bridge/bin/nvcc`（cu-bridge 的 nvcc 兼容包装 → mxgpu_llvm；**不做 hipify**，直接编 `.cu`） |
| 产物 | `lmcache.cuda_ops`（与 CUDA profile **同名**——MACA 向 torch 报 `device_type == "cuda"`，不同名则静默落回纯 Python fallback） |
| 编译证据 | `-DUSE_MACA` 出现在全部编译单元（`lmcache_native` + `csrc/cuda`）；"No available devices" 为无卡环境良性告警 |
| 运行依赖 | `mcpy`（cupy fork，**沐曦源** `https://repos.metax-tech.com/r/maca-pypi/simple/`，PyPI 无）、`triton`（镜像已有 metax 版） |

上游说明：`setup_extensions/build_profiles/maca.py` 注释明确"无上游 CI/wheel，MACA 走自编译"。

## 构建后冒烟（Dockerfile 内置，失败即镜像红）

```bash
# 1) sglang 适配器导入（fork 的 LMCRadixCache 直接 import 这三个模块）
python3 -c "from lmcache.integration.sglang.multi_process_adapter import LMCacheMPConnector; \
            from lmcache.integration.sglang.sglang_adapter import LMCacheLayerwiseConnector; \
            from lmcache.integration.sglang.utils import lmcache_get_config; print('adapter OK')"
# 2) 完整版 server CLI（--l1-size-gb / --eviction-policy 为 0.5.5 必填参数）
lmcache server --help | grep -- --l1-size-gb
# 3) c_ops 扩展（真实节点有卡时）: python3 -c "import lmcache.cuda_ops"
```

## ✅ 实测验证记录（2026-10-06，全链路闭环）

| 步骤 | 结果 | 证据 |
|---|---|---|
| MACA 源码编译 | ✅ | `-DUSE_MACA -DNV_ARCH_A100` 编译全部单元（lmcache_native + csrc/cuda）→ `lmcache-0.5.5-cp312-linux_x86_64.whl` |
| fork 三件套 adapter 导入 | ✅ | `multi_process_adapter/sglang_adapter/utils` 全部导入成功（无卡环境 StubCPUDevice，属预期） |
| daemon 实起 | ✅ | `lmcache server --host 127.0.0.1 --port 5557 --chunk-size 256 --l1-size-gb 1 --eviction-policy LRU --transport zmq` → `ss` 显示 **LISTEN 127.0.0.1:5557**（cpu-only，无需 GPU） |

**运行依赖定稿**（冒烟迭代敲定；跳过 NVIDIA-only `cufile-python`、云后端 `awscrt`/`bigtable`、
重训练栈 `numba`/`transformers`，daemon 与 sglang 适配器路径均不需要）：
`mcpy`(沐曦源) + `py-cpuinfo sortedcontainers aiofile aiofiles pyzmq cryptography
opentelemetry{-api,-sdk,-exporter-otlp,-exporter-prometheus} fastapi uvicorn httptools
pyyaml blake3 msgspec cachetools psutil aiohttp httpx safetensors`。

> ⚠ `lmcache server` 的 `--l1-size-gb` 与 `--eviction-policy` 在 0.5.5 是**必填**（fork README
> 的示例命令仍成立）；DaemonSet 命令已按此对齐（daemon/lmcache-server-daemonset.yaml）。

## 手工实验记录（可复现; 2026-10-06）

容器内手动步骤（`docker run` 基座 → `pip install` 依赖 → `pip wheel .`）：

```bash
export BUILD_WITH_MACA=1 MACA_PATH=/opt/maca MACA_HOME=/opt/maca
export PATH=/opt/maca/bin:/opt/maca/mxgpu_llvm/bin:/opt/maca/tools/cu-bridge/bin:$PATH
pip install "setuptools>=77,<81" ninja setuptools_scm wheel pybind11 grpcio==1.78.0 grpcio-tools==1.78.0
cd lmcache-0.5.5 && pip wheel . --no-build-isolation --no-deps -w /tmp/wheel
```

> 注：`setuptools>=77` 与镜像内 `xformers` 的 `setuptools==69.5.1` pin 冲突——仅在
> builder 阶段存在，运行镜像不受影响（这正是多阶段构建的原因）。运行时若某组件
> 依赖该 pin，回退候选：builder 内建虚拟环境编译（venv --system-site-packages）。

## 已知风险

- **驱动 queue pool**（论坛 vLLM+C500 实测，DP=4 撞 `mxkwCreateQueueBlock timeout`）：
  与镜像无关，是解锁运行时风险；观察点与缓解见 ../README.md §3/§6。
- `mcpy` 版本随沐曦源演进；如与 MACA 用户态不匹配（镜像 3.8.2.6 vs 节点驱动 3.8.1.3），
  以 daemon/引擎冒烟为准。
