#!/bin/bash
# 多文件同步到多节点，SSH端口23579
# 同步文件有个问题，每个机器的local gid我没法同步，只能手动修改；

dest_ips=("10.26.57.55" "10.26.57.56" "10.26.57.57")
syn_files=("/var/lib/ceph/bootstrap-osd/ceph.keyring"
           "/etc/ceph/ceph.client.admin.keyring")
           #"/etc/ceph/ceph.conf")

ssh_port=23579
user="cyf"

# 遍历节点和文件进行同步
for node in "${dest_ips[@]}"; do
    for file in "${syn_files[@]}"; do
        if [ -f "$file" ]; then
            echo "推送 $file 到 $node:$file"
            scp -P ${ssh_port} "$file" ${user}@${node}:"$file"
            if [ $? -eq 0 ]; then
                echo "✅ 已成功同步 $file 到 $node"
            else
                echo "❌ 同步 $file 到 $node 失败"
            fi
        else
            echo "⚠️ 文件 $file 不存在，跳过"
        fi
    done
done

echo "==== 所有文件同步完成 ===="
