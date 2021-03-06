#!/bin/bash
#
# Test fl_classify (caused by traffic) while adding failed hw rules.
# Bug SW #1297803: [ASAP MLNX OFED] fl_classify might access invalid memory on err flow in fl_change
#

NIC=${1:-ens2f0}
VF=${2:-ens2f2}
REP=${3:-eth0}
my_dir="$(dirname "$0")"
. $my_dir/common.sh

IP1="7.7.7.1"
IP2="7.7.7.2"

function cleanup() {
    reset_tc $REP
    reset_tc $REP2
    ip netns del ns0 2> /dev/null
    ip netns del ns1 2> /dev/null
    sleep 1
    modprobe -rv act_mirred cls_flower || err "failed unload"
}

function config_vf() {
    local ns=$1
    local vf=$2
    local rep=$3
    local ip=$4

    echo "$ns : $vf ($ip) -> $rep"
    if [ ! -e /sys/class/net/$vf ]; then
        err "Cannot find $vf"
        return 1
    fi
    if [ ! -e /sys/class/net/$rep ]; then
        err "Cannot find $rep"
        return 1
    fi
    reset_tc $vf
    reset_tc $rep
    ifconfig $rep 0 up
    ip netns add $ns
    ip link set $vf netns $ns
    ip netns exec $ns ifconfig $vf $ip/24 up
}

function disable_sriov() {
    title "- Disable SRIOV"
    echo 0 > /sys/class/net/$NIC/device/sriov_numvfs
    echo 0 > /sys/class/net/$NIC2/device/sriov_numvfs
}

function enable_sriov() {
    title "- Enable SRIOV"
    echo 2 > /sys/class/net/$NIC/device/sriov_numvfs
    echo 2 > /sys/class/net/$NIC2/device/sriov_numvfs
}

cleanup

enable_switchdev_if_no_rep $REP
bind_vfs

mac1=`cat /sys/class/net/$VF/address`
mac2=`cat /sys/class/net/$VF2/address`

test "$mac1" || fail "no mac1"
test "$mac2" || fail "no mac2"

config_vf ns0 $VF $REP $IP1
config_vf ns1 $VF2 $REP2 $IP2

modprobe -av act_mirred cls_flower

tc filter add dev $REP ingress protocol arp flower action mirred egress redirect dev $REP2 || fail "tc - failed adding arp rule"
tc filter add dev $REP2 ingress protocol arp flower action mirred egress redirect dev $REP || fail "tc - failed adding arp rule"

tc filter add dev $REP ingress protocol ip prio 1 flower skip_hw src_mac aa:bb:cc:dd:ee:ff action mirred egress redirect dev $REP2 || fail "tc - failed adding fake rule"
tc filter add dev $REP2 ingress protocol ip prio 1 flower skip_hw src_mac aa:bb:cc:dd:ee:ff action mirred egress redirect dev $REP || fail "tc - failed adding fake rule"

title "Test ping $VF($IP1, $mac1) -> $VF2($IP2, $mac2)"
ip netns exec ns0 ping -q -f $IP2 &

tc filter add dev $REP ingress protocol ip prio 3 flower skip_sw src_mac $mac1 action \
    mirred egress redirect dev $REP2 2>/dev/null && fail "tc - expected to fail adding rule"
tc filter add dev $REP2 ingress protocol ip prio 3 flower skip_sw src_mac $mac2 action \
    mirred egress redirect dev $REP 2>/dev/null && fail "tc - expected to fail adding rule"

max=10000
for i in `seq $max`; do
    # we expect to fail because of existing counter
    tc filter add dev $REP ingress protocol ip prio 1 flower skip_sw src_mac $mac1 action \
        mirred egress redirect dev $REP2 &>/dev/null && err "tc expected to fail" && break
    tc filter add dev $REP2 ingress protocol ip prio 1 flower skip_sw src_mac $mac2 action \
        mirred egress redirect dev $REP &>/dev/null && err "tc expected to fail" && break
    if (( i%500 == 0 )); then echo $i/$max ; fi
done

killall -9 ping

cleanup
test_done
