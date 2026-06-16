#!/bin/bash

# ============ 配置 ============
CEPH_BIN="/home/cyf/githubDownload/ceph/build/bin"
SSH_PORT=23579

# 每个节点一个 OSD：三块 SSD 分别对应 data, block.db, block.wal
# 注意：下标 0 是 data，不参与 host write 分子统计
#      下标 1 是 block.db，对应 bluefs.bytes_written_sst
#      下标 2 是 block.wal，对应 bluefs.bytes_written_wal

node1_ip="localhost"
node1_osd_id=0
node1_ssds=("nvme0n1" "nvme1n1" "nvme2n1")

node2_ip="10.26.57.55"
node2_osd_id=1
node2_ssds=("nvme1n1" "nvme2n1" "nvme3n1")

node3_ip="10.26.57.56"
node3_osd_id=2
node3_ssds=("nvme1n1" "nvme2n1" "nvme3n1")

node4_ip="10.26.57.57"
node4_osd_id=3
node4_ssds=("nvme1n1" "nvme2n1" "nvme3n1")

# 测试参数
concurrent_writers=16
single_object_sizes=(1024 32768 1048576)
run_times=3

# 模式选择: "fixed_data" / "fixed_objects"
#   fixed_data   - 固定总数据量 TOTAL_DATA_MB，对象数随 object size 变化
#                  大对象→对象少  小对象→对象多（不适合元数据WA对比测试）
#   fixed_objects- 固定每线程对象数 FIXED_OBJECTS_PER_WRITER，总数据量随 object size 变化
#                  各object size 下对象数一致，元数据量公平对比（适合元数据WA测试）
MODE="fixed_objects"

# fixed_data 模式参数
TOTAL_DATA_MB=16384

# fixed_objects 模式参数
FIXED_OBJECTS_PER_WRITER=4096

POOL="test-pool"
REPLICA_SIZE=3

RESULT_FILE="bluefs_to_block_wa_results_$(date +%Y%m%d_%H%M%S).csv"

echo "对象大小(KB),运行次数,用户写入(MB),DB_host写入(MB),BlueFS_SST写入(MB),DB_BlueFS_to_block_WA,WAL_host写入(MB),BlueFS_WAL写入(MB),WAL_BlueFS_to_block_WA,BlueFS_slow写入(MB),对象数量,实际总数据量(MB)" > "$RESULT_FILE"


# ============ 基础函数 ============

run_cmd_on_node() {
    local node=$1
    local cmd=$2

    if [ "$node" == "localhost" ]; then
        bash -c "$cmd"
    else
        ssh -p "$SSH_PORT" "$node" "$cmd"
    fi
}

# 获取单个 SSD 的累计 host writes，单位 MB
# 使用 /sys/block/<dev>/stat 第 7 个字段 written sectors × 512
get_ssd_writes_mb() {
    local node=$1
    local ssd=$2
    local sectors

    sectors=$(run_cmd_on_node "$node" "cat /sys/block/$ssd/stat 2>/dev/null | awk '{print \$7}'" 2>/dev/null)

    if [ -z "$sectors" ]; then
        echo "0"
    else
        echo "scale=6; $sectors * 512 / 1024 / 1024" | bc
    fi
}

# 获取某个 OSD 的 perf dump 中 bluefs 指标，单位 MB
# counter_name 可以是 bytes_written_sst / bytes_written_wal / bytes_written_slow
get_bluefs_counter_mb() {
    local node=$1
    local osd_id=$2
    local counter_name=$3
    local bytes

    if [ "$node" == "localhost" ]; then
        bytes=$(sudo "$CEPH_BIN"/ceph daemon osd."$osd_id" perf dump 2>/dev/null \
            | sed -n '/^{/,$p' \
            | jq -r ".bluefs.${counter_name} // 0")
    else
        bytes=$(ssh -p "$SSH_PORT" "$node" "sudo $CEPH_BIN/ceph daemon osd.$osd_id perf dump 2>/dev/null" \
            | sed -n '/^{/,$p' \
            | jq -r ".bluefs.${counter_name} // 0")
    fi

    if [ -z "$bytes" ] || [ "$bytes" == "null" ]; then
        echo "0"
    else
        echo "scale=6; $bytes / 1024 / 1024" | bc
    fi
}


# ============ host writes：只统计 DB/WAL SSD，不统计 data SSD ============

record_db_host_writes_sum() {
    local total=0
    local writes

    writes=$(get_ssd_writes_mb "$node1_ip" "${node1_ssds[1]}")
    total=$(echo "scale=6; $total + $writes" | bc)

    writes=$(get_ssd_writes_mb "$node2_ip" "${node2_ssds[1]}")
    total=$(echo "scale=6; $total + $writes" | bc)

    writes=$(get_ssd_writes_mb "$node3_ip" "${node3_ssds[1]}")
    total=$(echo "scale=6; $total + $writes" | bc)

    writes=$(get_ssd_writes_mb "$node4_ip" "${node4_ssds[1]}")
    total=$(echo "scale=6; $total + $writes" | bc)

    echo "$total"
}

record_wal_host_writes_sum() {
    local total=0
    local writes

    writes=$(get_ssd_writes_mb "$node1_ip" "${node1_ssds[2]}")
    total=$(echo "scale=6; $total + $writes" | bc)

    writes=$(get_ssd_writes_mb "$node2_ip" "${node2_ssds[2]}")
    total=$(echo "scale=6; $total + $writes" | bc)

    writes=$(get_ssd_writes_mb "$node3_ip" "${node3_ssds[2]}")
    total=$(echo "scale=6; $total + $writes" | bc)

    writes=$(get_ssd_writes_mb "$node4_ip" "${node4_ssds[2]}")
    total=$(echo "scale=6; $total + $writes" | bc)

    echo "$total"
}


# ============ BlueFS counters：统计所有 OSD 的 bytes_written_sst/wal ============

record_bluefs_sst_sum() {
    local total=0
    local v

    v=$(get_bluefs_counter_mb "$node1_ip" "$node1_osd_id" "bytes_written_sst")
    total=$(echo "scale=6; $total + $v" | bc)

    v=$(get_bluefs_counter_mb "$node2_ip" "$node2_osd_id" "bytes_written_sst")
    total=$(echo "scale=6; $total + $v" | bc)

    v=$(get_bluefs_counter_mb "$node3_ip" "$node3_osd_id" "bytes_written_sst")
    total=$(echo "scale=6; $total + $v" | bc)

    v=$(get_bluefs_counter_mb "$node4_ip" "$node4_osd_id" "bytes_written_sst")
    total=$(echo "scale=6; $total + $v" | bc)

    echo "$total"
}

record_bluefs_wal_sum() {
    local total=0
    local v

    v=$(get_bluefs_counter_mb "$node1_ip" "$node1_osd_id" "bytes_written_wal")
    total=$(echo "scale=6; $total + $v" | bc)

    v=$(get_bluefs_counter_mb "$node2_ip" "$node2_osd_id" "bytes_written_wal")
    total=$(echo "scale=6; $total + $v" | bc)

    v=$(get_bluefs_counter_mb "$node3_ip" "$node3_osd_id" "bytes_written_wal")
    total=$(echo "scale=6; $total + $v" | bc)

    v=$(get_bluefs_counter_mb "$node4_ip" "$node4_osd_id" "bytes_written_wal")
    total=$(echo "scale=6; $total + $v" | bc)

    echo "$total"
}

record_bluefs_slow_sum() {
    local total=0
    local v

    v=$(get_bluefs_counter_mb "$node1_ip" "$node1_osd_id" "bytes_written_slow")
    total=$(echo "scale=6; $total + $v" | bc)

    v=$(get_bluefs_counter_mb "$node2_ip" "$node2_osd_id" "bytes_written_slow")
    total=$(echo "scale=6; $total + $v" | bc)

    v=$(get_bluefs_counter_mb "$node3_ip" "$node3_osd_id" "bytes_written_slow")
    total=$(echo "scale=6; $total + $v" | bc)

    v=$(get_bluefs_counter_mb "$node4_ip" "$node4_osd_id" "bytes_written_slow")
    total=$(echo "scale=6; $total + $v" | bc)

    echo "$total"
}


# ============ Ceph pool 操作 ============

create_replicated_pool() {
    echo "创建副本池 $POOL (副本数: $REPLICA_SIZE) ..."

    "$CEPH_BIN"/ceph osd pool create "$POOL" 32 32 replicated 2>/dev/null
    sleep 3

    "$CEPH_BIN"/ceph osd pool set "$POOL" size "$REPLICA_SIZE"
    sleep 1

    echo "  副本池创建完成 (size=$REPLICA_SIZE)"
}

delete_pool() {
    echo "删除测试池 $POOL ..."
    "$CEPH_BIN"/ceph config set mon mon_allow_pool_delete true
    "$CEPH_BIN"/ceph osd pool delete "$POOL" "$POOL" --yes-i-really-really-mean-it 2>/dev/null
    "$CEPH_BIN"/ceph config set mon mon_allow_pool_delete false
    echo "  测试池已删除"
    sleep 2
}


# ============ workload 参数 ============

calculate_objects_per_writer() {
    local obj_size=$1

    if [ "$MODE" = "fixed_objects" ]; then
        # 固定每线程对象数，总数据量随之变化（适合元数据 WA 对比）
        echo "$FIXED_OBJECTS_PER_WRITER"
    else
        # 固定总数据量，对象数随之变化
        local total_data_bytes=$((TOTAL_DATA_MB * 1024 * 1024))
        local total_objects=$((total_data_bytes / obj_size))

        if [ "$total_objects" -lt 1 ]; then
            total_objects=1
        fi

        local objects_per_writer=$((total_objects / concurrent_writers))

        if [ "$objects_per_writer" -lt 1 ]; then
            objects_per_writer=1
        fi

        echo "$objects_per_writer"
    fi
}


# ============ 单次测试 ============

run_single_test() {
    local obj_size=$1
    local run_num=$2

    local objects_per_writer
    local total_objects
    local total_data_mb
    local total_data_gb

    objects_per_writer=$(calculate_objects_per_writer "$obj_size")
    total_objects=$((concurrent_writers * objects_per_writer))
    total_data_mb=$((total_objects * obj_size / 1024 / 1024))
    total_data_gb=$(echo "scale=2; $total_data_mb / 1024" | bc)

    echo ""
    echo "=========================================="
    echo "测试: 对象大小 = $((obj_size / 1024)) KB, 第 $run_num 次"
    echo "=========================================="
    echo "  每线程对象数: $objects_per_writer"
    echo "  总对象数: $total_objects"
    echo "  用户写入量: $total_data_mb MB ($total_data_gb GB)"
    if [ "$MODE" = "fixed_objects" ]; then
        echo "  说明: 固定对象数模式，总数据量随 object size 变化"
    else
        echo "  说明: 固定数据量模式，对象数随 object size 变化（注意元数据量不一致）"
    fi
    echo "  注意: 用户写入量只记录，不作为 WA 分母"

    # bench 前：host writes
    local start_db_host
    local start_wal_host

    start_db_host=$(record_db_host_writes_sum)
    start_wal_host=$(record_wal_host_writes_sum)

    # bench 前：BlueFS logical writes
    local start_bluefs_sst
    local start_bluefs_wal
    local start_bluefs_slow

    start_bluefs_sst=$(record_bluefs_sst_sum)
    start_bluefs_wal=$(record_bluefs_wal_sum)
    start_bluefs_slow=$(record_bluefs_slow_sum)

    echo "  初始 DB host writes:        $start_db_host MB"
    echo "  初始 WAL host writes:       $start_wal_host MB"
    echo "  初始 BlueFS SST writes:     $start_bluefs_sst MB"
    echo "  初始 BlueFS WAL writes:     $start_bluefs_wal MB"
    echo "  初始 BlueFS slow writes:    $start_bluefs_slow MB"

    echo "  写入测试中..."
    local time_seconds=120

    "$CEPH_BIN"/rados bench -p "$POOL" "$time_seconds" write \
        -b "$obj_size" \
        -t "$concurrent_writers" \
        --max-objects "$total_objects" \
        --no-cleanup > /dev/null 2>&1

    echo "  等待 10 秒，等待后台写入相对稳定..."
    sleep 10

    # bench 后：host writes
    local end_db_host
    local end_wal_host

    end_db_host=$(record_db_host_writes_sum)
    end_wal_host=$(record_wal_host_writes_sum)

    # bench 后：BlueFS logical writes
    local end_bluefs_sst
    local end_bluefs_wal
    local end_bluefs_slow

    end_bluefs_sst=$(record_bluefs_sst_sum)
    end_bluefs_wal=$(record_bluefs_wal_sum)
    end_bluefs_slow=$(record_bluefs_slow_sum)

    echo "  最终 DB host writes:        $end_db_host MB"
    echo "  最终 WAL host writes:       $end_wal_host MB"
    echo "  最终 BlueFS SST writes:     $end_bluefs_sst MB"
    echo "  最终 BlueFS WAL writes:     $end_bluefs_wal MB"
    echo "  最终 BlueFS slow writes:    $end_bluefs_slow MB"

    # delta
    local delta_db_host
    local delta_wal_host
    local delta_bluefs_sst
    local delta_bluefs_wal
    local delta_bluefs_slow

    delta_db_host=$(echo "scale=6; $end_db_host - $start_db_host" | bc)
    delta_wal_host=$(echo "scale=6; $end_wal_host - $start_wal_host" | bc)

    delta_bluefs_sst=$(echo "scale=6; $end_bluefs_sst - $start_bluefs_sst" | bc)
    delta_bluefs_wal=$(echo "scale=6; $end_bluefs_wal - $start_bluefs_wal" | bc)
    delta_bluefs_slow=$(echo "scale=6; $end_bluefs_slow - $start_bluefs_slow" | bc)

    # WA = host writes / BlueFS logical writes
    local db_wa
    local wal_wa

    if [ "$(echo "$delta_bluefs_sst == 0" | bc)" -eq 1 ]; then
        db_wa="N/A"
    else
        db_wa=$(echo "scale=6; $delta_db_host / $delta_bluefs_sst" | bc)
    fi

    if [ "$(echo "$delta_bluefs_wal == 0" | bc)" -eq 1 ]; then
        wal_wa="N/A"
    else
        wal_wa=$(echo "scale=6; $delta_wal_host / $delta_bluefs_wal" | bc)
    fi

    echo ""
    echo "  ===== 本次结果 ====="
    echo "  DB host writes delta:       $delta_db_host MB"
    echo "  BlueFS SST writes delta:    $delta_bluefs_sst MB"
    echo "  DB BlueFS-to-block WA:      $db_wa"

    echo "  WAL host writes delta:      $delta_wal_host MB"
    echo "  BlueFS WAL writes delta:    $delta_bluefs_wal MB"
    echo "  WAL BlueFS-to-block WA:     $wal_wa"

    echo "  BlueFS slow writes delta:   $delta_bluefs_slow MB"
    if [ "$(echo "$delta_bluefs_slow > 0" | bc)" -eq 1 ]; then
        echo "  警告: BlueFS slow 写入增长，说明可能有 DB/WAL 文件 spill 到 data 盘。"
    fi

    echo "$((obj_size / 1024)),$run_num,$total_data_mb,$delta_db_host,$delta_bluefs_sst,$db_wa,$delta_wal_host,$delta_bluefs_wal,$wal_wa,$delta_bluefs_slow,$total_objects,$total_data_mb" >> "$RESULT_FILE"
}


# ============ 主流程 ============

echo "=========================================="
echo "Ceph BlueFS-to-block-layer 写放大测试"
echo "=========================================="
echo ""
echo "测试配置:"
echo "  池类型: 副本池 (副本数: $REPLICA_SIZE)"
echo "  并发写线程: $concurrent_writers"
echo "  对象大小列表: ${single_object_sizes[*]}"
echo "  每个大小测试次数: $run_times"
if [ "$MODE" = "fixed_objects" ]; then
    echo "  模式: 固定对象数 (每线程 ${FIXED_OBJECTS_PER_WRITER} 对象)"
else
    echo "  模式: 固定数据量 (${TOTAL_DATA_MB} MB)"
fi
echo ""
echo "OSD/SSD 映射:"
echo "  node1 osd.$node1_osd_id data=${node1_ssds[0]}, block.db=${node1_ssds[1]}, block.wal=${node1_ssds[2]}"
echo "  node2 osd.$node2_osd_id data=${node2_ssds[0]}, block.db=${node2_ssds[1]}, block.wal=${node2_ssds[2]}"
echo "  node3 osd.$node3_osd_id data=${node3_ssds[0]}, block.db=${node3_ssds[1]}, block.wal=${node3_ssds[2]}"
echo "  node4 osd.$node4_osd_id data=${node4_ssds[0]}, block.db=${node4_ssds[1]}, block.wal=${node4_ssds[2]}"
echo ""
echo "核心指标:"
echo "  DB WA  = ΔDB host writes  / ΣΔbluefs.bytes_written_sst"
echo "  WAL WA = ΔWAL host writes / ΣΔbluefs.bytes_written_wal"
echo ""
echo "结果将保存到: $RESULT_FILE"
echo ""

create_replicated_pool

for obj_size in "${single_object_sizes[@]}"; do
    echo ""
    echo "=========================================="
    echo "开始测试对象大小: $((obj_size / 1024)) KB"
    echo "=========================================="

    for run in $(seq 1 "$run_times"); do
        run_single_test "$obj_size" "$run"
    done
done

echo ""
echo "=========================================="
echo "清理测试数据..."
echo "=========================================="
delete_pool

echo ""
echo "=========================================="
echo "测试完成！结果汇总"
echo "=========================================="
echo ""
cat "$RESULT_FILE"
echo ""
echo "结果已保存到: $RESULT_FILE"