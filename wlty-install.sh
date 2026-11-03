#!/bin/bash
# ==============================================================================
# WLTY 一键安装器
# ------------------------------------------------------------------------------
#  用法: curl -fsSL <本文件 raw 链接> | sudo bash
#        （或 sudo bash -c "$(curl -fsSL <本文件 raw 链接>)"，装完自动打开面板）
#
#  安装后命令: sudo wlty   （0 体检 / 1 调优 / 2 删除 / 3 回程 / 4 退出）
# ==============================================================================
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "请使用 root 运行: curl -fsSL <链接> | sudo bash"; exit 1; }

# 脚本本体地址: 默认 GitHub raw，可用环境变量覆盖 (如 Gitee/对象存储)
SRC="${WLTY_SRC:-https://raw.githubusercontent.com/890890-bot/UDP/main/wlty.sh}"
DEST="/usr/local/bin/wlty"

echo "▶ 正在下载: $SRC"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if ! curl -fsSL --retry 3 -m 60 "$SRC" -o "$TMP"; then
    echo "✗ 下载失败, 请检查地址是否可访问: $SRC"
    exit 1
fi

SZ=$(wc -c < "$TMP")
if (( SZ < 30000 )); then
    echo "✗ 下载内容异常 (仅 ${SZ} 字节), 可能拿到的是 404 页面"
    exit 1
fi

# 安装前先做语法校验, 防止装坏
if ! bash -n "$TMP"; then
    echo "✗ 脚本语法校验失败, 已放弃安装"
    exit 1
fi

install -m 0755 "$TMP" "$DEST"
echo "✔ 安装完成: $DEST"
echo "▶ 启动面板: sudo wlty"

# 交互式终端 (如 sudo bash -c "$(curl ...)") 则安装后直接打开面板
if [[ -t 0 && -t 1 ]]; then
    exec "$DEST"
fi
