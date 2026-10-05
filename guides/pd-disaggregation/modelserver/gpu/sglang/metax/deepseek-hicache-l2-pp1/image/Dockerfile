# ═══════════════════════════════════════════════════════════════════════════
# L2-PP1 镜像: r4-hicache-l2 + prefill.sh 最优解拓扑支持 (pp1/tp8/dp4)
# 用途: deepseek-hicache-l2-pp1 部署 (与 0.5.12 最优解 pp1/tp8/dp4 严格同拓扑对比)
# 基础: harbor.isuanova.com/metax/sglang:0.5.13-dsv4-adapter-r4-hicache-l2 (原 L2 镜像)
# 补丁: prefill.sh 非 auto 路径 tp 优先取 config.sh 的 prefill_tp_size (默认 8)
#       原公式 pp=1 → tp=32 触发 o_groups 守卫, 无法表达最优解拓扑
# 用法:
#   docker build -t harbor.isuanova.com/metax/sglang:0.5.13-dsv4-adapter-r4-hicache-l2-pp1 .
#   docker push harbor.isuanova.com/metax/sglang:0.5.13-dsv4-adapter-r4-hicache-l2-pp1
# ═══════════════════════════════════════════════════════════════════════════
FROM harbor.isuanova.com/metax/sglang:0.5.13-dsv4-adapter-r4-hicache-l2

COPY apply_l2pp1_patch.py /tmp/apply_l2pp1_patch.py
RUN /opt/conda/bin/python3 /tmp/apply_l2pp1_patch.py \
    && bash -n /workspace/llm-launch/sglang/prefill.sh \
    && rm -f /tmp/apply_l2pp1_patch.py
