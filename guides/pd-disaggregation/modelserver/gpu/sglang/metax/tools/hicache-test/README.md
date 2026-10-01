# HiCache L2 / Mooncake L3 测试工具

> 用于 MetaX C500 集群 DeepSeek-V4 PD 分离部署的 **HiCache 二级/三级 KV 缓存链路测试**。
> 流程对齐 GPUStack《Mooncake PD / Store 测试与验证报告》(2026-09) §8-13。
> 适用部署: `deepseek-hicache-l3/`（L2+L3 全栈）。

## 文件

| 文件 | 作用 |
|---|---|
| `hicache_test.py` | 主测试: 冷 → L2 命中 → flush → L3 命中判据 |
| `analyze.py` | 结果解析: 时序 + prefill 日志 + master 指标 → 综合判定 |
| `README.md` | 本手册 |

## 1. 前置条件

- **pd-bench-client pod 存在**（`metax/sglang:benchmark` 镜像, 挂 `/workspace/data` 模型目录）:
  测试脚本需在该 pod 内运行（它带模型 tokenizer 与 transformers）。
- **服务就绪**（全栈已部署并 fired up）:
  - router 健康: `curl http://<router-ip>:8001/health` → OK
  - prefill 健康: `curl http://<prefill-ip>:8000/health` → 200
  - decode 健康: `curl http://<decode-ip>:8200/health` → 200
  - mooncake master: `curl http://<master-ip>:8080/metadata` 有响应（50051/8080/9003 LISTEN）
- 端点填写**宿主机 IP**（hostNetwork ⇒ podIP 即节点 IP），不要填 ClusterIP。

## 2. 运行测试

```bash
# 拷入 bench pod（或直接 kubectl cp）
kubectl -n metax-ai-pd cp hicache_test.py pd-bench-client:/tmp/hicache_test.py
kubectl -n metax-ai-pd cp analyze.py        pd-bench-client:/tmp/analyze.py

# 小 prompt 快速验证 (默认 1236 token)
kubectl -n metax-ai-pd exec pd-bench-client -- /opt/conda/bin/python3 /tmp/hicache_test.py \
  --router  http://10.66.3.32:8001 \
  --prefill http://10.66.3.28:8000 \
  --model   /workspace/data/DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8 \
  --json-out /tmp/l3-result.json

# 大 KV L3 验证 (32K prompt, ~982MB 写入 L3; 冷 prefill 需几分钟)
kubectl -n metax-ai-pd exec pd-bench-client -- /opt/conda/bin/python3 /tmp/hicache_test.py \
  --router http://10.66.3.32:8001 --prefill http://10.66.3.28:8000 \
  --model /workspace/data/DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8 \
  --prompt-tokens 32000 --timeout 900 --json-out /tmp/l3-32k.json

# 只测 L2 (跳过 flush/L3 阶段)
... --skip-flush --json-out /tmp/l2-only.json
```

参数:

| 参数 | 默认 | 说明 |
|---|---|---|
| `--router` | 必填 | PD router `http://<ip>:8001` |
| `--prefill` | 必填 | prefill leader `http://<ip>:8000`（flush 用）|
| `--model` | 必填 | 模型路径（bench pod 内 hostPath）|
| `--prompt-tokens` | 1236 | 目标 prompt token 数（1236 / 4000 / 16000 / 32000 / 64000）|
| `--max-tokens` | 32 | 生成 token 数 |
| `--rounds` | 1 | 每阶段重复轮数 |
| `--skip-flush` | 关 | 跳过 flush 阶段 |
| `--timeout` | 300 | 单请求超时（32K 冷 prefill 建议 900）|
| `--json-out` | 无 | 结果 JSON（analyze.py 必需）|

## 3. 结果解析

```bash
# 在 bench pod 内（能 kubectl 即可）:
python3 /tmp/analyze.py \
  --result /tmp/l3-result.json \
  --prefill-pod prefill-hicache-0 \
  --master-pod mooncake-master \
  --namespace metax-ai-pd
```

也可离线解析（把日志落盘后传回）:

```bash
kubectl -n metax-ai-pd logs prefill-hicache-0  --tail=3000 > prefill.log
kubectl -n metax-ai-pd logs mooncake-master    --tail=3000 > master.log
python3 analyze.py --result l3-result.json --prefill-log prefill.log --master-log master.log
```

### 判据表（analyze.py 输出）

| 判定项 | PASS 条件 | 含义 |
|---|---|---|
| ② L2 命中 | `cached_tokens>0` 且 elapsed 显著低于 ① | KV 从 Host DRAM 回 GPU（45x 级）|
| flush | http=200 `Cache flushed` | prefill 本地 L1/L2 已清空（PP 各 stage）|
| prefill 回读 | `matched=0` 且 `loaded=N>0` | 不是本地 radix 直接命中, 是 host/L3 重新加载 |
| L3 写入 | master `BatchPut Item` 或 `Keys` 增长 | KV 真实写入 Mooncake Store |
| L3 查询 | master `Get/ExistKey` 增长 | L3 被查询/被读取 |
| ③ L3 命中 | **flush 后** `cached_tokens>0` | L1/L2 已清仍命中 ⇒ 必为 L3 回读 |

### 输出示例解读

```
[请求①冷] http=200 elapsed=57.95s prompt=1236 completion=32 cached=None   ← 冷基线, 无缓存
[请求②L2] http=200 elapsed=1.49s  prompt=1236 completion=32 cached=1236   ← L2 命中 (39x)
[flush]   http=200 elapsed=0.74s  body=Cache flushed.                      ← L1/L2 已清
[请求③L3] http=200 elapsed=2.10s  prompt=1236 completion=32 cached=1236   ← L3 命中!
```

prefill 日志辅证（`#cached-token: 1236` + prefetch 行）:

```
Prefill batch, #new-seq: 1, #new-token: 256, #cached-token: 1236, ...
HiCache prefetch success ... completed_local=1236 completed_synced=1236 matched=0 loaded=1236
```

master 辅证（`Storage`/`Keys`/`BatchPut`/`BatchGet` 增长, 池 32GiB+4GiB=36GiB）:

```
Master Metrics: Storage: 982.61 MB / 36.00 GB | Keys: 6008 | Batch Put: Item=6000/6000 ...
```

## 4. 故障取证（③ 失败时）

若请求③ 非 200（L3 路径崩溃）, 抓齐以下证据再回退:

1. **结果 JSON**（`--json-out`）: 请求时序与错误体
2. **prefill 引擎日志**: `Scheduler hit an exception` 完整 Python 栈
   ```bash
   kubectl -n metax-ai-pd logs <prefill-pod> --tail=2000 | grep -B5 -A40 "hit an exception"
   ```
3. **MXC/MCR 内核日志**（宿主机）: `dmesg | grep -iE "MXC|MCR|Xnack|memory violation"`
4. **master 指标**: `Storage/Keys/BatchPut/BatchGet` 是否增长（区分"写入前崩"vs"写入后崩"）
5. 各 rank 落盘日志: 节点 `/var/log/sglang-hicache/prefill-rank*.log`（pod 重建后仍保留）

已知问题对照（详见 `metax/TROUBLESHOOTING-2026-09-26.md`）:

| 现象 | 已知根因 |
|---|---|
| `transfer_kernel_impl` Xnack(0x8) @ write_backup | MACA 用户态 transfer kernel 竞态（L3 专属, L2 无）|
| `Decode handshake failed / Aborted by AbortReq` + `Scheduler hit an exception` | L3 prefetch 后 PP 组内 p2p 断开（2026-09-27 新观测, 待定位）|

## 5. 与 GPUStack 报告的对应关系

| 本工具阶段 | 报告章节 | 报告结论 |
|---|---|---|
| ①冷 | §8 | 32K cold prefill 基线 |
| ②L2 | §6/§12 | L2 hit, `completed_local=32000` |
| flush | §10 | `PP0~7 Cache flushed successfully` |
| ③L3 | §11-13 | `matched=0 loaded=32000`, `#cached-token=32000` |
| master 指标 | §9/§11/§16.3 | BatchPut 6000 items / Get 3024 / 池 32→36GiB |
