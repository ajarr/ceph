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

wait_for_non_primary_demoted_mirror_snap() {
  local cluster=$1
  local pool=$2
  local image=$3
  local ret

  for s in 1 2 4 8 8 8 8 8 8 8 8 16 16; do
    ret=$(rbd --cluster $cluster snap ls --all $pool/$image --format=json \
            | jq 'last' \
            | jq 'select(.name | contains("non_primary"))' \
            | jq 'select(.namespace.state == "demoted")' \
            | jq 'select(.namespace.complete == true)')
    if [ "$ret" != "" ]; then
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

wait_for_image_removal () {
  local cluster=$1
  local pool=$2
  local image=$3
  local img_in_list

  for s in 1 2 4 8 8 8 8 8 8 8 8 16 16; do
    img_in_list=$(rbd --cluster $cluster ls -p $pool --format=json \
                    | jq --arg img $image 'index($img)')
    if [[ $img_in_list == null ]]; then
      echo "image:${image} removed from cluster:${cluster} pool:${pool}"
      return 0
    fi

    echo "waiting for image ${image} to be removed from \
      cluster:${cluster} pool:${pool} ..."
    sleep $s
  done

  echo "image:${image} not removed from cluster:${cluster} pool:${pool}"
  return 1
}

compare_demoted_promoted_mirror_snaps() {
  local img=${IMG_PREFIX}$1
  local mntpt=${MNTPT_PREFIX}$1
  local bdev demote demote_id demote_name demote_md5
  local promote promote_id promote_name promote_md5

  sudo umount ${mntpt}
  sudo rbd --cluster ${CLUSTER1} device unmap -t ${RBD_DEVICE_TYPE} \
      ${POOL}/${img}

  # demote primary image and calculate hash of its latest mirror snapshot
  demote_image ${CLUSTER1} ${POOL} ${img}
  demote=$(rbd --cluster ${CLUSTER1} snap ls --all ${POOL}/${img} \
             --format=json \
             | jq 'last' \
             | jq 'select(.name | contains("mirror.primary"))' \
             | jq 'select(.namespace.state == "demoted")')
  if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
    demote_id=$(echo $demote | jq -r '.id')
    bdev=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
             -o try-netlink --snap-id ${demote_id} ${POOL}/${img})
  elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
    demote_name=$(echo $demote | jq -r '.name')
    bdev=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
             ${POOL}/${img}@${demote_name})
  fi
  demote_md5=$(sudo md5sum ${bdev} | awk '{print $1}')
  sudo rbd --cluster ${CLUSTER1} device unmap -t ${RBD_DEVICE_TYPE} ${bdev}

  wait_for_non_primary_demoted_mirror_snap ${CLUSTER2} ${POOL} ${img}

  # promote non-primary image and calculate hash of its latest mirror snapshot
  promote_image ${CLUSTER2} ${POOL} ${img}
  promote=$(rbd --cluster ${CLUSTER2} snap ls --all ${POOL}/${img} \
              --format=json \
              | jq 'last' \
              | jq 'select(.name | contains("mirror.primary"))')
  if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
    promote_id=$(echo $promote | jq -r '.id')
    bdev=$(sudo rbd --cluster ${CLUSTER2} device map -t ${RBD_DEVICE_TYPE} \
             -o try-netlink --snap-id ${promote_id} ${POOL}/${img})
  elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
    promote_name=$(echo $promote | jq -r '.name')
    bdev=$(sudo rbd --cluster ${CLUSTER2} device map -t ${RBD_DEVICE_TYPE} \
             ${POOL}/${img}@${promote_name})
  fi
  promote_md5=$(sudo md5sum ${bdev} | awk '{print $1}')
  sudo rbd --cluster ${CLUSTER2} device unmap -t ${RBD_DEVICE_TYPE} ${bdev}

  if [ "${demote_md5}" != "${promote_md5}" ]; then
    echo "demote_md5:${demote_md5} != promote_md5:${promote_md5} for \
      pool/img:${POOL}/${img}"
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
    if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
      BDEV=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
               -o try-netlink ${POOL}/${IMG})
    elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
      BDEV=$(sudo rbd --cluster ${CLUSTER1} device map -t ${RBD_DEVICE_TYPE} \
               ${POOL}/${IMG})
    else
      echo "Unknown RBD_DEVICE_TYPE: ${RBD_DEVICE_TYPE}"
      return 1
    fi
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
    compare_demoted_promoted_mirror_snaps $j &
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
    # Allow for removal of non-primary image by checking that mirroring
    # image status is "up+replaying"
    wait_for_replaying_status_in_pool_dir ${CLUSTER1} ${POOL} ${IMG}
    remove_image ${CLUSTER2} ${POOL} ${IMG}
    wait_for_image_removal ${CLUSTER1} ${POOL} ${IMG}
  done
done

echo OK
