#!/bin/bash
# 快速开始 - 一键追踪内核启动

echo "=========================================="
echo "内核启动追踪 - 快速开始"
echo "=========================================="
echo ""
echo "本脚本将自动完成以下步骤："
echo "1. 设置追踪环境"
echo "2. 启动 QEMU 并追踪内核启动"
echo "3. 提示如何保存和查看结果"
echo ""
read -p "按 Enter 开始，或 Ctrl+C 取消..."

# 设置环境
echo ""
echo "[1/2] 设置追踪环境..."
./trace_kernel_boot.sh setup

echo ""
echo "[2/2] 启动 QEMU 追踪..."
echo ""
echo "=========================================="
echo "重要提示："
echo "=========================================="
echo ""
echo "QEMU 启动后，请在控制台中执行："
echo ""
echo "    /trace_boot_init.sh"
echo ""
echo "这将保存追踪数据到 /tmp/ 目录"
echo ""
echo "查看追踪结果："
echo "    cat /tmp/boot_trace_full.txt | less"
echo "    cat /tmp/boot_trace_key_functions.txt"
echo ""
echo "退出 QEMU："
echo "    按 Ctrl+A 然后按 X"
echo "    或输入: poweroff"
echo ""
echo "=========================================="
echo ""
read -p "按 Enter 启动 QEMU..."

./trace_kernel_boot.sh ftrace
