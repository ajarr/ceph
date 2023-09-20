#!/bin/bash
set -ex

POOL=rbd2
IMAGE_PREFIX=image
MNT_DIR_PREFIX=mnt
IMAGES=20
RUN_TIME=3600

ceph osd pool create ${POOL}
rbd pool init ${POOL}
rbd mirror pool enable ${POOL} image
rbd mirror pool peer add ${POOL} cluster1

# Create images and schedule their mirror snapshots
for ((i=1;i<=${IMAGES};i++)); do
    rbd create ${IMAGE_PREFIX}$i --size 1024 --pool ${POOL}
    rbd mirror image enable ${POOL}/${IMAGE_PREFIX}$i snapshot
    rbd mirror snapshot schedule add -p ${POOL} --image ${IMAGE_PREFIX}$i 1m
done

# Run fio workloads don images via kernel client
for ((i=1;i<=${IMAGES};i++)); do
    DEVS[$i]=$(sudo rbd device map ${POOL}/${IMAGE_PREFIX}$i)
    sudo mkfs.ext4 ${DEVS[$i]}
    MNTPATHS[$i]=`pwd`/${MNT_DIR_PREFIX}${IMAGE_PREFIX}$i
    mkdir -p ${MNTPATHS[$i]}
    sudo mount ${DEVS[$i]} ${MNTPATHS[$i]}
    sudo chown $(whoami) ${MNTPATHS[$i]}
    fio --name=fiotest --filename=${MNTPATHS[$i]}/test --rw=randrw --bs=4K \
        --direct=1 --ioengine=libaio --size=800M --iodepth=2 \
        --runtime=${RUN_TIME} --time_based &> /dev/null &
done

# Repeatedly blocklist rbd_support module's client ~10s after the module
# recovers from previous blocklisting
CURRENT_TIME=$(date +%s)
END_TIME=$((${CURRENT_TIME}+${RUN_TIME}))
PREV_CLIENT=0
while [[ ${CURRENT_TIME} -le ${END_TIME} ]]; do
    CLIENT_ADDR=$(ceph mgr dump | jq .active_clients[] |
        jq 'select(.name == "rbd_support")' |
        jq -r '[.addrvec[0].addr, "/", .addrvec[0].nonce|tostring] | add')
    if [[ -z "${CLIENT_ADDR}" ]] || \
       [[ "${CLIENT_ADDR}" == "${PREV_CLIENT}" ]]; then
        sleep 10
    else
        ceph osd blocklist add ${CLIENT_ADDR}
	sleep 10
        # Confirm rbd_support module's client is blocklisted
	ceph osd blocklist ls | grep -q ${CLIENT_ADDR}
	sudo pgrep -x fio || true
        PREV_CLIENT=${CLIENT_ADDR}
    fi
    CURRENT_TIME=$(date +%s)
done

# Confirm that rbd_support module recovered from repeated blocklisting
# Check that you can add a mirror snapshot schedule after a few retries
for ((i=1;i<=24;i++)); do
    rbd mirror snapshot schedule add -p ${POOL} \
        --image ${IMAGE_PREFIX}1 2m && break
    sleep 10
done
rbd mirror snapshot schedule ls -p ${POOL} \
    --image ${IMAGE_PREFIX}1 | grep 'every 2m'
# Verify that the schedule present before client blocklisting is preserved
rbd mirror snapshot schedule ls -p ${POOL} \
    --image ${IMAGE_PREFIX}1 | grep 'every 1m'
rbd mirror snapshot schedule rm -p ${POOL} \
    --image ${IMAGE_PREFIX}1 2m
for ((i=1;i<=${IMAGES};i++)); do
    rbd mirror snapshot schedule rm -p ${POOL} \
        --image ${IMAGE_PREFIX}$i 1m
done

# cleanup
sudo killall fio || true
for ((i=1;i<=${IMAGES};i++)); do
    sudo umount ${MNTPATHS[$i]}
    sudo rbd device unmap ${DEVS[$i]}
    rm -rf ${MNTPATHS[$i]}
done
ceph osd pool rm ${POOL} ${POOL} --yes-i-really-really-mean-it

echo OK
