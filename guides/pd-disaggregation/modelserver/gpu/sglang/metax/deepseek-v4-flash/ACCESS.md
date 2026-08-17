# DeepSeek-V4-Flash 接入指南（独立文档）

> 适用部署：`guides/pd-disaggregation/modelserver/gpu/sglang/metax/deepseek-v4-flash/lws/`（4 Prefill + 4 Decode，llm-d EPP 网关）
> 本文档只讲「怎么连、怎么用」，部署与排障见同目录 `lws/README.md`。

---

## 1. 接口一览

**双网关并行**（同一套 P/D 后端，用于性能对比）：

| 网关 | 集群外入口 | 集群内入口 | Metrics |
|------|-----------|-----------|---------|
| **llm-d EPP**（llm-d 规范） | `http://10.0.0.232:8081` | `http://pd-disaggregation-epp.metax-ai-pd.svc:80` | — |
| **sglang 默认网关**（launch_router） | `http://10.0.0.232:8001` | `http://10.0.0.232:8001` | `http://10.0.0.232:29000/metrics` |

| 项 | 值 |
|----|----|
| 协议 | OpenAI 兼容 `/v1/chat/completions`（HTTP/1.1，支持流式） |
| 模型名 | `DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8` |
| 认证 | 无（两个网关均不校验 api_key） |

**网关差异（对比压测关注点）**：

| | llm-d EPP | sglang 默认网关 |
|--|-----------|----------------|
| 组件 | envoy + endpoint-picker(ext_proc) + routing-proxy sidecar | sglang_router.launch_router（Rust） |
| 路由 | EPP 插件链（prefill/decode-filter、prefix-cache-scorer）直接选 P/D | round_robin 轮询 4P+4D worker（可 `--enable-shortest-queue`） |
| 连接方式 | EPP → decode pod 的 sidecar:8000（两段式转发） | router 直连各 P/D（节点 IP 直连，不依赖集群 DNS） |
| 可观测 | EPP 日志/grpc | :29000 Prometheus（smg_worker_health 等） |

拓扑回顾（完整链路）：

```
Client ──→ 10.0.0.232:8081 (EPP envoy) 或 :8001 (sglang router)
              │
              ├─ [EPP 路径] → routing-proxy sidecar (decode pod :8000)
              │                  ├─ ① Prefill: prefill:8000 (TP1/PP8, 算 KV)
              │                  │      └─ mooncake RDMA (mlx5_0)
              │                  └─ ② Decode: 同 pod modelserver:8200 (自回归生成)
              │
              └─ [sglang 路径] → prefill 节点 :8000 (4×) / decode 节点 :8200 (4×)
                                 (bootstrap 8998 + RDMA KV 传输)
```

## 2. 快速验证

> 以下示例统一用 EPP 入口 `:8081`；**压测对比时把端口换成 sglang 网关 `:8001` 即可**，请求体完全一致。

```bash
curl -s -X POST http://10.0.0.232:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8",
    "messages": [{"role": "user", "content": "请只回复 OK"}],
    "max_tokens": 16,
    "temperature": 0
  }'
# 期望: choices[0].message.content == "OK"
```

## 3. 连接方式

### 3.1 curl（集群外直连）

```bash
# 单轮
curl -s -X POST http://10.0.0.232:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8",
    "messages": [{"role": "user", "content": "你好，用一句话介绍上海"}],
    "max_tokens": 64,
    "temperature": 0.7
  }'

# 流式输出
curl -s -N -X POST http://10.0.0.232:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8",
    "messages": [{"role": "user", "content": "写一首五言绝句"}],
    "max_tokens": 128,
    "stream": true
  }'

# 多轮对话
curl -s -X POST http://10.0.0.232:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8",
    "messages": [
      {"role": "user", "content": "1+1=?"},
      {"role": "assistant", "content": "2"},
      {"role": "user", "content": "再乘以 3 呢?"}
    ],
    "max_tokens": 64
  }'

# 开启思考模式 (DeepSeek V4 reasoning)
curl -s -X POST http://10.0.0.232:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8",
    "messages": [{"role": "user", "content": "9.11 和 9.9 哪个大?"}],
    "max_tokens": 512,
    "extra_body": {"chat_template_kwargs": {"enable_thinking": true}}
  }'
```

### 3.2 OpenAI SDK（Python）

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://10.0.0.232:8081/v1",
    api_key="not-needed",          # EPP 不校验
)

# 普通对话
resp = client.chat.completions.create(
    model="DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8",
    messages=[{"role": "user", "content": "你好，用一句话介绍上海"}],
    max_tokens=64,
)
print(resp.choices[0].message.content)

# 流式
stream = client.chat.completions.create(
    model="DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8",
    messages=[{"role": "user", "content": "写一首五言绝句"}],
    max_tokens=128,
    stream=True,
)
for chunk in stream:
    if chunk.choices and chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
```

### 3.3 集群内 / 调试

```bash
# 集群内 Service DNS
curl -X POST http://pd-disaggregation-epp.metax-ai-pd.svc:80/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8","messages":[{"role":"user","content":"hi"}],"max_tokens":16}'

# 任意机器临时调试（本地 8001 → EPP 80）
kubectl -n metax-ai-pd port-forward svc/pd-disaggregation-epp 8001:80
curl http://127.0.0.1:8001/v1/chat/completions ...
```

### 3.4 模型列表 / 健康

```bash
curl http://10.0.0.232:8081/v1/models
# 返回 id 为模型完整路径 "/workspace/data/DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8";
# 请求里用短名 DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8 即可 (EPP 不按模型名路由, 直接进 PD pool)
```

## 4. 常用参数

| 参数 | 建议 | 说明 |
|------|------|------|
| `model` | `DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8` | 短名即可 |
| `max_tokens` | ≤ 8192 起步 | decode 侧 max_running_requests=320（8 DP），超长输出请逐步加压 |
| `temperature` | 0 / 0.7 | 复现性测试用 0 |
| `stream` | true/false | 均支持 |
| `chat_template_kwargs.enable_thinking` | true 开启思考 | 思考 token 计入 max_tokens，需相应加大 |

## 5. 压测注意事项

- **务必关闭 KV cache**：`--disable-radix-cache`（sglang 侧），vllm 等价参数 `--no-enable-prefix-caching`。不关会导致 prefix cache 命中、指标失真。
- 吞吐参考（8 卡 C500 单实例，预热后）：prefill 输入吞吐 ~256 token/s（64k 上下文下会下降），decode EAGLE 投机采样 spec_accept_rate ≈ 0.4。
- 压测工具沿用 GLM 方案：`sglang/bench_serving`（benchmark_args 见 pd-stress-test-report.zh.md）。

## 6. 连不上时排查（按顺序）

1. **入口可达性**：`curl -s -o /dev/null -w "%{http_code}" http://10.0.0.232:8081/health` → 200？
2. **Pod 就绪**：`oc -n metax-ai-pd get pods -l 'llm-d.ai/guide=pd-disaggregation'` → prefill 4×1/1、decode 4×2/2？
3. **EPP 端点**：`oc -n metax-ai-pd logs deploy/pd-disaggregation-epp -c epp | grep -oE '"endpoint":"metax-ai-pd/[a-z0-9-]+-rank-0"'` → 应有 8 个端点
4. **bootstrap**：`curl "http://<prefill-ip>:8998/route?prefill_dp_rank=-1&prefill_cp_rank=-1&target_tp_rank=-1&target_pp_rank=-1"` → 200？
5. **P/D 日志**：宿主机 `/var/log/sglang-dsv4/prefill-rank{N}.log` / `decode-rank{N}.log`（hostPath 落盘，Pod 重建后仍在）
6. 报 `Decode handshake failed / KVTransferError` → RDMA 或 bootstrap 问题，见 `lws/README.md` §8 排障记录
