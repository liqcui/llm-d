import datetime
import numpy as np
import re

from collections import defaultdict
from tabulate import tabulate
from tqdm import tqdm


def main():
    args = parse_args()
    keys = set()
    analyst = Analyst()
    for line in read_all_lines(args):
        line = parse_line(line)
        keys |= line.keys()
        analyst.add(line)
    if args.print_only:
        return
    print(f"keys: {sorted(keys)}")
    print(f"{len(analyst.by_room_id)=}")
    all_requests = list(analyst.by_room_id.values())

    def duration(start_key: str, end_key: str):
        res = []
        for req in all_requests:
            if start_key in req and end_key in req:
                val = (req[end_key] - req[start_key]).total_seconds() * 1000
                res.append(val)
        return np.array(res)

    m2p_req = duration("mini_lb_start", "prefill_server_recv")
    d2m_req = duration("decode_transfer_pop", "mini_lb_first")

    all_data = [[
        ("ttft_sglang", [req["ttft"] * 1000 for req in all_requests if "ttft" in req], 0),
        ("ttft_minilb", duration("mini_lb_start", "mini_lb_first"), 0),
    ]]

    # tb_d2p_trans_kv = duration("prealloc_pop", "prefill_recv_kv_args")
    # tb_d2p_trans_kv_register_t1 = duration("decode_register_kv_args", "prefill_register_kv_args")
    # tb_d_trans_kv_args_lock_t1 = duration("decode_send_kv_args", "decode_send_kv_args_locked")
    # tb_d2p_trans_kv_args_net_t1 = duration("decode_send_kv_args_locked", "prefill_recv_kv_args_net")
    # tb_p_trans_kv_args_post_t1 = duration("prefill_recv_kv_args_net", "prefill_recv_kv_args")


    for pp_rank in range(args.pp_size):
        # Prefill PP
        data = [
            [f"ttft_pp{pp_rank}", [], 0],
            ("m2p-req", m2p_req),
            ("p2dp-req", duration("prefill_server_recv", f"bootstrap_add_pp{pp_rank}")),
            ("bootstrap", duration(f"bootstrap_add_pp{pp_rank}", f"bootstrap_pop_pp{pp_rank}")),
            ("bootstrap-kv-args", duration(f"bootstrap_add_pp{pp_rank}", f"prefill_recv_kv_args_pp{pp_rank}"), 2),
            ("bootstrap-kv-args-register", duration(f"bootstrap_add_pp{pp_rank}", f"prefill_register_kv_args_pp{pp_rank}"), 3),
            ("bootstrap-kv-args-recv", duration(f"prefill_register_kv_args_pp{pp_rank}", f"prefill_recv_kv_args_pp{pp_rank}"), 3),
            ("forward-wait", duration(f"bootstrap_pop_pp{pp_rank}", f"prefill_forward_start_pp{pp_rank}")),
            ("forward", duration(f"prefill_forward_start_pp{pp_rank}", f"prefill_forward_post_send_pp{pp_rank}")),
            ("forward-post", duration(f"prefill_forward_post_send_pp{pp_rank}", f"prefill_forward_end_pp{pp_rank}")),
            ("p2d-kv", duration(f"prefill_forward_end_pp{pp_rank}", "decode_transfer_pop")),
            ("p2d-kv-1", duration(f"prefill_forward_end_pp{pp_rank}", f"prefill_p2d_kv_send_done_pp{pp_rank}"), 2),
            ("p2d-kv-2", duration(f"prefill_p2d_kv_send_done_pp{pp_rank}", f"prefill_p2d_kv_transfer_start_pp{pp_rank}"), 2),
            ("p2d-kv-3", duration(f"prefill_p2d_kv_transfer_start_pp{pp_rank}", f"prefill_p2d_kv_transfer_end_pp{pp_rank}"), 2),
            ("p2d-kv-4", duration(f"prefill_p2d_kv_transfer_end_pp{pp_rank}", "decode_p2d_kv_transfer_end"), 2),
            ("p2d-kv-5", duration("decode_p2d_kv_transfer_end", "decode_transfer_pop"), 2),
            (f"d2m-req", d2m_req),
        ]
        data[0][1] = elementwise_sum_or_sum_of_means(list(map(lambda x: x[1], filter(lambda x: get_label_indent(x) == 1 and len(x[1]) > 0, data))))
        all_data.append(data)

    if True:
        # Decode
        data = [
            ["ttft_decode", [], 0],
            ("m2d_req", duration("mini_lb_start", "decode_server_recv")),
            ("d2dp_req", duration("decode_server_recv", "prealloc_add")),
            ("d_prealloc", duration("prealloc_add", "prealloc_pop")),
            ("d_trans_queue", duration("prealloc_pop", "decode_transfer_pop")),
            ("d2m_req", d2m_req),
        ]
        data[0][1] = elementwise_sum_or_sum_of_means(list(map(lambda x: x[1], filter(lambda x: get_label_indent(x) == 1 and len(x[1]) > 0, data))))
        all_data.append(data)

    table_header = ["name", "length", "mean", "p50", "p90", "p95", "p99", "min", "max"]
    table = []
    for (i, data) in enumerate(all_data):
        if i > 0:
            table.append([])
        for item in data:
            indent = "." * get_label_indent(item)
            name, value, *_ = item
            p50, p90, p95, p99 = np.percentile(value if len(value) > 0 else 0, [50, 90, 95, 99])

            table.append([
                f" {indent}{name}",
                len(value),
                np.mean(value) if len(value) > 0 else 0,
                p50,
                p90,
                p95,
                p99,
                np.min(value) if len(value) > 0 else 0,
                np.max(value) if len(value) > 0 else 0,
            ])
    print(tabulate(table, headers=table_header, floatfmt=".1f"))


def elementwise_sum_or_sum_of_means(lists: list[list[float]]) -> list[float]:
    if not lists:
        return [ 0.0 ]
    assert all(isinstance(lst, np.ndarray) for lst in lists), f"All elements must be numpy arrays"
    first_len = len(lists[0])
    is_consistent = all(len(lst) == first_len for lst in lists)

    if is_consistent:
        return sum(lists)
    else:
        return [sum(np.mean(lst) if lst.size > 0 else 0.0 for lst in lists)]


def get_label_indent(data) -> int:
    if not hasattr(data, "__len__"):
        return 0
    if len(data) == 2:
        return 1
    if len(data) == 3:
        assert isinstance(data[2], int), f"{data[2]=}"
        return data[2]
    return 0


class Analyst:
    def __init__(self) -> None:
        self.by_room_id = defaultdict(dict)
        self.by_rid = defaultdict(dict)

    def add(self, data: dict):
        if "room_id" in data and "rid" in data:
            room_id = data["room_id"]
            rid = data["rid"]
            self.by_room_id[room_id] |= self.by_rid[rid]
            self.by_room_id[room_id] |= data
            self.by_rid[rid] = self.by_room_id[room_id]
        elif "room_id" in data:
            room_id = data["room_id"]
            self.by_room_id[room_id] |= data
        elif "rid" in data:
            rid = data["rid"]
            self.by_rid[rid] |= data
        else:
            raise ValueError(f"No room_id or rid in data: {data}")


_PAT_VALUE_NUMBER = re.compile(r"\d+(\.\d*)?")


def parse_line(line: str) -> dict:
    res = {
        "log_dt": parse_datetime(_PAT_DATETIME.search(line)[0]),
    }
    if " room_id: " in line:
        line = line[line.index(" room_id: ") :]
    elif " rid: " in line:
        line = line[line.index(" rid: ") :]
    else:
        raise ValueError(f"No room_id or rid in line: {line}")
    for item in line.split(","):
        pos = item.find(":")
        if pos == -1:
            pos = item.find("=")
            if pos == -1:
                raise ValueError(f"Invalid item: {item}, in '{line}'")
        key = item[:pos].strip()
        value = item[pos + 1 :].strip()

        try:
            if key == "room_id":
                value = int(value)
            elif key == "ttft":
                value = float(_PAT_VALUE_NUMBER.search(value)[0])
            elif key == "rid":
                pass
            else:
                value = parse_datetime(value)
        except Exception as e:
            raise ValueError(f"Failed to parse item: {item}, in '{line}'") from e
        res[key] = value
    return res


def read_all_lines(args):
    for file in tqdm(args.files, desc="Processing files"):
        yield from read_file_lines(file, args)


_PAT_LINE_FILTER = re.compile(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})( |]|\.|,)")


def read_file_lines(file_path: str, args):
    with open(file_path, "r") as file:
        for line in file:
            dt = _PAT_LINE_FILTER.search(line)
            if dt is None:
                continue
            dt = parse_datetime(dt[1])
            if dt < args.since:
                continue
            if dt > args.until:
                return
            if args.print_only:
                print(line.strip())
                continue
            if not (" room_id: " in line or " rid: " in line):
                continue
            yield line.strip()


_PAT_DATETIME = re.compile(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")
_PAT_DATETIME_MS = re.compile(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{1,6})")


def parse_datetime(dt_str: str) -> datetime.datetime:
    if _PAT_DATETIME_MS.match(dt_str):
        return datetime.datetime.strptime(dt_str, "%Y-%m-%d %H:%M:%S.%f")
    if _PAT_DATETIME.match(dt_str):
        return datetime.datetime.strptime(dt_str, "%Y-%m-%d %H:%M:%S")
    raise ValueError(f"Invalid datetime format: {dt_str}")


def parse_args():
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--files", metavar="FILE", type=str, nargs="+", help="List of files to process"
    )
    parser.add_argument(
        "--since",
        metavar="YYYY-MM-DD HH:MM:SS",
        type=str,
        help="Start datetime for filtering logs",
    )
    parser.add_argument(
        "--until",
        metavar="YYYY-MM-DD HH:MM:SS",
        type=str,
        default=datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        help="End datetime for filtering logs",
    )
    parser.add_argument(
        "--print-only",
        action="store_true",
        help="Only print parsed lines without analysis",
    )
    parser.add_argument(
        "--pp-size",
        type=int,
        default=2,
    )
    args = parser.parse_args()
    args.since = parse_datetime(args.since)
    args.until = parse_datetime(args.until)
    return args


if __name__ == "__main__":
    main()
