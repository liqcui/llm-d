# 部署检查点 — 2026-08-16（GLM5.2 已上线，压测进行中）

> 集群当前部署：**GLM-5.2-W8A8**（LWS 模式，metax-ai-pd，4 Prefill + 4 Decode + llm-d EPP 网关）
> 2026-08-16 16:00：DeepSeek 资源已按用户指示全部删除，GLM5.1 → GLM5.2 升级部署完成，压测进行中

## 〇、当前状态（2026-08-16）

- **DeepSeek-V4-Flash 已下线**：LWS prefill-dsv4/decode-dsv4、deepseek-v4-router、headless Services、pd-smart-adapter ConfigMap 已全部删除（镜像/模型仍在 harbor 与节点 /data，可随时恢复）
- **GLM5.2 已上线**：`metax/lws/`（LWS 模式）部署，镜像 `harbor.mycompany.com/metax/sglang:glmpd`，模型 `/data/GLM-5.2-W8A8`（8 节点已就位）
  - 升级方式：prefill/decode yaml 新增 env 门控 sed —— `SGLANG_MODEL_PATH` 覆盖 `glm-5.sh` 的 `model_path_specific`；以后换模型只改 env
  - 节点拓扑（沿用 GLM5.1 压测验证过的分配）：prefill = 147/165/154/152（标签 metax-sglang-pd-prefill），decode = 168/166/167/169（标签 metax-sglang-pd-decode）
  - kustomization 模型标签已改 `glm-5.2-w8a8`
  - EPP 已发现 GLM 端点（prefill-0-rank-0 / decode-0-rank-0），冒烟通过（reasoning 正常）
- **压测**：stress pod `sglang-pd-stress-test`（default ns，node 232，`/opt/conda/bin/python3` 有 sglang；GLM5.2 tokenizer 已拷入 `/workspace/data/GLM-5.2-W8A8/`）
  - 方法：`sglang.bench_serving --backend=sglang-oai-chat --base-url=http://10.0.0.232:8081`（EPP 路径，见 pd-stress-test-report.zh.md）
  - GLM5.1 基线（报告 §4.2，5×4096in/512out @c=1）：E2E 21.2s / TTFT 1.11s / TPOT 39.3ms / 24.1 tok/s
  - **GLM5.2 压测完成（2026-08-16 17:00）**：
    - 5×4096/512 @c=1（同 5.1 基线参数）：E2E 18.9s / TTFT 1.01s / TPOT 35.0ms / 27.1 tok/s（**全线提升 9-12%**）
    - 200×4096/2048 @c=32 rate=4（限流未打满，并发均值 28）：输出吞吐 693 tok/s、总吞吐 2080 tok/s、TTFT 中位 1.62s、TPOT 39.5ms、成功率 200/200
    - 20×60000/8192 @c=4（长上下文）：输出吞吐 162 tok/s、TTFT 中位 5.0s（60K prefill ~5s）、TPOT 22.4ms、成功率 20/20
  - **压测踩坑**：bench_serving 随机 token prompt 重分词会膨胀 ~4%（65536→68252），超过服务上限 66746 tokens → 全部 400、客户端重试挂死；64K 输入改用 60000
  - **sglang 网关已修复**：新增 `glm-router` Deployment（232:8001，smg 直调 + §8.4 sed），注册 prefill/decode master；⚠️ LWS 重建后 master 落点会漂移（当前 154/167），漂移后按 yaml 注释更新 IP

## 一、升级到下一个模型版本（最小变更流程）

1. 模型分发到 8 个 GPU 节点 `/data/<MODEL>` + stress pod（232）拷 tokenizer
2. `kubectl set env lws/prefill lws/decode SGLANG_MODEL_PATH=/workspace/data/<MODEL>` → 删 LWS 重建（或直接改 yaml env）
3. `kubectl apply -k guides/pd-disaggregation/modelserver/gpu/sglang/metax/lws/`
4. 冒烟 + bench_serving 对照基线

## 二、升级时可能复现的已知坑（平台级事实，新版本验证时对照）

- **C500：Triton MoE w8a16 路径在 MACA 上数值完全错误（cosine=0）** —— 量化 MoE 优先验证 w8a8 + mctlass fused MoE（cosine≈0.9997）；mctlass w8a16 Linear 路径本身正确
- **C500：`triton count_and_sort_expert_tokens_kernel` 特定形状变体 ATU 越界**（动态分块 profiling 的 128 形状探索触发）→ 规避手段：禁用动态分块
- 部分 fork 的量化 DeepEP low_latency 路径已废弃（assert）→ EP=1 走标准 FusedMoE 可绕过
- fork 默认 `SGLANG_ENABLE_STRICT_MEM_CHECK_DURING_IDLE=True`（idle 池核算微差即杀 scheduler）→ 显式置 false
- decode 服务器不打印 Decode batch 日志时，流量验证用 metrics：`prompt_tokens_total` / `generation_tokens_total` / `num_requests_total`
- `torch.randint(0, E, ...)` 在 Metax torch 上有 bug（check_uniform_bounds NotImplementedError）——测试代码注意绕开
- LWS restartPolicy=RecreateGroupOnPodRestart：任何容器重启 → 整组重建（放大一切崩溃）
- hostNetwork router 滚动更新会因端口占用死锁 → 先删旧 router pod 再等新 pod 调度
- GLM 部署注意：worker pod 的 8000 是残接口（/server_info 404），**仅 rank-0（master）是有效入口**；EPP 按 worker-index=0 发现

## 三、待办

- [ ] GLM5.2 吞吐/长上下文压测收尾（200×4096/2048、65536/8192）
- [ ] （可选）GLM5.2 EPLB profile 重新采集（当前沿用 glm-5 的 eplb.pt，模型升级后建议重跑 EPLB 平衡）
- [ ] （可选）恢复 DeepSeek 部署时:改回 dsv4 yaml 镜像 apply 即可，节点标签/模型均未动
- [ ] incident-2026-08-15 故障报告（MCCL/Gloo 脏连接）跟进沐曦侧根因修复
