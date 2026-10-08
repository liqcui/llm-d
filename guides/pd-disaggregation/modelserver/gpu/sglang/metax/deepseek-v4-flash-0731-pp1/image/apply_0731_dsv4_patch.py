#!/usr/bin/env python3
"""DeepSeek-V4-Flash-0731 在 MACA (0.5.14) 上的模型加载/推理修复补丁。

背景
----
`DeepSeek-V4-Flash-0731-w8a8` 是 ModelSlim 格式 (quant_model_description.json +
quant_model_weights) 的 W8A8 量化模型, 其 description 为**原生命名**
(`layers.0.attn.wq_a.weight`), 与 sglang 运行时 module 树 (`model.layers.0.attn.wq_a`,
self_attn/mlp 等) 存在三重不匹配; 且镜像内 ModelSlim 量化实现全部走 **Ascend NPU 内核**
(`torch.ops.npu.*` / `sgl_kernel_npu`), 在 MACA 上不存在。0.5.12-maca 与 0.5.14-maca
均确认无法直接加载该模型 (create_weights AttributeError → graph capture npu_dynamic_quant
AttributeError)。本补丁在 0.5.14-maca.ai3.8.2.122 上实测闭环 (单节点非 PD 启动 + 推理正确)。

修复内容 (4 文件)
-----------------
1. modelslim.py (ModelSlimConfig.__init__)
   - 原版把 DSv4 description remap 成 HF 命名 (self_attn/mlp/down_proj), 与运行时
     sglang 命名 (attn/ffn/w2 + "model." 前缀) 不匹配 → scheme 探测全部查空。
   - 改为: `layers.` 系 key 加 "model." 前缀; embed/head/hc_head_ 保持原 remap 特判;
     合成 fused 模块 key: wqkv_a <- wq_a; shared_experts.gate_up_proj <- w1;
     shared_experts.down_proj <- w2 (运行时 module 为 fused, description 为拆分命名)。
2. linear_method_npu.py (NPUW8A8Int8Dynamic[Linear]Method)
   - 删除 NPU 依赖: process 不做 transpose/npu_format_cast, 保持 weight [N,K] 原始布局,
     weight_scale 转 float32; apply 改为直调 mctlass op
     (`mctlass_w8a8_scaled_mm_azp`), 实测约定: b=[N,K] (不转置), out=[M,N],
     compute a @ b^T, scale_b 传 [N,1] (不转置)。
     ⚠ 镜像自带 wrapper sgl_kernel.cutlass_scaled_mm 的 out 分配 (n=b.shape[1]) 与
     op 约定不符, 不可用 (实测两种朝向均 fail)。
   - weight_offset 全零 (实测 max|.|=0) → 无需 azp, 数学上对称等价。
3. fused_moe_method_npu.py (NPUW8A8Int8DynamicMoEMethod)
   - process 不做 NPU 布局变换; apply 委托同镜像 GPU Triton 实现
     (sglang.srt.layers.quantization.w8a8_int8.W8A8Int8MoEMethod:
     MoeRunner(TRITON) + TritonMoeQuantInfo(use_int8_w8a8=True, per_channel_quant=True))。
4. modelslim_w8a8_int8_moe.py (ModelSlimW8A8Int8MoE.create_moe_runner)
   - scheme 只存 config 不建 runner; 补充调用 kernel.create_moe_runner 注入 runner
     (GPU 委托实现需要)。

用法 (镜像构建内):
    python3 /tmp/apply_0731_dsv4_patch.py            # 应用
    python3 /tmp/apply_0731_dsv4_patch.py --check    # 只校验锚点
"""

import ast
import sys

PREFIX = "/opt/conda/lib/python3.12/site-packages/"
F_MODELSLIM = PREFIX + "sglang/srt/layers/quantization/modelslim/modelslim.py"
F_LINEAR = PREFIX + "sglang/srt/hardware_backend/npu/quantization/linear_method_npu.py"
F_MOE = PREFIX + "sglang/srt/hardware_backend/npu/quantization/fused_moe_method_npu.py"
F_MOE_SCHEME = (
    PREFIX + "sglang/srt/layers/quantization/modelslim/schemes/modelslim_w8a8_int8_moe.py"
)

MARKER = "PATCH-0731"


# --------------------------------------------------------------------------- #
# 1. modelslim.py — description key 归一化 + fused key 合成
# --------------------------------------------------------------------------- #
MS_OLD = """        keys = [k for k in quant_config if isinstance(k, str)]
        is_dsv4 = any(k.startswith("hc_head_") for k in keys)
        if is_dsv4:
            from sglang.srt.models.deepseek_v4 import DeepseekV4ForCausalLM

            remap = DeepseekV4ForCausalLM.remap_weight_name_to_dpsk_hf_format
            quant_config = {
                (remap(k) if isinstance(k, str) else k): v
                for k, v in quant_config.items()
            }
"""

MS_NEW = """        keys = [k for k in quant_config if isinstance(k, str)]
        is_dsv4 = any(k.startswith("hc_head_") for k in keys)
        if is_dsv4:
            # ── PATCH-0731 ──
            # 原版 remap 到 HF 命名 (self_attn/mlp/down_proj) 与运行时 module 树
            # (attn/ffn/w2, 带 "model." 前缀) 不匹配 → scheme 探测全部查空崩溃。
            # 改为: layers. 系 key 加 "model." 前缀 (原生命名与运行时对齐);
            # embed/head/hc_head_ 保持 remap 特判; 并合成 fused 模块 key
            # (wqkv_a / shared_experts.gate_up_proj / down_proj) 供 scheme 探测。
            import re as _re

            from sglang.srt.models.deepseek_v4 import DeepseekV4ForCausalLM

            _remap = DeepseekV4ForCausalLM.remap_weight_name_to_dpsk_hf_format
            _new = {}
            for _k, _v in quant_config.items():
                if not isinstance(_k, str):
                    _new[_k] = _v
                    continue
                _mrow = _re.match(r"mtp\.(\d+)\.(.+)$", _k)
                if _mrow:
                    # DSpark draft 量化查找用原始 mtp.N.* 命名; 补 MoE
                    # w1/w2/w3 -> gate_proj/down_proj/up_proj 与
                    # shared_experts w1->gate_up_proj / w2->down_proj 别名
                    _new[_k] = _v
                    _rest = _mrow.group(2)
                    _rest2 = (
                        _rest.replace(".w1.", ".gate_proj.")
                        .replace(".w2.", ".down_proj.")
                        .replace(".w3.", ".up_proj.")
                    )
                    if _rest2 != _rest:
                        _new["mtp." + _mrow.group(1) + "." + _rest2] = _v
                    _m3 = _re.match(
                        r"(mtp\.\d+\.ffn\.shared_experts\.)w(1|2)(\..+)$", _k
                    )
                    if _m3:
                        _tag = "gate_up_proj" if _m3.group(2) == "1" else "down_proj"
                        _new[_m3.group(1) + _tag + _m3.group(3)] = _v
                    continue
                if _k.startswith("layers."):
                    _new["model." + _k] = _v
                elif _k.startswith(("embed.", "head.", "hc_head_")):
                    _new[_remap(_k)] = _v
                else:
                    _new[_k] = _v
            _fused = {}
            for _fk, _fv in list(_new.items()):
                _m = _re.match(r"(model\\.layers\\.\\d+\\.attn\\.)wq_a(\\..+)$", _fk)
                if _m:
                    _fused[_m.group(1) + "wqkv_a" + _m.group(2)] = _fv
                _m2 = _re.match(
                    r"(model\\.layers\\.\\d+\\.ffn\\.shared_experts\\.)w(1|2)(\\..+)$", _fk
                )
                if _m2:
                    _tag = "gate_up_proj" if _m2.group(2) == "1" else "down_proj"
                    _fused[_m2.group(1) + _tag + _m2.group(3)] = _fv
            _new.update(_fused)
            print(
                f"[PATCH-0731] normalized {len(_new)} quant keys (fused +{len(_fused)})"
            )
            quant_config = _new
"""

# --------------------------------------------------------------------------- #
# 2a. linear_method_npu.py — W8A8 dynamic: process (NPU → MACA 布局约定)
# --------------------------------------------------------------------------- #
LIN_PROC_OLD = """    def process_weights_after_loading(self, layer: torch.nn.Module):
        layer.weight.data = layer.weight.data.transpose(0, 1).contiguous()
        layer.weight.data = npu_format_cast(layer.weight.data)

        layer.weight_scale.data = layer.weight_scale.data.flatten()
        # Compressed-tensors format doesn't have this field
        if hasattr(layer, "weight_offset"):
            layer.weight_offset.data = layer.weight_offset.data.flatten()
"""

LIN_PROC_NEW = """    def process_weights_after_loading(self, layer: torch.nn.Module):
        # ── PATCH-0731 ── NPU 依赖删除; mctlass 实测约定: weight 保持 [N,K]
        # 原始布局 (不 transpose), weight_scale 转 float32。offset 全零无需 azp。
        if getattr(layer, "weight_scale", None) is not None:
            layer.weight_scale.data = layer.weight_scale.data.to(torch.float32)
"""

# --------------------------------------------------------------------------- #
# 2b. linear_method_npu.py — W8A8 dynamic: apply (npu ops → mctlass 直调)
# --------------------------------------------------------------------------- #
LIN_APPLY_OLD = """        if isinstance(x, tuple):
            \"\"\"dynamic_scale is calculated in malprolog kernel\"\"\"
            original_dtype = torch.bfloat16
            quant_out, dynamic_scale = x
        else:
            original_dtype = x.dtype
            quant_out, dynamic_scale = torch.ops.npu.npu_dynamic_quant(x)
        return torch.ops.npu.npu_quant_matmul(
            quant_out,
            layer.weight,
            layer.weight_scale,
            pertoken_scale=dynamic_scale.flatten(),
            bias=bias,
            output_dtype=original_dtype,
        )
"""

LIN_APPLY_NEW = """        # ── PATCH-0731 ── 直调 mctlass w8a8 op (实测约定: b=[N,K] 不转置,
        # out=[M,N], 计算 a @ b^T, scale_b 传 [N,1] 不转置)。镜像自带 wrapper
        # sgl_kernel.cutlass_scaled_mm 的 out 分配与 op 不符, 不可用。
        from sglang.srt.layers.quantization.int8_kernel import per_token_quant_int8
        import mctlassEx

        if isinstance(x, tuple):
            original_dtype = torch.bfloat16
            quant_out, dynamic_scale = x
        else:
            original_dtype = x.dtype
            quant_out, dynamic_scale = per_token_quant_int8(x)

        weight = layer.weight  # [N=out, K=in] int8
        out = torch.empty(
            (quant_out.shape[0], weight.shape[0]),
            dtype=original_dtype,
            device=x.device,
        )
        if bias is not None and bias.ndim == 1:
            bias = bias.unsqueeze(0)
        mctlassEx.mctlassExHandleWrapper().mctlass_w8a8_scaled_mm_azp(
            quant_out,
            weight,
            out,
            dynamic_scale,
            layer.weight_scale,
            bias,
            None,
            None,
            torch.cuda.current_stream().cuda_stream,
        )
        return out
"""

# --------------------------------------------------------------------------- #
# 3a. fused_moe_method_npu.py — W8A8 MoE: process
# --------------------------------------------------------------------------- #
MOE_PROC_OLD = """    def process_weights_after_loading(self, layer: torch.nn.Module) -> None:
        if self._maybe_apply_fuseep_weights(layer):
            return
        layer.w13_weight.data = npu_format_cast(
            layer.w13_weight.data.transpose(1, 2).contiguous()
        )
        layer.w2_weight.data = npu_format_cast(
            layer.w2_weight.data.transpose(1, 2).contiguous()
        )
        layer.w13_weight_scale = torch.nn.Parameter(
            layer.w13_weight_scale.data.squeeze(-1), requires_grad=False
        )
        layer.w2_weight_scale = torch.nn.Parameter(
            layer.w2_weight_scale.data.squeeze(-1), requires_grad=False
        )
        layer.w13_weight_scale_bf16 = torch.nn.Parameter(
            layer.w13_weight_scale.data.to(dtype=torch.bfloat16), requires_grad=False
        )
        layer.w2_weight_scale_bf16 = torch.nn.Parameter(
            layer.w2_weight_scale.data.to(dtype=torch.bfloat16), requires_grad=False
        )
        # Compressed-tensors format doesn't have this field
        if hasattr(layer, "w13_weight_offset"):
            layer.w13_weight_offset = torch.nn.Parameter(
                layer.w13_weight_offset.data.squeeze(-1),
                requires_grad=False,
            )
        if hasattr(layer, "w2_weight_offset"):
            layer.w2_weight_offset = torch.nn.Parameter(
                layer.w2_weight_offset.data.squeeze(-1),
                requires_grad=False,
            )

        if hasattr(layer, "dispatcher"):
            layer.dispatcher.set_quant_config({"dispatcher_output_dtype": "int8"})
"""

MOE_PROC_NEW = """    def process_weights_after_loading(self, layer: torch.nn.Module) -> None:
        # ── PATCH-0731 ── GPU triton MoE 约定: weight 保持 [E,2I,H]/[E,H,I],
        # scales 保持 [E,N,1] float32; 不做 NPU transpose/format_cast/squeeze。
        if self._maybe_apply_fuseep_weights(layer):
            return
        layer.w13_weight = torch.nn.Parameter(layer.w13_weight, requires_grad=False)
        layer.w2_weight = torch.nn.Parameter(layer.w2_weight, requires_grad=False)
        layer.w13_weight_scale = torch.nn.Parameter(
            layer.w13_weight_scale.data, requires_grad=False
        )
        layer.w2_weight_scale = torch.nn.Parameter(
            layer.w2_weight_scale.data, requires_grad=False
        )

    # ── PATCH-0731 ── GPU 委托 (NPU 实现依赖 torch.ops.npu.*)
    def _gpu(self):
        d = self.__dict__.get("_gpu_delegate")
        if d is None:
            from sglang.srt.layers.quantization.w8a8_int8 import W8A8Int8MoEMethod

            d = W8A8Int8MoEMethod(getattr(self, "quant_config", None))
            self.__dict__["_gpu_delegate"] = d
        return d

    def create_moe_runner(self, layer, moe_runner_config):
        return self._gpu().create_moe_runner(layer, moe_runner_config)

    def get_triton_quant_info(self, layer):
        from sglang.srt.layers.moe.moe_runner.triton import TritonMoeQuantInfo

        return TritonMoeQuantInfo(
            w13_weight=layer.w13_weight,
            w2_weight=layer.w2_weight,
            use_int8_w8a8=True,
            per_channel_quant=True,
            w13_scale=layer.w13_weight_scale,
            w2_scale=layer.w2_weight_scale,
            a13_scale=getattr(layer, "w13_input_scale", None),
            a2_scale=getattr(layer, "w2_input_scale", None),
        )
"""

# --------------------------------------------------------------------------- #
# 3b. fused_moe_method_npu.py — W8A8 MoE: apply
# --------------------------------------------------------------------------- #
MOE_APPLY_OLD = """        from sglang.srt.layers.moe.token_dispatcher import StandardCombineInput

        combine_input = self._maybe_apply_deepep(layer, dispatch_output)
        if combine_input is not None:
            return combine_input

        # release fp32 scale to save memory
        layer.w13_weight_scale = None
        layer.w2_weight_scale = None

        hidden_states = dispatch_output.hidden_states
        topk_output = dispatch_output.topk_output

        topk_weights, topk_ids, _ = topk_output
        topk_ids = topk_ids.to(torch.int32)
        topk_weights = topk_weights.to(hidden_states.dtype)

        # prefill
        if not torch.npu.is_current_stream_capturing():
            output = npu_fused_experts(
                hidden_states=hidden_states,
                w13=layer.w13_weight,
                w13_scale=layer.w13_weight_scale_bf16,
                w2=layer.w2_weight,
                w2_scale=layer.w2_weight_scale_bf16,
                topk_weights=topk_weights,
                topk_ids=topk_ids,
                top_k=topk_ids.shape[1],
            )
        # decode
        else:
            output = npu_fused_experts_w8a8_decode(
                hidden_states=hidden_states,
                w13=layer.w13_weight,
                w13_scale=layer.w13_weight_scale_bf16,
                w2=layer.w2_weight,
                w2_scale=layer.w2_weight_scale_bf16,
                topk_weights=topk_weights,
                topk_ids=topk_ids,
                top_k=topk_ids.shape[1],
            )

        return StandardCombineInput(hidden_states=output)
"""

MOE_APPLY_NEW = """        # ── PATCH-0731 ── 委托 GPU Triton w8a8 MoE runner (NPU 实现依赖 torch.npu)
        return self._gpu().runner.run(
            dispatch_output, self.get_triton_quant_info(layer)
        )
"""

# --------------------------------------------------------------------------- #
# 4. modelslim_w8a8_int8_moe.py — scheme 注入 kernel runner
# --------------------------------------------------------------------------- #
SCHEME_OLD = """    def create_moe_runner(
        self, layer: torch.nn.Module, moe_runner_config: MoeRunnerConfig
    ):
        self.moe_runner_config = moe_runner_config

"""

SCHEME_NEW = """    def create_moe_runner(
        self, layer: torch.nn.Module, moe_runner_config: MoeRunnerConfig
    ):
        self.moe_runner_config = moe_runner_config
        # ── PATCH-0731 ── 同时初始化 kernel 侧 runner (GPU 委托实现需要)
        if hasattr(self.kernel, "create_moe_runner"):
            self.kernel.create_moe_runner(layer, moe_runner_config)

"""

PATCHES = [
    # (名称, 文件, 旧文本, 新文本, 期望出现次数)
    ("modelslim.py", F_MODELSLIM, MS_OLD, MS_NEW, 1),
    ("linear_method_npu.py:proc", F_LINEAR, LIN_PROC_OLD, LIN_PROC_NEW, 2),
    ("linear_method_npu.py:apply", F_LINEAR, LIN_APPLY_OLD, LIN_APPLY_NEW, 1),
    ("fused_moe_method_npu.py:proc", F_MOE, MOE_PROC_OLD, MOE_PROC_NEW, 1),
    ("fused_moe_method_npu.py:apply", F_MOE, MOE_APPLY_OLD, MOE_APPLY_NEW, 1),
    ("modelslim_w8a8_int8_moe.py", F_MOE_SCHEME, SCHEME_OLD, SCHEME_NEW, 1),
]


def main() -> None:
    check_only = "--check" in sys.argv
    for name, path, old, new, expect in PATCHES:
        src = open(path).read()
        # 转义回退: 本脚本中 MS_NEW 的 regex 写作 \\. (两层转义), 实际写入文件需 \.
        new = new.replace("\\\\.", "\\.")
        if MARKER in src and old not in src:
            print(f"[skip] {name}: 已打过补丁")
            continue
        n = src.count(old)
        if n != expect:
            sys.exit(f"[FAIL] {name}: 锚点匹配 {n} 次 (期望 {expect})")
        if check_only:
            print(f"[ok] {name}: 锚点唯一 x{expect}")
            continue
        src = src.replace(old, new)
        ast.parse(src)  # 语法校验
        open(path, "w").write(src)
        print(f"[applied] {name}")

    print("[PATCH-0731] done" + (" (check only)" if check_only else ""))


if __name__ == "__main__":
    main()
