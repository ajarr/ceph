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

wait_for_non_primary_demoted_mirror_snap() {
  local cluster=$1
  local pool=$2
  local image=$3

  for s in 1 2 4 8 8 8 8 8 8 8 8 16 16; do
    RET=$(rbd --cluster $cluster snap ls --all $pool/$image --format=json \
            | jq 'last' \
            | jq 'select(.name | contains("non_primary"))' \
            | jq 'select(.namespace.state == "demoted")' \
            | jq 'select(.namespace.complete == true)')
    if [ "$RET" != "" ]; then
      echo "demoted snapshot received, continuing"
      return 0
    fi

    echo "waiting for demoted snapshot ..."
    sleep $s
  done

  echo "demoted snapshot of pool/img:${pool}/${image} not received in \
    cluster:${cluster}"
  return 1
}

setup

start_mirrors ${CLUSTER1}
start_mirrors ${CLUSTER2}

# initial setup
create_image_and_enable_mirror ${CLUSTER1} ${POOL} ${IMAGE} \
  ${RBD_MIRROR_MODE} 10G

if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
  BDEV=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
           -o try-netlink ${POOL}/${IMAGE})
elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
  BDEV=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
           ${POOL}/${IMAGE})
else
  echo "Unknown RBD_DEVICE_TYPE: ${RBD_DEVICE_TYPE}"
  return 1
fi
sudo mkfs.ext4 ${BDEV}
sudo mkdir -p ${MOUNT}

for i in {1..25}; do
  # create mirror snapshots under I/O
  sudo mount ${BDEV} ${MOUNT}
  launch_manual_msnaps ${CLUSTER1} ${POOL} ${IMAGE} &
  run_bench ${MOUNT} ${WORKLOAD_TIMEOUT}
  wait

  sudo umount ${MOUNT}
  sudo rbd --cluster ${CLUSTER1} device unmap -t ${RBD_DEVICE_TYPE} ${BDEV}

  # demote primary image and calculate hash of its latest mirror snapshot
  demote_image ${CLUSTER1} ${POOL} ${IMAGE}
  DEMOTE=$(rbd --cluster ${CLUSTER1} snap ls --all ${POOL}/${IMAGE} \
             --format=json \
             | jq 'last' \
             | jq 'select(.name | contains("mirror.primary"))' \
             | jq 'select(.namespace.state == "demoted")')
  if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
    DEMOTE_ID=$(echo $DEMOTE | jq -r '.id')
    BDEV=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
             -o try-netlink --snap-id ${DEMOTE_ID} ${POOL}/${IMAGE})
  elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
    DEMOTE_NAME=$(echo $DEMOTE | jq -r '.name')
    BDEV=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
             ${POOL}/${IMAGE}@${DEMOTE_NAME})
  fi
  DEMOTE_MD5=$(sudo md5sum ${BDEV} | awk '{print $1}')
  sudo rbd --cluster ${CLUSTER1} device unmap -t ${RBD_DEVICE_TYPE} ${BDEV}

  wait_for_non_primary_demoted_mirror_snap ${CLUSTER2} ${POOL} ${IMAGE}

  # promote non-primary image and calculate hash of its latest mirror snapshot
  promote_image ${CLUSTER2} ${POOL} ${IMAGE}
  PROMOTE=$(rbd --cluster ${CLUSTER2} snap ls --all ${POOL}/${IMAGE} \
              --format=json \
              | jq 'last' \
              | jq 'select(.name | contains("mirror.primary"))')
  if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
    PROMOTE_ID=$(echo $PROMOTE | jq -r '.id')
    BDEV=$(sudo rbd --cluster ${CLUSTER2} device map -t ${RBD_DEVICE_TYPE} \
             -o try-netlink --snap-id ${PROMOTE_ID} ${POOL}/${IMAGE})
  elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
    PROMOTE_NAME=$(echo $PROMOTE | jq -r '.name')
    BDEV=$(sudo rbd --cluster ${CLUSTER2} device map -t ${RBD_DEVICE_TYPE} \
             ${POOL}/${IMAGE}@${PROMOTE_NAME})
  fi
  PROMOTE_MD5=$(sudo md5sum ${BDEV} | awk '{print $1}')
  sudo rbd --cluster ${CLUSTER2} device unmap -t ${RBD_DEVICE_TYPE} ${BDEV}

  [ "${DEMOTE_MD5}" == "${PROMOTE_MD5}" ];

  # enable mirroring on newly promoted image in the other cluster
  BDEV=$(sudo rbd --cluster ${CLUSTER2} device map -t ${RBD_DEVICE_TYPE} \
           ${POOL}/${IMAGE})
  enable_mirror ${CLUSTER2} ${POOL} ${IMAGE}

  TEMP=${CLUSTER1}
  CLUSTER1=${CLUSTER2}
  CLUSTER2=${TEMP}
done

echo OK
