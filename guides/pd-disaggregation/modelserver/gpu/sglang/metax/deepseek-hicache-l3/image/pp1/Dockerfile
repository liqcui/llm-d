# ═══════════════════════════════════════════════════════════════════════════
# L3-PP1 镜像: r4-hicache-l2-mc013 (L3/Dummy-Client 镜像) + 最优解拓扑补丁
# 用途: L3 (Mooncake Store) 在最优解拓扑 (pp1/tp8/dp4) 下测试 —— 验证拓扑是否
#       消除 09-27 定性的 MACA L3 写回竞态崩溃
# 补丁: 同 L2-PP1 (apply_l2pp1_patch.py): prefill.sh 非 auto 路径 tp 优先取
#       prefill_tp_size, 使 pp1/tp8/dp4 可表达 (原公式 pp=1→tp=32 守卫崩)
# 用法:
#   docker build -t harbor.isuanova.com/metax/sglang:0.5.13-dsv4-adapter-r4-hicache-l2-mc013-pp1 .
#   docker push harbor.isuanova.com/metax/sglang:0.5.13-dsv4-adapter-r4-hicache-l2-mc013-pp1
# ═══════════════════════════════════════════════════════════════════════════
FROM harbor.isuanova.com/metax/sglang:0.5.13-dsv4-adapter-r4-hicache-l2-mc013

COPY apply_l2pp1_patch.py /tmp/apply_l2pp1_patch.py
RUN /opt/conda/bin/python3 /tmp/apply_l2pp1_patch.py \
    && bash -n /workspace/llm-launch/sglang/prefill.sh \
    && rm -f /tmp/apply_l2pp1_patch.py
