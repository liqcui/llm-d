import argparse
import asyncio
import itertools
import time
import uvicorn

from fastapi import FastAPI, HTTPException
from typing import Tuple

# 创建一个从 1 开始的无限递增计数器
counter = itertools.count(start=1)

class ServiceRank:
    def __init__(self):
        self.main_ip = ""
        self.ip_rank = {}
        self.mutex = asyncio.Lock()
        self.main_ip_ready = asyncio.Event()

    async def get_rank(self, ip: str) -> Tuple[str, int]:
        async with self.mutex:
            if ip not in self.ip_rank:
                if not self.main_ip:
                    self.main_ip = ip
                    self.main_ip_ready.set()
                self.ip_rank[ip] = len(self.ip_rank)
            return self.main_ip, self.ip_rank[ip]

    async def get_main_ip(self) -> str:
        await self.main_ip_ready.wait()
        return self.main_ip

class Context:
    def __init__(self, timestamp_ms: int, profile_dir: str):
        self.timestamp_ms = timestamp_ms
        self.profile_dir = profile_dir

        self.prefill = ServiceRank()
        self.decode = ServiceRank()

app_context: Context = None

app = FastAPI()
@app.get("/config")
async def get_config(service: str, ip: str):
    res = {
        "type": service
    }
    if service == "prefill":
        main_ip, rank = await app_context.prefill.get_rank(ip)
        res["main_ip"] = main_ip
        res["rank"] = rank
    elif service == "decode":
        main_ip, rank = await app_context.decode.get_rank(ip)
        res["main_ip"] = main_ip
        res["rank"] = rank
    elif service == "minilb":
        res["prefill"] = await app_context.prefill.get_main_ip()
        res["decode"] = await app_context.decode.get_main_ip()
    else:
        raise HTTPException(status_code=400, detail=f"Invalid service type: {service}")

    if app_context.timestamp_ms:
        res["timestamp_ms"] = app_context.timestamp_ms
    if app_context.profile_dir:
        res["profile_dir"] = app_context.profile_dir
    return res

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--host",
        type=str,
        default="0.0.0.0",
        help="Host IP address to bind the service",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8000,
        help="Port number to bind the service",
    )
    parser.add_argument(
        "--timestamp-ms",
        type=int,
        default=int(time.time() * 1000),
        help="Timestamp in milliseconds for synchronization",
    )
    parser.add_argument(
        "--profile-dir",
        type=str,
        default="",
        help="Directory for profile data",
    )
    args = parser.parse_args()
    return args

if __name__ == "__main__":
    args = parse_args()
    app_context = Context(timestamp_ms=args.timestamp_ms, profile_dir=args.profile_dir)
    uvicorn.run(app, host=args.host, port=args.port)
