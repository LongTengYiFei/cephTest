#!/bin/bash
# 脚本说明：
# 在每块 NVMe 盘上直接创建 OSD（不使用分区）
# 使用条件：
# 必须是全新集群，且盘已清理（wipefs等）

set -e

# 设置环境变量
export PYTHONPATH=/home/cyf/ceph-dpu/src/pybind
export LD_LIBRARY_PATH=/usr/local/lib/ceph/dpu

# 检查参数
if [ $# -ne 1 ]; then
    echo "用法: $0 <nvme范围>"
    echo "示例: $0 0-3"
    echo "示例: $0 0-2"
    echo "示例: $0 1-3"
    exit 1
fi

# 解析参数范围
range="$1"
if [[ ! "$range" =~ ^[0-9]+-[0-9]+$ ]]; then
    echo "错误: 参数格式不正确，请使用 '起始编号-结束编号' 格式"
    echo "示例: 0-3"
    exit 1
fi

# 提取起始和结束编号
start_num=$(echo "$range" | cut -d'-' -f1)
end_num=$(echo "$range" | cut -d'-' -f2)

# 验证范围有效性
if [ "$start_num" -gt "$end_num" ]; then
    echo "错误: 起始编号不能大于结束编号"
    exit 1
fi

echo "==== 将在 NVMe 设备 $start_num-$end_num 上创建 OSD ===="

# 遍历指定范围的NVMe设备
for ((i=start_num; i<=end_num; i++)); do
    device="/dev/nvme${i}n1"
    if [ -b "$device" ]; then
        echo "==== 准备在整盘创建 OSD: $device ===="
        if ceph-volume raw prepare --bluestore --data "$device"; then
            echo "✅ 成功为 $device 创建 OSD"
        else
            echo "❌ 为 $device 创建 OSD 失败"
        fi
    else
        echo "设备 $device 不存在，跳过"
    fi
done

echo "==== NVMe 设备 $start_num-$end_num OSD 创建完成 ===="