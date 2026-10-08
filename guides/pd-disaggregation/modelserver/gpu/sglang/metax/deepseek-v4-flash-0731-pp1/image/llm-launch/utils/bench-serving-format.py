# 将 csv 格式的数据提取指定的列，并通过计算之后，拼到一起输出，中间空两列。
# 示例：
# 输入：
# Backend,Traffic request rate,Max request concurrency,Successful requests,Benchmark duration (s),Total input tokens,Total generated tokens,Total generated tokens (retokenized),Request throughput (req/s),Input token throughput (tok/s),Output token throughput (tok/s),Total token throughput (tok/s),Concurrency,Accept length,Mean E2E Latency (ms),Median E2E Latency (ms),Mean TTFT (ms),Median TTFT (ms),P99 TTFT (ms),Mean TPOT (ms),Median TPOT (ms),P99 TPOT (ms),Mean ITL (ms),Median ITL (ms),P95 ITL (ms),P99 ITL (ms),Max ITL (ms),time
# sglang,50.0,1536,4608,385.63,2359296,7077888,7053279,11.95,6117.96,18353.88,24471.84,1318.51,1.90,110343.68,105478.99,14796.50,3701.00,64000.88,62.25,64.19,73.55,62.25,57.16,116.95,168.97,1025.46,2026-03-20 11:55:01.255041
# sglang,50.0,1536,12288,894.31,6291456,18874368,18810654,13.74,7034.97,21104.90,28139.86,1444.26,1.90,105112.53,103794.50,3313.55,868.14,35426.95,66.32,66.21,75.04,66.32,60.50,124.98,191.49,1472.73,2026-03-20 12:02:18.086142
# 参数指定需要选中的列，默认值为： prefills,decode-ep,prefill-chunk,prompts,concurrency-per-card,max-concurrency,input-length,output-length,request-rate,tbo,graph,mtp,ttft,tpot,total-throughput,input-throughtput,output-throughput,qps,accent-length,prefill-throughput-per-card,decode-throughput-per-card,decode-throughput-per-card-total,time
# 参数额外提供的值：
#   --prefills: 默认值 1
#   --prefill-cards: 默认值 16
#   --decodes: 默认值 1
#   --decode-cards: 默认值 32
#   --prefill-chunk-size: 无默认值，必须指定
#   --tbo: bool 值, 接受 --tbo/--tbo True/--tbo False, 默认值 False, 输出为 ON/OFF
#   --disable-graph: bool 值, 接受 --disable-graph/--disable-graph True/--disable-graph False, 默认值 False
#   --mtp: 接受 int 值 0/1/2/3, 默认值 2；0 和 1 与之前的 off 效果相同，输出统一为 off
#   --keep-even-rows: 可选开关，开启后删除奇数数据行，只保留偶数数据行
#
# 内置规则映射表, 前面是参数指定的需要放到前面的列, 后面是对应的值。这个值以 -- 开头表示来自参数；名字在输入数据的列里就表示来自输入数据的列(不需要完全匹配，只要对应列名包含对应的值就行，取第一个匹配的列)。有些列不是简单的复制，而是需要多列计算。
# prefills: --prefills
# decode-ep: --decodes * --decode-cards
# prefill-chunk: --prefill-chunk-size
# prompts: Successful requests
# concurrency-per-card: Max request concurrency / decode-ep
# max-concurrency: Max request concurrency
# input-length: Total input tokens / Successful requests
# output-length: Total generated tokens / Successful requests
# request-rate: Traffic request rate
# tbo: --tbo, True 输出 ON, False 输出 OFF
# graph: not --disable-graph, --disable-graph 为 True 时输出 OFF, 否则输出 ON
# mtp: --mtp, 0 和 1 输出 off，2 和 3 输出对应数字
# ttft: Mean TTFT
# tpot: Mean TPOT
# total-throughput: Total token throughput
# input-throughtput: Input token throughput
# output-throughput: Output token throughput
# qps: Request throughput
# accent-length: Accept length
# prefill-throughput-per-card: Input token throughput / (--prefills * --prefill-cards)
# decode-throughput-per-card: Output token throughput / (--decodes * --decode-cards)
# decode-throughput-per-card-total: Total token throughput / ((--prefills * --prefill-cards) + (--decodes * --decode-cards))
# time: time
#
# 输出（原始输入列保持原样，计算结果按 float 默认输出，time 保持原始值）：
# prefills,decode-ep,prefill-chunk,prompts,concurrency-per-card,max-concurrency,input-length,output-length,request-rate,tbo,graph,mtp,ttft,tpot,total-throughput,input-throughtput,output-throughput,qps,accent-length,prefill-throughput-per-card,decode-throughput-per-card,decode-throughput-per-card-total,time,,,Backend,Traffic request rate,Max request concurrency,Successful requests,Benchmark duration (s),Total input tokens,Total generated tokens,Total generated tokens (retokenized),Request throughput (req/s),Input token throughput (tok/s),Output token throughput (tok/s),Total token throughput (tok/s),Concurrency,Accept length,Mean E2E Latency (ms),Median E2E Latency (ms),Mean TTFT (ms),Median TTFT (ms),P99 TTFT (ms),Mean TPOT (ms),Median TPOT (ms),P99 TPOT (ms),Mean ITL (ms),Median ITL (ms),P95 ITL (ms),P99 ITL (ms),Max ITL (ms),time
# 1,32,14336,4608,48.0,1536,512.0,1536.0,50.0,OFF,ON,2,14796.50,62.25,24471.84,6117.96,18353.88,11.95,1.90,382.3725,573.55875,509.83,2026-03-20 11:55:01.255041,,,sglang,50.0,1536,4608,385.63,2359296,7077888,7053279,11.95,6117.96,18353.88,24471.84,1318.51,1.90,110343.68,105478.99,14796.50,3701.00,64000.88,62.25,64.19,73.55,62.25,57.16,116.95,168.97,1025.46,2026-03-20 11:55:01.255041
# 1,32,14336,12288,48.0,1536,512.0,1536.0,50.0,OFF,ON,2,3313.55,66.32,28139.86,7034.97,21104.90,13.74,1.90,439.685625,659.528125,586.2470833333333,2026-03-20 12:02:18.086142,,,sglang,50.0,1536,12288,894.31,6291456,18874368,18810654,13.74,7034.97,21104.90,28139.86,1444.26,1.90,105112.53,103794.50,3313.55,868.14,35426.95,66.32,66.21,75.04,66.32,60.50,124.98,191.49,1472.73,2026-03-20 12:02:18.086142


import argparse
import csv
import sys

from contextlib import nullcontext
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


SOURCE_COLUMN_ALIASES = {
    "successful-requests": ["Successful requests"],
    "max-request-concurrency": ["Max request concurrency"],
    "total-input-tokens": ["Total input tokens"],
    "total-generated-tokens": ["Total generated tokens"],
    "traffic-request-rate": ["Traffic request rate"],
    "mean-ttft": ["Mean TTFT"],
    "mean-tpot": ["Mean TPOT"],
    "total-token-throughput": ["Total token throughput"],
    "input-token-throughput": ["Input token throughput"],
    "output-token-throughput": ["Output token throughput"],
    "request-throughput": ["Request throughput"],
    "accept-length": ["Accept length"],
    "time": ["time"],
}

DIRECT_OUTPUT_COLUMNS = {
    "prompts": "successful-requests",
    "max-concurrency": "max-request-concurrency",
    "request-rate": "traffic-request-rate",
    "ttft": "mean-ttft",
    "tpot": "mean-tpot",
    "total-throughput": "total-token-throughput",
    "input-throughtput": "input-token-throughput",
    "input-throughput": "input-token-throughput",
    "output-throughput": "output-token-throughput",
    "qps": "request-throughput",
    "accent-length": "accept-length",
    "accept-length": "accept-length",
}

PARAMETER_OUTPUT_COLUMNS = {
    "prefills": "prefills",
    "prefill-chunk": "prefill_chunk_size",
    "tbo": "tbo",
}

DEFAULT_COLUMNS = (
    "prefills,decode-ep,prefill-chunk,prompts,concurrency-per-card,"
    "max-concurrency,input-length,output-length,request-rate,tbo,graph,mtp,"
    "ttft,tpot,total-throughput,input-throughtput,output-throughput,qps,"
    "accent-length,prefill-throughput-per-card,decode-throughput-per-card,"
    "decode-throughput-per-card-total,time"
)


@dataclass(frozen=True)
class EvalContext:
    args: argparse.Namespace
    row: dict[str, str]
    source_headers: dict[str, str]


def main() -> None:
    args = parse_args()
    requested_columns = split_requested_columns(args.columns)

    if not requested_columns:
        raise SystemExit("No columns requested")

    with open_input(args.input_file) as input_stream:
        reader = csv.DictReader(input_stream)
        if reader.fieldnames is None:
            raise SystemExit("Input CSV is missing a header row")

        source_headers = resolve_source_headers(reader.fieldnames, requested_columns)
        writer = csv.writer(sys.stdout, lineterminator="\n")
        writer.writerow(requested_columns + [""] * args.padding_columns + list(reader.fieldnames))

        for row_index, row in enumerate(reader, start=1):
            if args.keep_even_rows and row_index % 2 == 1:
                continue

            ctx = EvalContext(args=args, row=row, source_headers=source_headers)
            selected_values = [evaluate_output_column(column, ctx) for column in requested_columns]
            original_values = [row.get(fieldname, "") for fieldname in reader.fieldnames]
            writer.writerow(selected_values + [""] * args.padding_columns + original_values)

def split_requested_columns(raw_columns: str) -> list[str]:
    return [column.strip() for column in raw_columns.split(",") if column.strip()]


def open_input(input_file: str):
    if input_file == "-":
        return nullcontext(sys.stdin)
    return Path(input_file).open("r", encoding="utf-8", newline="")


def build_header_map(fieldnames: Sequence[str]) -> dict[str, str]:
    header_map: dict[str, str] = {}
    for fieldname in fieldnames:
        normalized_fieldname = fieldname.casefold()
        header_map.setdefault(normalized_fieldname, fieldname)
    return header_map


def resolve_source_headers(
    fieldnames: Sequence[str], requested_columns: Sequence[str]
) -> dict[str, str]:
    header_map = build_header_map(fieldnames)
    source_keys = collect_required_source_keys(requested_columns)
    resolved_headers: dict[str, str] = {}
    missing_columns: list[str] = []

    for source_key in sorted(source_keys):
        matched_header = find_matching_header(source_key, header_map)
        if matched_header is None:
            missing_columns.append(source_key)
            continue
        resolved_headers[source_key] = matched_header

    if missing_columns:
        available_headers = ", ".join(fieldnames)
        missing_text = ", ".join(missing_columns)
        raise SystemExit(
            f"Failed to resolve source columns: {missing_text}. Available headers: {available_headers}"
        )

    return resolved_headers


def collect_required_source_keys(requested_columns: Sequence[str]) -> set[str]:
    required = {"time"}
    for column in requested_columns:
        canonical_column = canonicalize_name(column)
        if canonical_column == "graph":
            continue
        if canonical_column == "mtp":
            continue
        if canonical_column in PARAMETER_OUTPUT_COLUMNS:
            continue
        if canonical_column in DIRECT_OUTPUT_COLUMNS:
            required.add(DIRECT_OUTPUT_COLUMNS[canonical_column])
        elif canonical_column in COMPUTED_COLUMN_DEPENDENCIES:
            required.update(COMPUTED_COLUMN_DEPENDENCIES[canonical_column])
        elif canonical_column == "time":
            required.add("time")
        else:
            required.add(canonical_column)
    return required


def find_matching_header(source_key: str, header_map: dict[str, str]) -> str | None:
    # 这里按“别名 -> 模糊匹配输入表头”的方式处理，兼容 benchmark 输出字段里带单位或后缀的情况。
    candidate_patterns = SOURCE_COLUMN_ALIASES.get(source_key, [source_key])
    normalized_patterns = [pattern.casefold() for pattern in candidate_patterns]

    for normalized_header, original_header in header_map.items():
        if any(pattern in normalized_header for pattern in normalized_patterns):
            return original_header
    return None


def evaluate_output_column(column_name: str, ctx: EvalContext) -> str:
    canonical_column = canonicalize_name(column_name)

    if canonical_column == "graph":
        return stringify_param_value(not ctx.args.disable_graph)

    if canonical_column == "mtp":
        return format_mtp_value(ctx.args.mtp)

    if canonical_column in PARAMETER_OUTPUT_COLUMNS:
        return stringify_param_value(getattr(ctx.args, PARAMETER_OUTPUT_COLUMNS[canonical_column]))

    if canonical_column in DIRECT_OUTPUT_COLUMNS:
        return get_source_text(ctx, DIRECT_OUTPUT_COLUMNS[canonical_column])

    if canonical_column == "decode-ep":
        return str(ctx.args.decodes * ctx.args.decode_cards)

    if canonical_column == "concurrency-per-card":
        return divide_float(
            get_source_float(ctx, "max-request-concurrency"),
            float(ctx.args.decodes * ctx.args.decode_cards),
        )

    if canonical_column == "input-length":
        return divide_float(
            get_source_float(ctx, "total-input-tokens"),
            get_source_float(ctx, "successful-requests"),
        )

    if canonical_column == "output-length":
        return divide_float(
            get_source_float(ctx, "total-generated-tokens"),
            get_source_float(ctx, "successful-requests"),
        )

    if canonical_column == "prefill-throughput-per-card":
        return divide_float(
            get_source_float(ctx, "input-token-throughput"),
            float(ctx.args.prefills * ctx.args.prefill_cards),
        )

    if canonical_column == "decode-throughput-per-card":
        return divide_float(
            get_source_float(ctx, "output-token-throughput"),
            float(ctx.args.decodes * ctx.args.decode_cards),
        )

    if canonical_column == "decode-throughput-per-card-total":
        total_cards = float(
            ctx.args.prefills * ctx.args.prefill_cards
            + ctx.args.decodes * ctx.args.decode_cards
        )
        return divide_float(get_source_float(ctx, "output-token-throughput"), total_cards)

    if canonical_column == "time":
        return get_source_text(ctx, "time")

    source_text = try_get_source_text(ctx, canonical_column)
    if source_text is not None:
        return source_text

    raise SystemExit(f"Unsupported output column: {column_name}")


COMPUTED_COLUMN_DEPENDENCIES = {
    "decode-ep": set(),
    "concurrency-per-card": {"max-request-concurrency"},
    "input-length": {"total-input-tokens", "successful-requests"},
    "output-length": {"total-generated-tokens", "successful-requests"},
    "prefill-throughput-per-card": {"input-token-throughput"},
    "decode-throughput-per-card": {"output-token-throughput"},
    "decode-throughput-per-card-total": {"total-token-throughput"},
}


def canonicalize_name(name: str) -> str:
    return name.strip().casefold().replace("_", "-")


def stringify_param_value(value: object) -> str:
    if isinstance(value, bool):
        return "ON" if value else "OFF"
    return str(value)


def parse_mtp_arg(value: str) -> int:
    normalized_value = value.strip().casefold()
    if normalized_value == "off":
        return 0

    try:
        parsed_value = int(normalized_value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"Invalid mtp value: {value}. Expected one of off/0/1/2/3"
        ) from exc

    if parsed_value not in {0, 1, 2, 3}:
        raise argparse.ArgumentTypeError(
            f"Invalid mtp value: {value}. Expected one of off/0/1/2/3"
        )

    return parsed_value


def format_mtp_value(value: int) -> str:
    if value in {0, 1}:
        return "off"
    return str(value)


def parse_bool_arg(value: str | None) -> bool:
    if value is None:
        return True

    normalized_value = value.strip().casefold()
    if normalized_value in {"1", "true", "t", "yes", "y", "on"}:
        return True
    if normalized_value in {"0", "false", "f", "no", "n", "off"}:
        return False

    raise argparse.ArgumentTypeError(
        f"Invalid boolean value: {value}. Expected one of True/False/ON/OFF/1/0"
    )


def try_get_source_text(ctx: EvalContext, source_key: str) -> str | None:
    header_name = ctx.source_headers.get(source_key)
    if header_name is None:
        return None
    return ctx.row.get(header_name, "")


def get_source_text(ctx: EvalContext, source_key: str) -> str:
    value = try_get_source_text(ctx, source_key)
    if value is None:
        raise SystemExit(f"Source column is not available: {source_key}")
    return value


def get_source_float(ctx: EvalContext, source_key: str) -> float:
    return to_float(get_source_text(ctx, source_key), source_key)


def to_float(value: object, field_name: str = "") -> float:
    try:
        return float(str(value))
    except ValueError as exc:
        suffix = f" for {field_name}" if field_name else ""
        raise SystemExit(f"Invalid numeric value{suffix}: {value}") from exc


def divide_float(numerator: float, denominator: float) -> str:
    if denominator == 0:
        raise SystemExit("Division by zero while computing derived columns")
    return str(numerator / denominator)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Extract selected columns from a benchmark CSV and append the original row "
            "after a configurable number of empty separator columns."
        )
    )
    parser.add_argument(
        "--columns",
        default=DEFAULT_COLUMNS,
        help=(
            "Comma-separated logical column names, for example: "
            f"prefills,decode-ep,prefill-chunk,prompts,time. Default: {DEFAULT_COLUMNS}"
        ),
    )
    parser.add_argument(
        "input_file",
        nargs="?",
        default="-",
        help="Input CSV file path. Use '-' or omit it to read from stdin.",
    )
    parser.add_argument("--prefills", type=int, default=1, help="Prefill instance count.")
    parser.add_argument(
        "--prefill-cards", type=int, default=16, help="GPU cards per prefill instance."
    )
    parser.add_argument("--decodes", type=int, default=1, help="Decode instance count.")
    parser.add_argument(
        "--decode-cards", type=int, default=32, help="GPU cards per decode instance."
    )
    parser.add_argument(
        "--prefill-chunk-size",
        type=int,
        required=True,
        help="Prefill chunk size used for the run.",
    )
    parser.add_argument(
        "--tbo",
        nargs="?",
        const=True,
        default=False,
        type=parse_bool_arg,
        help="Bool flag. Accepts --tbo/--tbo True/--tbo False. Output uses ON/OFF.",
    )
    parser.add_argument(
        "--disable-graph",
        nargs="?",
        const=True,
        default=False,
        type=parse_bool_arg,
        help="Bool flag. Accepts --disable-graph/--disable-graph True/--disable-graph False.",
    )
    parser.add_argument(
        "--mtp",
        type=parse_mtp_arg,
        default=2,
        help="Accepts off/0/1/2/3. Values 0 and 1 are normalized to off in output.",
    )
    parser.add_argument(
        "--padding-columns",
        type=int,
        default=2,
        help="Number of empty separator columns inserted between extracted and original data.",
    )
    parser.add_argument(
        "--keep-even-rows",
        action="store_true",
        help="Drop odd-numbered data rows and keep only even-numbered data rows.",
    )
    args = parser.parse_args()

    if args.padding_columns < 0:
        parser.error("--padding-columns must be >= 0")

    if args.prefills <= 0:
        parser.error("--prefills must be > 0")

    if args.prefill_cards <= 0:
        parser.error("--prefill-cards must be > 0")

    if args.decodes <= 0:
        parser.error("--decodes must be > 0")

    if args.decode_cards <= 0:
        parser.error("--decode-cards must be > 0")

    if args.prefill_chunk_size <= 0:
        parser.error("--prefill-chunk-size must be > 0")

    return args


if __name__ == "__main__":
    main()
