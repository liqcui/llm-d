# deepseek-hicache-l2-pp1 — HiCache L2 @ 最优解拓扑 (pp1/tp8/dp4)

> 2026-10-05 创建。状态：**镜像资产就绪，部署目录待补**（见下）。

## 目标

让 HiCache L2 部署支持与**非 HiCache 最优解**（`deepseek-v4-rc3-maca/lws/`: prefill
pp1/tp8/dp4）**完全相同的拓扑**，用于严格的同拓扑 A/B 收益对比（消除
`deepseek-v4-rc3-pp4/` 对照时的拓扑差异残留）。

## 背景（拓扑约束）

原 `r4-hicache-l2` 镜像的厂商 `prefill.sh`：
- 非 auto 路径 `tp_size=$((nnodes*num_dies/pp_size))` → pp=1 时 tp=32
- 守卫 `tp 必须整除 o_groups(=8)` → tp=32 触发 `log_fatal`

⇒ 4 节点下只能表达 pp4/tp8/dp1。本目录镜像消除该约束。

## 镜像（image/）

```bash
cd image/
sudo docker build -t harbor.isuanova.com/metax/sglang:0.5.13-dsv4-adapter-r4-hicache-l2-pp1 .
sudo docker push harbor.isuanova.com/metax/sglang:0.5.13-dsv4-adapter-r4-hicache-l2-pp1
```

- 补丁：`prefill.sh` 非 auto 路径的 tp 改为 **`${prefill_tp_size:-原公式}`**。
  `config.sh:52` 已有 `readonly prefill_tp_size="8"`（厂商默认），故补丁后
  pp1 场景 tp=8（8|8 守卫通过），pp4 场景行为不变（公式也是 8）。
- 验证：构建时 `bash -n` 语法检查 + 应用后 `server_args` 应显示
  `tp_size=8 pp_size=1 dp_size=4`（dp>1 的 `--enable-dp-attention` 注入已在
  `deepseek-hicache/lws/base/launcher-configmap.yaml`）。

## 部署目录（待补）

参考 `deepseek-v4-rc3-pp4/` 的**完整副本**模式（kustomize 对 LWS 自定义 CRD
无 OpenAPI schema → containers/env 无法按 name 合并，任何 patch 都整容器替换 →
只能整副本文件）。需拷贝 `deepseek-hicache/lws/{base,shared,kustomization.yaml}`
并修改：
- `base/kustomization.yaml` 或 prefill.yaml 的镜像 tag → `...-l2-pp1`
- `base/prefill.yaml`: `PD_PP_SIZE=1`、`PD_DP_SIZE=4`（MY_PREFILL_PP_AUTO=0 时由
  补丁后的 tp 逻辑 + PD_* 回写推导；或 PP_AUTO=1 走 auto——auto 固定 pp=nnodes=4，
  不适用；**用 PP_AUTO=0 + PD_* 显式值**）
- `base/router.yaml`: 端点占位（部署后按 leader 同步）

## 完整对比协议（部署就绪后）

| label | 部署 | 拓扑 |
|---|---|---|
| `l2off-opt` | `deepseek-v4-rc3-maca/lws/`（生产最优解） | pp1/tp8/dp4 |
| `l2pp1-opt` | 本目录 | pp1/tp8/dp4 |

场景：`mini-l2-{32c,64c,128c}` + `hicache-multiturn-{20x10,80x10}`
（env 文件：新增 `envs/hicache-l2-pp1.json`）
产出：`sglbench compare` ×5 + `sglbench report`。

## 前序数据（pp4 同拓扑对照, 2026-10-05 报告）

见 `~/sglang-benchmark-tools/docs/TEST-REPORT-2026-10-05-hicache-l2.md`：
- 32c TTFT -52.6% ✅ / 64c +14.2% ❌ / 128c 稳定性+吞吐双回归 ❌
- multiturn 20×10 稳态持平（工作集<L1）; 80×10 两侧均触发平台故障（38% partial 等）
