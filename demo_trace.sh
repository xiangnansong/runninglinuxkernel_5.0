#!/bin/bash
# 快速演示脚本 - 展示如何使用内核启动追踪工具

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================"
echo "内核启动追踪工具 - 快速演示"
echo "========================================"
echo ""

echo "本演示将展示如何追踪内核启动过程的函数调用"
echo ""

# 步骤 1
echo "步骤 1: 设置追踪环境"
echo "----------------------------------------"
echo "运行命令: ./trace_kernel_boot.sh setup"
echo ""
read -p "按 Enter 继续..."
./trace_kernel_boot.sh setup
echo ""

# 步骤 2
echo "步骤 2: 查看内核配置"
echo "----------------------------------------"
echo "检查 ftrace 配置是否启用..."
echo ""
grep -E "CONFIG_FTRACE=|CONFIG_FUNCTION_TRACER=|CONFIG_FUNCTION_GRAPH_TRACER=" .config
echo ""
echo "✓ 内核配置正确"
echo ""
read -p "按 Enter 继续..."

# 步骤 3
echo "步骤 3: 启动追踪"
echo "----------------------------------------"
echo "现在将启动 QEMU 并开始追踪内核启动过程"
echo ""
echo "启动后，请在 QEMU 控制台中执行以下命令："
echo ""
echo "  /trace_boot_init.sh"
echo ""
echo "这将保存追踪数据到 /tmp/ 目录"
echo ""
echo "要退出 QEMU，按 Ctrl+A 然后按 X"
echo ""
read -p "按 Enter 启动 QEMU..."

# 启动 QEMU（用户需要手动退出）
./trace_kernel_boot.sh ftrace

echo ""
echo "========================================"
echo "演示完成"
echo "========================================"
echo ""
echo "下一步："
echo "1. 如果已保存追踪数据，可以分析结果："
echo "   ./trace_kernel_boot.sh analyze"
echo ""
echo "2. 查看详细文档："
echo "   cat TRACE_KERNEL_BOOT_README.md"
echo ""
echo "3. 清理追踪输出："
echo "   ./trace_kernel_boot.sh clean"
echo ""
