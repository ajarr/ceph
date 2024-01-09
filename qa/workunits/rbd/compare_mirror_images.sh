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
    RET=$(rbd --cluster $cluster snap ls --all $pool/$image --format=json \
            | jq 'last' \
            | jq 'select(.name | contains("non_primary"))' \
            | jq 'select(.namespace.state == "demoted")' \
            | jq 'select(.namespace.complete == true)')
    if [ "$RET" != "" ]; then
      echo demoted snapshot received, continuing
      break
    fi

    echo waiting for demoted snapshot...
    sleep $s
  done
}

compare_images() {
  local img=${IMG_PREFIX}$1
  local mntpt=${MNTPT_PREFIX}$1

  sudo umount ${mntpt}
  sudo rbd --cluster ${CLUSTER1} device unmap -t ${RBD_DEVICE_TYPE} \
      ${POOL}/${img}

  # demote primary image and calculate hash of its latest mirror snapshot
  demote_image ${CLUSTER1} ${POOL} ${img}
  local bdev demote demote_id demote_name demote_md5

  demote=$(rbd --cluster ${CLUSTER1} snap ls --all ${POOL}/${img} --format=json \
             | jq 'last' \
             | jq 'select(.name | contains("mirror.primary"))' \
             | jq 'select(.namespace.state == "demoted")')
  if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
    demote_id=$(echo $demote | jq -r '.id')
    bdev=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
             --snap-id ${demote_id} ${POOL}/${img})
  elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
    demote_name=$(echo $demote | jq -r '.name')
    bdev=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
             ${POOL}/${img}@${demote_name})
  else
     echo "Unknown RBD_DEVICE_TYPE: ${RBD_DEVICE_TYPE}"
     return 1
  fi
  demote_md5=$(sudo md5sum ${bdev} | awk '{print $1}')
  echo "demote_md5:$demote_md5 for pool/image:$POOL/$img in cluster:$CLUSTER1 mapped to bdev:$bdev"
  sudo rbd --cluster ${CLUSTER1} device unmap -t ${RBD_DEVICE_TYPE} ${bdev}

  wait_for_demote_snap ${CLUSTER2} ${POOL} ${img}

  # promote non-primary image and calculate hash of its latest mirror snapshot
  promote_image ${CLUSTER2} ${POOL} ${img}
  local promote promote_id promote_name promote_md5

  promote=$(rbd --cluster ${CLUSTER2} snap ls --all ${POOL}/${img} --format=json \
              | jq 'last' \
              | jq 'select(.name | contains("mirror.primary"))')
  if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
    promote_id=$(echo $promote | jq -r '.id')
    bdev=$(sudo rbd --cluster ${CLUSTER2} device map -t ${RBD_DEVICE_TYPE} \
             --snap-id ${promote_id} ${POOL}/${img})
  elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
    promote_name=$(echo $promote | jq -r '.name')
    bdev=$(sudo rbd --cluster ${CLUSTER2} device map -t ${RBD_DEVICE_TYPE} \
             ${POOL}/${img}@${promote_name})
  else
     echo "Unknown RBD_DEVICE_TYPE: ${RBD_DEVICE_TYPE}"
     return 1
  fi
  promote_md5=$(sudo md5sum ${bdev} | awk '{print $1}')
  echo "promote_md5:$promote_md5 for pool/image:$POOL/$img in cluster:$CLUSTER2 mapped to bdev:$bdev"
  sudo rbd --cluster ${CLUSTER2} device unmap -t ${RBD_DEVICE_TYPE} ${bdev}

  if [ "${demote_md5}" != "${promote_md5}" ]; then
    echo "demote_md5:$demote_md5 not same as promote_md5:$promote_md5 for pool/image:$POOL/$img"
    return 1
  fi
}

setup

start_mirrors ${CLUSTER1}
start_mirrors ${CLUSTER2}

for i in {1..10}; do
  for j in {1..10}; do
    IMG=${IMG_PREFIX}${j}
    MNTPT=${MNTPT_PREFIX}${j}
    create_image_and_enable_mirror ${CLUSTER1} ${POOL} ${IMG} \
      ${RBD_MIRROR_MODE} 10G
    BDEV=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
             ${POOL}/${IMG})
    sudo mkfs.ext4 ${BDEV}
    sudo mkdir -p ${MNTPT}
    sudo mount ${BDEV} ${MNTPT}
    # create mirror snapshots under I/O
    launch_manual_msnaps ${CLUSTER1} ${POOL} ${IMG} &
    run_bench ${MNTPT} ${WORKLOAD_TIMEOUT} &
  done
  wait

  pids=''
  for j in {1..10}; do
    compare_images $j &
    pids+=" $!"
  done

  for pid in $pids; do
    wait "$pid"
    RC=$?
    echo $pid $RC
    if [ $RC != 0 ]; then
      exit $RC
    fi
  done

  for j in {1..10}; do
    IMG=${IMG_PREFIX}${j}
    remove_image ${CLUSTER2} ${POOL} ${IMG}
  done
done

echo OK
