#!/bin/bash
# 文件名: test_wamp_cluster.sh
# 用法: ./test_wamp_cluster.sh

# ============ 配置 ============
# Ceph 命令路径
CEPH_BIN="/home/cyf/githubDownload/ceph/build/bin"

# Node1 的 SSD 列表（本机）
node1_ssds=("nvme0n1" "nvme1n1" "nvme2n1" "nvme3n1")

# Node2 的配置
node2_ip="10.26.57.55"
node2_ssds=("nvme0n1" "nvme2n1" "nvme3n1" "nvme4n1")

# 测试参数
concurrent_writers=16
single_object_sizes=(1024 2048 4096 8192 16384  32768 65536 131072 262144 524288 1048576 2097152 4194304)
run_times=3

# ============ 新增配置 ============
# 固定总数据量（单位：MB），例如 512MB
TOTAL_DATA_MB=512

# 或者固定对象数量（根据对象大小自动计算）
# FIXED_OBJECT_COUNT=4096  # 如果希望固定对象数量可以这样配置
# 使用固定数据量模式
USE_FIXED_DATA=true  # true: 固定数据量, false: 固定对象数量

# 测试池
POOL="test-pool"

# ============ 池类型配置 ============
# 池类型: "replicated" 或 "erasure"
POOL_TYPE="replicated"  # 修改这里来选择池类型

# 副本池配置（当 POOL_TYPE="replicated" 时生效）
REPLICA_SIZE=3  # 副本数

# EC 池配置（当 POOL_TYPE="erasure" 时生效）
EC_K=4
EC_M=2
EC_STRIPE_UNIT=4096
EC_PROFILE_NAME="ec42_profile"
EC_RULE_NAME="ec_rule"

# 结果文件
RESULT_FILE="wamp_results_$(date +%Y%m%d_%H%M%S).csv"

# 初始化结果文件
echo "对象大小(KB),运行次数,用户写入(MB),集群写入(MB),写放大倍数,对象数量,实际总数据量(MB),池类型" > $RESULT_FILE

# ============ 函数定义 ============

# 获取单个 SSD 的累计写入量 (MB)
get_ssd_writes_mb() {
    local node=$1
    local ssd=$2
    
    if [ "$node" == "localhost" ]; then
        sectors=$(cat /sys/block/$ssd/stat 2>/dev/null | awk '{print $7}')
        if [ -z "$sectors" ]; then
            echo "0"
        else
            echo "scale=2; $sectors * 512 / 1024 / 1024" | bc
        fi
    else
        sectors=$(ssh -p 23579 $node "cat /sys/block/$ssd/stat 2>/dev/null" 2>/dev/null | awk '{print $7}')
        if [ -z "$sectors" ]; then
            echo "0"
        else
            echo "scale=2; $sectors * 512 / 1024 / 1024" | bc
        fi
    fi
}

# 记录所有 SSD 的累计写入量（返回总和）
record_ssd_writes_sum() {
    local total=0
    
    for ssd in "${node1_ssds[@]}"; do
        writes=$(get_ssd_writes_mb "localhost" "$ssd")
        total=$(echo "scale=2; $total + $writes" | bc)
    done
    
    for ssd in "${node2_ssds[@]}"; do
        writes=$(get_ssd_writes_mb "$node2_ip" "$ssd")
        total=$(echo "scale=2; $total + $writes" | bc)
    done
    
    echo $total
}

# 创建副本池
create_replicated_pool() {
    echo "创建副本池 $POOL (副本数: $REPLICA_SIZE) ..."
    
    # 创建副本池
    $CEPH_BIN/ceph osd pool create $POOL 32 32 replicated
    sleep 3
    
    # 设置副本数
    $CEPH_BIN/ceph osd pool set $POOL size $REPLICA_SIZE
    sleep 1
    
    echo "  副本池创建完成 (size=$REPLICA_SIZE)"
}

# 创建 EC 池
create_erasure_pool() {
    echo "创建 EC ${EC_K}+${EC_M} 测试池 $POOL ..."
    
    # 创建 EC profile（如果不存在）
    if ! $CEPH_BIN/ceph osd erasure-code-profile get $EC_PROFILE_NAME > /dev/null 2>&1; then
        $CEPH_BIN/ceph osd erasure-code-profile set $EC_PROFILE_NAME \
            k=$EC_K m=$EC_M \
            stripe_unit=$EC_STRIPE_UNIT \
            crush-failure-domain=osd
        echo "  EC profile '$EC_PROFILE_NAME' 已创建 (k=$EC_K, m=$EC_M, stripe_unit=${EC_STRIPE_UNIT}KB, failure-domain=osd)"
    fi
    
    # 创建 EC 专用的 crush rule（如果不存在）
    if ! $CEPH_BIN/ceph osd crush rule ls | grep -q "^$EC_RULE_NAME$"; then
        echo "  创建 EC 专用 CRUSH rule '$EC_RULE_NAME' ..."
        $CEPH_BIN/ceph osd crush rule create-erasure $EC_RULE_NAME $EC_PROFILE_NAME
        echo "  CRUSH rule '$EC_RULE_NAME' 已创建"
    fi
    
    # 创建 EC 池
    $CEPH_BIN/ceph osd pool create $POOL 32 32 erasure $EC_PROFILE_NAME $EC_RULE_NAME
    sleep 3
    
    echo "  EC 池创建完成"
}

# 删除测试池
delete_pool() {
    echo "删除测试池 $POOL ..."
    $CEPH_BIN/ceph config set mon mon_allow_pool_delete true
    $CEPH_BIN/ceph osd pool delete $POOL $POOL --yes-i-really-really-mean-it 2>/dev/null
    $CEPH_BIN/ceph config set mon mon_allow_pool_delete false
    echo "  测试池已删除"
    sleep 2
}

# 计算每个 writer 应该写入的对象数量
calculate_objects_per_writer() {
    local obj_size=$1
    
    if [ "$USE_FIXED_DATA" = true ]; then
        # 固定数据量模式：总数据量 / (对象大小 × 并发数)
        local total_data_bytes=$((TOTAL_DATA_MB * 1024 * 1024))
        local obj_size_bytes=$obj_size
        local total_objects=$((total_data_bytes / obj_size_bytes))
        
        # 确保至少有一个对象
        if [ $total_objects -lt 1 ]; then
            total_objects=1
        fi
        
        # 计算每个线程的对象数
        local objects_per_writer=$((total_objects / concurrent_writers))
        
        # 确保每个线程至少有一个对象
        if [ $objects_per_writer -lt 1 ]; then
            objects_per_writer=1
            total_objects=$((concurrent_writers * objects_per_writer))
        else
            # 调整总对象数为并发数的整数倍
            total_objects=$((concurrent_writers * objects_per_writer))
        fi
        
        echo $objects_per_writer
    else
        # 固定对象数量模式：使用固定的每线程对象数
        echo $FIXED_OBJECTS_PER_WRITER
    fi
}

# 运行单次写入测试
run_single_test() {
    local obj_size=$1
    local run_num=$2
    
    # 计算当前对象大小的对象数量
    local objects_per_writer=$(calculate_objects_per_writer $obj_size)
    local total_objects=$((concurrent_writers * objects_per_writer))
    local total_data_mb=$((total_objects * obj_size / 1024 / 1024))
    local total_data_gb=$(echo "scale=2; $total_data_mb / 1024" | bc)
    
    echo ""
    echo "=========================================="
    echo "测试: 对象大小 = $(($obj_size / 1024)) KB, 第 $run_num 次"
    echo "=========================================="
    echo "  每线程对象数: $objects_per_writer"
    echo "  总对象数: $total_objects"
    echo "  总用户写入量: $total_data_mb MB ($total_data_gb GB)"
    
    # 记录初始写入量
    start_total=$(record_ssd_writes_sum)
    echo "  初始集群写入: $start_total MB"
    
    # 运行 rados bench
    echo "  写入测试中..."
    time_seconds=120
    $CEPH_BIN/rados bench -p $POOL $time_seconds write -b $obj_size -t $concurrent_writers --max-objects $total_objects --no-cleanup > /dev/null 2>&1
    
    # 等待落盘
    sleep 10
    
    # 记录最终写入量
    end_total=$(record_ssd_writes_sum)
    echo "  最终集群写入: $end_total MB"
    
    # 计算写放大
    delta=$(echo "scale=2; $end_total - $start_total" | bc)
    amp=$(echo "scale=2; $delta / $total_data_mb" | bc)
    
    echo "  集群实际写入: $delta MB"
    echo "  写放大倍数: $amp"
    
    # 获取池类型名称用于结果记录
    local pool_type_name=""
    if [ "$POOL_TYPE" == "replicated" ]; then
        pool_type_name="副本${REPLICA_SIZE}"
    else
        pool_type_name="EC${EC_K}+${EC_M}"
    fi
    
    # 返回结果
    echo "$(($obj_size / 1024)),$run_num,$total_data_mb,$delta,$amp,$total_objects,$total_data_mb,$pool_type_name" >> $RESULT_FILE
}

# ============ 主流程 ============

echo "=========================================="
echo "Ceph BlueStore 写放大测试"
echo "=========================================="
echo ""
echo "测试配置:"
echo "  池类型: $POOL_TYPE"
if [ "$POOL_TYPE" == "replicated" ]; then
    echo "  副本数: $REPLICA_SIZE"
else
    echo "  EC 配置: ${EC_K}+${EC_M} (stripe_unit=${EC_STRIPE_UNIT})"
fi
echo "  并发写线程: $concurrent_writers"
if [ "$USE_FIXED_DATA" = true ]; then
    echo "  测试模式: 固定数据量 = ${TOTAL_DATA_MB} MB"
else
    echo "  测试模式: 固定对象数量"
fi
echo "  对象大小列表: ${single_object_sizes[@]}"
echo "  每个大小测试次数: $run_times"
echo ""
echo "结果将保存到: $RESULT_FILE"
echo ""

# 根据池类型创建对应的池
if [ "$POOL_TYPE" == "replicated" ]; then
    create_replicated_pool
elif [ "$POOL_TYPE" == "erasure" ]; then
    create_erasure_pool
else
    echo "错误: 不支持的池类型 '$POOL_TYPE'"
    echo "请设置 POOL_TYPE 为 'replicated' 或 'erasure'"
    exit 1
fi

# 循环测试各种对象大小
for obj_size in "${single_object_sizes[@]}"; do
    obj_size_kb=$(($obj_size / 1024))
    echo ""
    echo "=========================================="
    echo "开始测试对象大小: $obj_size_kb KB"
    echo "=========================================="
    
    for run in $(seq 1 $run_times); do
        run_single_test $obj_size $run
    done
done

# 删除测试池
echo ""
echo "=========================================="
echo "清理测试数据..."
echo "=========================================="
delete_pool

# 输出汇总结果
echo ""
echo "=========================================="
echo "测试完成！结果汇总"
echo "=========================================="
echo ""
cat $RESULT_FILE
echo ""
echo "结果已保存到: $RESULT_FILE"