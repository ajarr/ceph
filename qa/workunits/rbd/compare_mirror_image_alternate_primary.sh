#!/bin/bash

set -ex

IMAGE=image
RBD_MIRROR_MODE=snapshot
MOUNT=/mnt/test
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
    RET=$(rbd --cluster $cluster snap ls --all $pool/$image \
            | grep non_primary | tail -n 1 | grep demote | grep -v "%" || true)
    if [ "$RET" != "" ]; then
      echo demoted snapshot received, continuing
      sleep 10s #wait a bit for it to propagate
      break
    fi

    echo waiting for demoted snapshot...
    sleep $s
  done
}

setup

start_mirrors ${CLUSTER1}
start_mirrors ${CLUSTER2}

# initial setup
create_image_and_enable_mirror ${CLUSTER1} ${POOL} ${IMAGE} \
  ${RBD_MIRROR_MODE} 10G

BDEV=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
         ${POOL}/${IMAGE})
sudo mkfs.ext4 ${BDEV}
sudo mkdir -p ${MOUNT}

for i in {1..25};
do
    sudo mount ${BDEV} ${MOUNT}
    launch_manual_msnaps ${CLUSTER1} ${POOL} ${IMAGE} &
    run_bench ${MOUNT} ${WORKLOAD_TIMEOUT}
  wait

  sudo umount ${MOUNT}
  sudo rbd --cluster ${CLUSTER1} device unmap -t ${RBD_DEVICE_TYPE} ${BDEV}

  # demote and calc hash
  demote_image ${CLUSTER1} ${POOL} ${IMAGE}
  DEMOTE=$(rbd --cluster ${CLUSTER1} snap ls --all ${POOL}/${IMAGE} \
             | tail -n 1 | grep mirror\.primary | grep demoted)
  if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
    DEMOTE_ID=$(echo $DEMOTE | awk '{print $1}')
    BDEV=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
             --snap-id ${DEMOTE_ID} ${POOL}/${IMAGE})
  elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
    DEMOTE_NAME=$(echo $DEMOTE | awk '{print $2}')
    BDEV=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
             ${POOL}/${IMAGE}@${DEMOTE_NAME})
  else
     echo "Unknown RBD_DEVICE_TYPE: ${RBD_DEVICE_TYPE}"
     return 1
  fi
  DEMOTE_MD5=$(sudo dd if=${BDEV} bs=4M | md5sum | awk '{print $1}')
  sudo rbd --cluster ${CLUSTER1} device unmap -t ${RBD_DEVICE_TYPE} ${BDEV}

  wait_for_demote_snap ${CLUSTER2} ${POOL} ${IMAGE}

  # promote and calc hash
  promote_image ${CLUSTER2} ${POOL} ${IMAGE}
  PROMOTE=$(rbd --cluster ${CLUSTER2} snap ls --all ${POOL}/${IMAGE} \
              | tail -n 1 | grep mirror\.primary)
  if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
    PROMOTE_ID=$(echo $PROMOTE | awk '{print $1}')
    BDEV=$(sudo rbd --cluster ${CLUSTER2} device map -t ${RBD_DEVICE_TYPE} \
             --snap-id ${PROMOTE_ID} ${POOL}/${IMAGE})
  elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
    PROMOTE_NAME=$(echo $PROMOTE | awk '{print $2}')
    BDEV=$(sudo rbd --cluster ${CLUSTER2} device map -t ${RBD_DEVICE_TYPE} \
             ${POOL}/${IMAGE}@${PROMOTE_NAME})
  else
     echo "Unknown RBD_DEVICE_TYPE: ${RBD_DEVICE_TYPE}"
     return 1
  fi
  PROMOTE_MD5=$(sudo dd if=${BDEV} bs=4M | md5sum | awk '{print $1}')
  sudo rbd --cluster ${CLUSTER2} device unmap -t ${RBD_DEVICE_TYPE} ${BDEV}

  [ "${DEMOTE_MD5}" == "${PROMOTE_MD5}" ];

  # swap clusters
  TEMP=${CLUSTER1}
  CLUSTER1=${CLUSTER2}
  CLUSTER2=${TEMP}

  BDEV=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
           ${POOL}/${IMAGE})
  enable_mirror ${CLUSTER1} ${POOL} ${IMAGE}
done

echo OK
