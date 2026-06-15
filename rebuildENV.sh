#!/bin/bash
# 使用前提，ceph conf文件已配置好，已有fsid；

get_fsid() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        echo "错误：文件 '$config_file' 不存在。" >&2
        return 1
    fi
    local fsid
    fsid=$(awk -F' *= *' '/^\s*fsid\s*=/ {print $2; exit}' "$config_file")
    if [[ -z "$fsid" ]]; then
        echo "错误：在文件 '$config_file' 中未找到 'fsid'。" >&2
        return 1
    fi
    echo "$fsid"
}

mon_ip="10.26.57.54"
mon_name="node1"
fsid=$(get_fsid "/etc/ceph/ceph.conf")

rm -fr /var/lib/ceph
mkdir /var/lib/ceph
mkdir /var/lib/ceph/bootstrap-osd
mkdir /var/lib/ceph/mgr
mkdir /var/lib/ceph/osd
mkdir /var/lib/ceph/mon/
mkdir /var/lib/ceph/mon/ceph-$mon_name

rm  /etc/ceph/monmap
rm  /etc/ceph/ceph.mon.keyring
rm  /etc/ceph/ceph.client.admin.keyring

ceph-authtool --create-keyring /etc/ceph/ceph.mon.keyring --gen-key -n mon. --cap mon 'allow *'
ceph-authtool --create-keyring /etc/ceph/ceph.client.admin.keyring --gen-key -n client.admin --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *' --cap mgr 'allow *'
sudo ceph-authtool --create-keyring /var/lib/ceph/bootstrap-osd/ceph.keyring --gen-key -n client.bootstrap-osd --cap mon 'profile bootstrap-osd' --cap mgr 'allow r'

sudo ceph-authtool /etc/ceph/ceph.mon.keyring --import-keyring /etc/ceph/ceph.client.admin.keyring
sudo ceph-authtool /etc/ceph/ceph.mon.keyring --import-keyring /var/lib/ceph/bootstrap-osd/ceph.keyring

monmaptool --create --add $mon_name $mon_ip --fsid $fsid /etc/ceph/monmap

ceph-mon --mkfs -i $mon_name --monmap /etc/ceph/monmap --keyring /etc/ceph/ceph.mon.keyring

chown -R cyf:cyf /var/lib/ceph
chown -R cyf:cyf /etc/ceph

sudo systemctl restart ceph-mon@$mon_name

# 配置mgr
mkdir /var/lib/ceph/mgr/ceph-m1
touch /var/lib/ceph/mgr/ceph-m1/keyring
AUTH_OUTPUT=$(/home/cyf/ceph-dpu/build/bin/ceph auth get-or-create mgr.m1 mon 'allow profile mgr' osd 'allow *' mds 'allow *' | tail -n +1)
echo "$AUTH_OUTPUT" >>  /var/lib/ceph/mgr/ceph-m1/keyring
/home/cyf/ceph-dpu/build/bin/ceph-mgr -i m1
