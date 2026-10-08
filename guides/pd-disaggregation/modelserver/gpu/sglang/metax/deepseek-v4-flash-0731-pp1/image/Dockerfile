# ═══════════════════════════════════════════════════════════════════════════
# 0731 修复镜像: 0.5.14-maca 官方镜像 + DeepSeek-V4-Flash-0731 (ModelSlim W8A8) 加载/推理修复
#
# 问题 (实测确认, 0.5.12-maca 与 0.5.14-maca 均复现):
#   1. ModelSlimConfig 对 DSv4 description 的 key 处理与运行时 module 树不匹配
#      (0.5.14 的 HF remap: self_attn/mlp/down_proj vs 运行时 attn/ffn/w2 + "model." 前缀)
#      → scheme 探测全查空 → create_weights AttributeError (NoneType)
#   2. ModelSlim 量化 kernel 全部为 Ascend NPU 实现 (torch.ops.npu.* / sgl_kernel_npu),
#      MACA 上不存在 → graph capture 期 AttributeError / RuntimeError
#
# 修复 (见 apply_0731_dsv4_patch.py 头部注释, 单节点非 PD 启动 + 推理正确性实测闭环):
#   - modelslim.py: key 归一化 ("model." 前缀) + fused key 合成 (wqkv_a/gate_up_proj/down_proj)
#   - linear_method_npu.py: W8A8 linear → mctlass op 直调 (b=[N,K], scale_b=[N,1] 不转置)
#   - fused_moe_method_npu.py + modelslim_w8a8_int8_moe.py: MoE → GPU Triton 委托
#
# 构建:
#   docker build -t harbor.isuanova.com/metax/sglang:0.5.14-maca.ai3.8.2.122-dsv4-0731 .
#   docker push harbor.isuanova.com/metax/sglang:0.5.14-maca.ai3.8.2.122-dsv4-0731
# ═══════════════════════════════════════════════════════════════════════════
FROM harbor.isuanova.com/metax/sglang:0.5.14-maca.ai3.8.2.122-torch2.10-py312-ubuntu22.04-amd64

COPY apply_0731_dsv4_patch.py /tmp/apply_0731_dsv4_patch.py
RUN /opt/conda/bin/python3 /tmp/apply_0731_dsv4_patch.py \
 && /opt/conda/bin/python3 -c "import ast; base='/opt/conda/lib/python3.12/site-packages/'; files=[base+'sglang/srt/layers/quantization/modelslim/modelslim.py', base+'sglang/srt/hardware_backend/npu/quantization/linear_method_npu.py', base+'sglang/srt/hardware_backend/npu/quantization/fused_moe_method_npu.py', base+'sglang/srt/layers/quantization/modelslim/schemes/modelslim_w8a8_int8_moe.py']; [ast.parse(open(f).read()) for f in files]; assert all('PATCH-0731' in open(f).read() for f in files), 'patch marker missing'; print('[Dockerfile] 0731 patch verified on 4 files')" \
 && rm -f /tmp/apply_0731_dsv4_patch.py
