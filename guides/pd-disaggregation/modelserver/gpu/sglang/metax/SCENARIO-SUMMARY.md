# 场景化测试总结与方案选型 — 2026-09-26

> 汇总 `deepseek-v4-rc3-maca`（生产）与 `deepseek-hicache`（HiCache 实验）两条线的
> 全部测试结果，按场景给出最佳方案。

---

## 一、各场景测试结果总表

| # | 场景 | 配置 | 结果 | 数据 |
|---|---|---|---|---|
| 1 | **短上下文高吞吐**（512/128, rate 20, 100 req） | 0.5.12-maca.ai3.8.2.7-llm；tp8/ep8/dp4/pp1（官方模式+EAGLE-5+EPLB+mem0.75） | ✅ **生产可用** | **1238 tok/s**，TTFT 0.82s，TPOT 36.8ms，100/100 |
| 2 | **长上下文**（4096/2048, rate 5, 50 req） | 同 #1 | ✅ **生产可用** | **1481 tok/s**，TTFT 0.58s（EAGLE accept 升至 0.45-0.60）|
| 3 | 超长上下文（32K 单请求） | 同 #1 | ✅ 可用（低并发） | KV 池用量 97-98%，稳定；5-6 并发 32K 序列 |
| 4 | 旧引擎对比（0.5.13） | 0.5.13-maca-llm | ❌ 弃用 | 120 tok/s（慢 8x）+ node33 illegal access |
| 5 | 旧 MACA 对比（3.7.1.13） | 0.5.12-dsv4-c500-llm | ⚠ 次优 | 958 tok/s（比 3.8.2.6 低 29%），驱动不匹配风险 |
| 6 | 厂商默认拓扑对比 | decode tp32/dp32/ep32 + prefill tp4/pp8 | ⚠ 差于最优但非 4x | 首轮 298 tok/s（JIT 热身，09-26 误记）；**2026-10-01 同日 7-8 轮全记录见 `deepseek-v4-rc3-maca/lws/BENCHMARK-COMPARISON-2026-10-01.md`**：Output 中位 982 vs 1019（峰值 1030 vs 1254）、TTFT 中位 3.2s vs 1.1s；❌ **1 小时压测崩 2 次**（prefill rank0 illegal access）+ 启动 25-40min（vs optimal 8min）|
| 7 | **HiCache L2+L3（32 卡跨节点）** | prefill r4(0.5.13)+hicache；tp8/pp4/dp1 | ⚠ **功能通/写回崩** | prefetch ✓ loaded=512；write_backup 触发 MACA transfer kernel Xnack 崩溃 |
| 8 | **HiCache 单机 PP8/TP1**（GPUStack 原配方） | prefill r4；size=1；pp8/tp1 | ⚠ **同样崩溃**（验证实验） | 完全相同栈（`host_indices.to(device)` → Xnack）；**排除形态因素** |

## 二、按场景选型

### 场景 A：线上生产推理（短/长上下文、高吞吐）→ **方案 1**

```
镜像: 0.5.12-maca.ai3.8.2.7-torch2.10-py312-ubuntu22.04-amd64-llm
模式: official (厂商 llm-launch)
拓扑: tp=8 / ep=8 / dp=4 / pp=1（prefill 同）
关键参数: mem-fraction 0.75, EAGLE draft=5, EPLB 开, max-running 厂商默认(40×dp)
```
✅ 已稳定生产运行；1238-1481 tok/s；文档 `deepseek-v4-rc3-maca/lws/OPTIMIZATION.md`

### 场景 B：长 SystemPrompt / 多轮对话（KV 跨请求复用）→ **方案 7/8（暂不可用，待修复）**

- HiCache 功能链路已验证（L3 写/prefetch/回读全路径 + 端到端）
- **阻塞**：KV write_backup 触发 MACA transfer kernel 竞态（`host_indices.to(device)` Xnack）
- **未解决的关键差异**（对照 GPUStack 报告跑通的原因）：
  1. 他们报告的 **"SGLang/Mooncake compatibility workaround"**（未公开具体内容）——需向他们获取
  2. MACA 驱动栈版本（他们报告未注明；我们：内核 3.9.6 + 用户态 3.8.2.6/驱动 3.8.1.3）
- **已排除**：拓扑形态（单机 PP8/TP1 同样崩）、io-backend（direct/kernel 同样崩）、节点数
- **修复路径**：向 GPUStack 要 workaround 清单 → 向 MACA 报障（栈完整）→ 精细同步补丁

### 场景 C：不用 HiCache 但需长上下文 → **方案 1**（长上下文吞吐反而更高）

### 场景 D：资源不足（仅 1 节点 8 卡） → 方案 1 的 prefill 单机变体（pp8/tp1 手动模式，启动 6m52s 更快，但 hiCache 关闭时不建议——吞吐减半以上）

## 三、关键结论

1. **生产最优 = 方案 1**（0.5.12-maca.ai3.8.2.7-llm + 最优参数），各项基准已验证
2. **HiCache 价值明确但当前不可交付**：功能链路 100% 通（prefetch/L3/PD 全验证），唯一阻塞是 MACA 原生栈的 transfer kernel 竞态（`_inc_hit_count → write_backup` 路径）
3. **对比 GPUStack 跑通的差异收敛为**：他们的 compatibility workaround + MACA 栈版本——**建议直接向 GPUStack 团队索取 workaround 具体内容**（这是最快的解锁路径，他们文档明确提到"在完成 compatibility workaround 后成功启动"）
4. 压测数据诚实说明：HiCache 的 TTFT 对比数据（L3 vs L2 vs Cold）**待阻塞解决后按 GPUStack §19 的 A/B/C 场景补充**

## 四、测试方法学备注

- 所有对比均为单变量实验（压测条件统一：benchmark 镜像 + ShareGPT/本地数据集）
- 引擎性能存在 **TileLang JIT 热身期**（首轮偏低，取 2-3 轮稳定值）
- MACA 崩溃证据链完整（MXC/MCR 内核日志 + Python 栈 + py-spy dump），可直接报送
