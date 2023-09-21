#!/bin/bash
set -ex

POOL=rbd
IMAGE_PREFIX=image
MNT_DIR_PREFIX=mnt
NUM_IMAGES=20
RUN_TIME=3600

rbd mirror pool enable ${POOL} image
rbd mirror pool peer add ${POOL} dummy

# Create images and schedule their mirror snapshots
for ((i = 1; i <= ${NUM_IMAGES}; i++)); do
    rbd create --size 1G ${POOL}/${IMAGE_PREFIX}$i
    rbd mirror image enable ${POOL}/${IMAGE_PREFIX}$i snapshot
    rbd mirror snapshot schedule add -p ${POOL} --image ${IMAGE_PREFIX}$i 1m
done

# Run fio workloads on images via kernel client
for ((i = 1; i <= ${NUM_IMAGES}; i++)); do
    DEVS[$i]=$(sudo rbd device map ${POOL}/${IMAGE_PREFIX}$i)
    sudo fio --name=fiotest --filename=${DEVS[$i]} --rw=randrw --bs=4K \
        --ioengine=sync --size=800M --iodepth=1 \
        --runtime=43200 --time_based &> /dev/null &
    FIO_PIDS="$FIO_PIDS $!"
done

function cleanup() {
    set +e

    test -n "{FIO_PIDS}" && sudo kill ${FIO_PIDS}
    wait
    for (( i = 1; i <= ${NUM_IMAGES}; i++)); do
        sudo rbd device unmap ${DEVS[$i]}
    done
}

trap cleanup INT TERM EXIT

# Repeatedly blocklist rbd_support module's client ~10s after the module
# recovers from previous blocklisting
CURRENT_TIME=$(date +%s)
END_TIME=$((${CURRENT_TIME}+${RUN_TIME}))
PREV_CLIENT=""
CLIENT_ADDR=""
while [[ ${CURRENT_TIME} -le ${END_TIME} ]]; do
    if [[ ! -z "${CLIENT_ADDR}" ]] &&
       [[ "${CLIENT_ADDR}" != "${PREV_CLIENT}" ]]; then
            ceph osd blocklist add ${CLIENT_ADDR}
            # Confirm rbd_support module's client is blocklisted
            ceph osd blocklist ls | grep -q ${CLIENT_ADDR}
            PREV_CLIENT=${CLIENT_ADDR}
    fi
    sleep 10
    CLIENT_ADDR=$(ceph mgr dump |
        jq .active_clients[] |
        jq 'select(.name == "rbd_support")' |
        jq -r '[.addrvec[0].addr, "/", .addrvec[0].nonce|tostring] | add')
    CURRENT_TIME=$(date +%s)
done

# Confirm that rbd_support module recovered from repeated blocklisting
# Check that you can add a mirror snapshot schedule after a few retries
for ((i = 1; i <= 24; i++)); do
    rbd mirror snapshot schedule add -p ${POOL} \
        --image ${IMAGE_PREFIX}1 2m && break
    sleep 10
done
rbd mirror snapshot schedule ls -p ${POOL} --image ${IMAGE_PREFIX}1 |
    grep 'every 2m'
# Verify that the schedule present before client blocklisting is preserved
rbd mirror snapshot schedule ls -p ${POOL} --image ${IMAGE_PREFIX}1 |
    grep 'every 1m'
rbd mirror snapshot schedule rm -p ${POOL} --image ${IMAGE_PREFIX}1 2m
for ((i = 1; i <= ${NUM_IMAGES}; i++)); do
    rbd mirror snapshot schedule rm -p ${POOL} --image ${IMAGE_PREFIX}$i 1m
done

echo OK
