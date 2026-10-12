# DEPLOY — deepseek-v4-flash-0731-pernode 部署与运维手册

> 本文档 = 该形态**从零到生产**的完整操作规格（配置项/步骤/验证/运维/回滚/故障）。
> 参数取值依据见 `OPTIMIZATION.md`（含 Router 实现 §6）；**全拓扑架构/流程/参数详解见 `ARCHITECTURE.md`**；性能数据索引见 OPTIMIZATION §7。

---

## 1. 组件清单（本目录全部资产）

```
deepseek-v4-flash-0731-pernode/
├── lws/
│   ├── kustomization.yaml        # 部署入口（namespace=metax-ai-pd, resources=[base]）
│   └── base/
│       ├── kustomization.yaml    # 资源清单（9 文件）
│       ├── prefill.yaml          # LWS: replicas=4 / size=1（4 台独立 prefill 引擎）
│       ├── decode.yaml           # LWS: replicas=4 / size=1（4 台独立 decode 引擎, DSPARK）
│       ├── launcher-configmap.yaml  # pd-launcher-dsv4-0731（explicit 直启器, 含 DSPARK 开关）
│       ├── router.yaml           # smg PD 路由器 (端点 4+4, :8001)
│       ├── services.yaml         # headless services
│       ├── serviceAccount.yaml   # + RBAC（launcher 查 K8s API 解析 leader）
│       └── rbac.yaml
├── README.md       # 定位/结构/终版标定摘要
├── OPTIMIZATION.md # 最优参数解（含 Router 层实现 §6）
└── DEPLOY.md       # 本文件
```
镜像：`harbor.isuanova.com/metax/sglang:0.5.14-maca.ai3.8.2.122-dsv4-0731-retractfix`（digest fb9cff47，
= 官方 0.5.14 + retract 崩溃修复；构建资产在 `../deepseek-v4-flash-0731-pp1/image/`）
模型：`/data/DeepSeek-V4-Flash-0731-W8A8`（节点侧；容器内 `/workspace/data/…`，LLMC SmoothQuant W8A8）

## 2. 前置条件

| # | 项 | 检查命令/说明 |
|---|---|---|
| 1 | 节点标签（4+4+1） | prefill ×4: `kubectl label node <n> metax-sglang-pd-prefill-dsv4-0731=true`；decode ×4 / router ×1 同规（本集群: prefill=29/31/36/28, decode=35/34/33/32, router=32） |
| 2 | 与其它形态互斥 | 同名资源（decode/prefill-dsv4-0731 + router）：**同时只能 apply 其一**；GLM/rc3 部署占节点时先拆 |
| 3 | 模型已分发 | 各节点 `/data/DeepSeek-V4-Flash-0731-W8A8` 存在 |
| 4 | 镜像已推 | digest fb9cff47 在 harbor；节点可拉 |
| 5 | LWS CRD | `kubectl get crd leaderworkersets...` |
| 6 | 端口 | hostNetwork 每节点 8000/8200/5600/5000/8998/8001 未被占用 |

## 3. 部署步骤（step-by-step）

```bash
# ⓪ IP 脱敏约定: 仓库内全部为 {{占位符}}; 真实 IP 通过站点配置在部署时注入
cp deepseek-v4-flash-0731-pernode/site-config.env.example \
   deepseek-v4-flash-0731-pernode/site-config.env      # ← 填写真实节点 IP（本集群: prefill 29/31/36/28, decode 35/34/33/32; 配置文件不入库）
# ① 渲染（读取 site-config.env → _rendered/lws/）
python3 ../tools/render_site.py deepseek-v4-flash-0731-pernode
python3 ../tools/render_site.py deepseek-v4-flash-0731-pernode --check   # 可选: 校验无未解析占位符
# ② 部署（经渲染产物）
kubectl apply -k deepseek-v4-flash-0731-pernode/_rendered/lws/
# ③ 等待 8 台引擎就绪（每台 boot ~5min；8 台并行）
kubectl -n metax-ai-pd get pods -l llm-app --no-headers | grep dsv4-0731   # 期望 8×(2/2 或 1/1)
# ④ E2E 验收
curl <router-node>:8001/v1/chat/completions -d '{"model":"DeepSeek-V4-Flash",...}'
# ⑤ 终版参数核验（每个 pod env 应含）：decode: MAX_RUNNING=48, CUDA_GRAPH=64, DSPARK=1
kubectl -n metax-ai-pd get lws decode-dsv4-0731 -o jsonpath='{...env[*]...}'
```

### 部署后验收基线（实测对标，`dsv4-0731-pernode-final-*`）
| 项 | 期望值 |
|---|---|
| 单流 4K | TTFT ~0.8s（热态）/ TPOT 5.5ms |
| rate2（默认操作点） | TTFT ≈1.1s / TPOT ≈16ms |
| conc160 @r5 | TTFT ≤2.5s / 300/300 零失败 |
| 8 引擎分配 | 4 台 prefill 负载差 <15% |

## 4. 运行操作（日常参数变更）

| 操作 | 方法 | 生效方式 |
|---|---|---|
| DSPARK 开/关（A/B） | decode env `PD_ENABLE_DSPARK=0/1` | LWS 自动滚动（~8min） |
| cap 调参 | decode env `PD_MAX_RUNNING_REQUESTS`。⚠ **必须 < `PD_CUDA_GRAPH_MAX_BS`**（见 §5.1）| 滚动 |
| graph-bs | 跟随 cap 规则：graph-bs > cap（终版 64>48） | 滚动 |
| L2（多轮场景） | prefill env `MY_ENABLE_HICACHE=1`（组合标定见 L2 报告） | 滚动 |
| 扩节点 | router.yaml 端点列表加项 + `kubectl apply -f router.yaml` 后 **scale 0→1 重启 router** | 重启 router |
| 日志 | 节点 `/var/log/sglang-dsv4-0731/{prefill,decode}-rank*.log`（跨代际追加）；`kubectl logs <pod> -c modelserver`（注意轮转截断） | — |
| 监控 | router :29000/metrics；引擎 --enable-metrics（launcher 解锁） | — |

## 5. 故障处置

### 5.1 引擎 boot 循环（4 分钟周期重建）
- **判据**：`RecreateGroup` 事件反复 + rank 日志 `TypeError: 'NoneType' object is not iterable`
  @ `dspark_worker_v2.py:496`。
- **根因**：`--cuda-graph-max-bs` 给定即清空 bs 列表，仅当 `adjusted≠requested` 重建；
  dp1 下 `adjusted=min(requested, max_running[≡requested])` → 永不重建 → DSPARK 崩（OPTIMIZATION §5.1）。
- **修复**：保证 `PD_CUDA_GRAPH_MAX_BS > PD_MAX_RUNNING_REQUESTS`（终版 64>48）。

### 5.2 全站 5xx/503（leader 漂移）
1. 核对落点：`kubectl get pods -o wide | grep dsv4-0731`（rank0 的 IP 是否=router 端点）
2. 同步：`kubectl set env deploy/deepseek-v4-0731-router PD_PREFILL_ENDPOINTS=<新IP>:8000 ...`
3. `scale --replicas=0` → sleep 5 → `--replicas=1`（hostNetwork 端口释放）
4. **注意**：熔断不会自愈，必须重启 router（实测）。

### 5.3 单引擎异常/GPU 崩溃
- 单台失败不扩散（router 绕行）；按需 `mx-smi -y -r -i 0 / -i 4` 热复位该节点后重建该组。
- 平台级崩溃协议（复位+重建）见 skill `sglbench-hicache-testing` §4。

## 6. 回滚 / 互切

```bash
# 切回旧基线（跨节点 tp8/dp4 explicit, cap64）
kubectl apply -k ../deepseek-v4-flash-0731-pp1/lws/      # 同名资源就地滚动
# 切厂商官方脚本 PP4 形态
kubectl apply -k ../deepseek-v4-flash-0731-official-pp4/lws/
# 每次切换后：核 leader IP → 同步 router（§5.2 步骤 2-3）
```
⚠ 滑动方向 = 同名资源互相覆盖；**切换前记录目标形态的 env 差异**（cap/graph-bs/DSPARK）。

## 7. 文档全景索引（0731 PD 家族）

| 文档 | 内容 |
|---|---|
| 本文件 | pernode 部署与运维手册 |
| `pernode/OPTIMIZATION.md` | **最优参数解**（终版）——架构结论/参数总表/分场景操作点/Router 实现/引擎缺陷 |
| `pernode/README.md` | 定位与终版标定摘要 |
| `../deepseek-v4-flash-0731-pp1/`（README+image/） | 旧基线 explicit 部署 + 修复镜像构建资产（retractfix/llm-retractfix Dockerfile） |
| `../deepseek-v4-flash-0731-official-pp4/` | 厂商脚本 PP4 形态（对照特解） |
| sglbench `docs/TEST-REPORT-2026-10-10-0731-comprehensive.md` | 多维度总纲（含 §9 pernode 专节） |
| sglbench `docs/TEST-REPORT-2026-10-12-stable-envelope-0731.md` | 包络与操作点（含 pernode 修订指针） |
| sglbench `docs/TEST-REPORT-2026-10-08-*.md` ×2 | 首轮 battery / HiCache L2 |
| DuckDB `data/bench.duckdb` | 全量测试数据（labels 见 OPTIMIZATION §7） |
