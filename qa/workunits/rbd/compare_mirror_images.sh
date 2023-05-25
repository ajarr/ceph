#!/bin/bash

set -ex

IMG_PREFIX=image-
RBD_MIRROR_MODE=snapshot
MNTPT_PREFIX=/mnt/test
WORKLOAD_TIMEOUT=5m

. $(dirname $0)/rbd_mirror_helpers.sh

launch_manual_msnaps() {
  local cluster=$1
  local pool=$2
  local image=$3

  for i in {1..30}; do
    mirror_image_snapshot $cluster $pool $image
    sleep 3s;
  done
}

run_bench() {
  local mountpt=$1
  local timeout=$2

  KERNEL_TAR_URL="https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-4.14.280.tar.gz"
  sudo wget $KERNEL_TAR_URL -O $mountpt/kernel.tar.gz
  sudo timeout $timeout bash -c "tar xvfz $mountpt/kernel.tar.gz -C $mountpt \
    | pv -L 1k --timer &> /dev/null" || true
}

wait_for_demote_snap () {
  local cluster=$1
  local pool=$2
  local image=$3

  for s in 1 2 4 8 8 8 8 8 8 8 8 16 16; do
    RET=$(rbd --cluster $cluster snap ls --all $pool/$image | tail -n 1 \
            | grep non_primary | grep demote | grep -v "%" || true)
    if [ "$RET" != "" ]; then
      echo demoted snapshot received, continuing
      sleep 10s #wait a bit for it to propagate
      break
    fi

    echo waiting for demoted snapshot...
    sleep $s
  done
}

compare_images() {
  local IMG=${IMG_PREFIX}$1
  local MNTPT=${MNTPT_PREFIX}$1

  sudo umount ${MNTPT}
  sudo rbd --cluster ${CLUSTER1} device unmap -t ${RBD_DEVICE_TYPE} \
      ${POOL}/${IMG}
  demote_image ${CLUSTER1} ${POOL} ${IMG}

  DEMOTE=$(rbd --cluster ${CLUSTER1} snap ls --all ${POOL}/${IMG} \
             | tail -n 1 | grep mirror\.primary | grep demoted)
  if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
    DEMOTE_ID=$(echo $DEMOTE | awk '{print $1}')
    BDEV=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
             --snap-id ${DEMOTE_ID} ${POOL}/${IMG})
  elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
    DEMOTE_NAME=$(echo $DEMOTE | awk '{print $2}')
    BDEV=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
             ${POOL}/${IMG}@${DEMOTE_NAME})
  else
     echo "Unknown RBD_DEVICE_TYPE: ${RBD_DEVICE_TYPE}"
     return 1
  fi
  DEMOTE_MD5=$(sudo dd if=${BDEV} bs=4M | md5sum | awk '{print $1}')
  sudo rbd --cluster ${CLUSTER1} device unmap -t ${RBD_DEVICE_TYPE} ${BDEV}

  wait_for_demote_snap ${CLUSTER2} ${POOL} ${IMG}

  promote_image ${CLUSTER2} ${POOL} ${IMG}

  PROMOTE=$(rbd --cluster ${CLUSTER2} snap ls --all ${POOL}/${IMG} \
              | tail -n 1 | grep mirror\.primary)
  if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
    PROMOTE_ID=$(echo $PROMOTE | awk '{print $1}')
    BDEV=$(sudo rbd --cluster ${CLUSTER2} device map -t ${RBD_DEVICE_TYPE} \
             --snap-id ${PROMOTE_ID} ${POOL}/${IMG})
  elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
    PROMOTE_NAME=$(echo $PROMOTE | awk '{print $2}')
    BDEV=$(sudo rbd --cluster ${CLUSTER2} device map -t ${RBD_DEVICE_TYPE} \
             ${POOL}/${IMG}@${PROMOTE_NAME})
  else
     echo "Unknown RBD_DEVICE_TYPE: ${RBD_DEVICE_TYPE}"
     return 1
  fi
  PROMOTE_MD5=$(sudo dd if=${BDEV} bs=4M | md5sum | awk '{print $1}')
  sudo rbd --cluster ${CLUSTER2} device unmap -t ${RBD_DEVICE_TYPE} ${BDEV}

  if [ "${DEMOTE_MD5}" != "${PROMOTE_MD5}" ]; then
          return 1
  fi
}

setup

start_mirrors ${CLUSTER1}
start_mirrors ${CLUSTER2}

for i in {1..10};
do
  for j in {1..10};
  do
    IMG=${IMG_PREFIX}${j}
    MNTPT=${MNTPT_PREFIX}${j}
    create_image_and_enable_mirror ${CLUSTER1} ${POOL} ${IMG} \
      ${RBD_MIRROR_MODE} 10G
    BDEV=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
             ${POOL}/${IMG})
    sudo mkfs.ext4 ${BDEV}
    sudo mkdir -p ${MNTPT}
    sudo mount ${BDEV} ${MNTPT}
    launch_manual_msnaps ${CLUSTER1} ${POOL} ${IMG} &
    run_bench ${MNTPT} ${WORKLOAD_TIMEOUT} &
  done
  wait

  pids=''
  for j in {1..10};
  do
    compare_images $j &
    pids+=" $!"
  done

  for pid in $pids;
  do
    wait "$pid"
    RC=$?
    echo $pid $RC
    if [ $RC != 0 ]; then
      exit $RC
    fi
  done

  for j in {1..10};
  do
    IMG=${IMG_PREFIX}${j}
    remove_image ${CLUSTER2} ${POOL} ${IMG}
  done
done

echo OK
