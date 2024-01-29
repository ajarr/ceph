#!/bin/bash

set -ex

CEPH_ARGS=''
IMG_PREFIX=image-primary
MIRROR_IMAGE_MODE=snapshot
MIRROR_POOL_MODE=image
MNTPT_PREFIX=test-primary
RBD_IMAGE_FEATURES='layering,exclusive-lock,object-map,fast-diff'
RBD_MIRROR_INSTANCES=1
RBD_MIRROR_MODE=snapshot
RBD_MIRROR_USE_EXISTING_CLUSTER=1
WORKLOAD_TIMEOUT=5m

. $(dirname $0)/rbd_mirror_helpers.sh

take_mirror_snapshots() {
  local cluster=$1
  local pool=$2
  local image=$3

  for i in {1..30}; do
    mirror_image_snapshot $cluster $pool $image
    sleep 3s;
  done
}

slow_untar_workload() {
  local tarball_src_path=$1
  local mountpt=$2
  local timeout=$3

  cp $tarball_src_path $mountpt/kernel.tar.gz
  timeout $timeout bash -c "tar xvfz $mountpt/kernel.tar.gz -C $mountpt \
    | pv -L 1k --quiet > /dev/null" || true
}

wait_for_non_primary_demoted_mirror_snap() {
  local cluster=$1
  local pool=$2
  local image=$3
  local demoted=false

  for s in 1 2 4 8 8 8 8 8 8 8 8 16 16; do
    demoted=$(rbd --cluster $cluster snap ls --all $pool/$image --format=json \
              | jq '(last | .name | startswith(".mirror.non_primary")) and
                    (last | .namespace.state == "demoted") and
                    (last | .namespace.complete == true)')

    if [ "$demoted" = true ]; then
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

  for s in 1 2 4 8 8 8 8 8 8 8 8 16 16; do
    if [[ -z $(rbd --cluster $cluster ls $pool | grep -w $image) ]]; then
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
  local dev=$1
  local img=${IMG_PREFIX}$2
  local mntpt=${MNTPT_PREFIX}$2
  local demote_md5 promote_md5

  sudo umount ${mntpt}

  # calculate hash before demotion of primary image
  demote_md5=$(sudo md5sum ${dev} | awk '{print $1}')
  sudo rbd --cluster ${CLUSTER1} device unmap -t ${RBD_DEVICE_TYPE} \
      ${POOL}/${img}

  demote_image ${CLUSTER1} ${POOL} ${img}
  wait_for_non_primary_demoted_mirror_snap ${CLUSTER2} ${POOL} ${img}
  sleep 10
  # wait_for_status_in_pool_dir ${CLUSTER1} ${POOL} ${img} 'up+unknown'
  # wait_for_status_in_pool_dir ${CLUSTER2} ${POOL} ${img} 'up+unknown'
  promote_image ${CLUSTER2} ${POOL} ${img}

  # calculate hash after promotion of secondary image
  if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
    dev=$(sudo rbd --cluster ${CLUSTER2} device map -t nbd \
             -o try-netlink ${POOL}/${img})
  elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
    dev=$(sudo rbd --cluster ${CLUSTER2} device map -t krbd ${POOL}/${img})
  fi
  promote_md5=$(sudo md5sum ${dev} | awk '{print $1}')
  sudo rbd --cluster ${CLUSTER2} device unmap -t ${RBD_DEVICE_TYPE} ${dev}

  if [[ "${demote_md5}" != "${promote_md5}" ]]; then
    echo "Mismatch for ${POOL}/${img}: ${demote_md5} != ${promote_md5}"
    return 1
  fi
}

setup

start_mirrors ${CLUSTER1}
start_mirrors ${CLUSTER2}

TARBALL_SRC=kernel.tar.gz
wget https://download.ceph.com/qa/linux-5.4.tar.gz -O ${TARBALL_SRC}

for i in {1..10}; do
  DEVS=()
  for j in {1..10}; do
    IMG=${IMG_PREFIX}${j}
    MNTPT=${MNTPT_PREFIX}${j}
    create_image_and_enable_mirror ${CLUSTER1} ${POOL} ${IMG} \
      ${RBD_MIRROR_MODE} 10G
    if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
      DEV=$(sudo rbd --cluster ${CLUSTER1} device map -t nbd \
	      -o try-netlink ${POOL}/${IMG})
    elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
      DEV=$(sudo rbd --cluster ${CLUSTER1} device map -t krbd \
	      ${POOL}/${IMG})
    else
      echo "Unknown RBD_DEVICE_TYPE: ${RBD_DEVICE_TYPE}"
      return 1
    fi
    DEVS+=($DEV)
    sudo mkfs.ext4 ${DEV}
    mkdir ${MNTPT}
    sudo mount ${DEV} ${MNTPT}
    sudo chown $(whoami) ${MNTPT}
    # create mirror snapshots under I/O every few seconds
    take_mirror_snapshots ${CLUSTER1} ${POOL} ${IMG} &
    slow_untar_workload ${TARBALL_SRC} ${MNTPT} ${WORKLOAD_TIMEOUT} &
  done
  wait

  pids=''
  for j in {1..10}; do
    compare_demoted_promoted_mirror_snaps ${DEVS[$j-1]} $j &
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
    rm -rf ${MNTPT_PREFIX}${j}
  done
done

echo OK
