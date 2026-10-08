#!/bin/bash
# 0731 修复镜像构建脚本 — 0.5.14-maca + DeepSeek-V4-Flash-0731 修复补丁
# 用法: bash build.sh   (在镜像构建机 10-66-2-1 上执行; 构建完自动推送)
set -euo pipefail
cd "$(dirname "$0")"

BASE=harbor.isuanova.com/metax/sglang:0.5.14-maca.ai3.8.2.122-torch2.10-py312-ubuntu22.04-amd64
TAG=harbor.isuanova.com/metax/sglang:0.5.14-maca.ai3.8.2.122-dsv4-0731

echo "== 校验补丁脚本可在 pristine 基础镜像上干净应用 =="
# (构建内已含断言; 这里仅提示)

echo "== docker build (BASE: ${BASE}) =="
docker build -t "${TAG}" .

echo "== docker push =="
docker push "${TAG}"

echo "== done: ${TAG} =="
