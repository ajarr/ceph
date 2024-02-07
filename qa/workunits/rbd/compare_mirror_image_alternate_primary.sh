#!/bin/bash

set -ex

CEPH_ARGS=''
IMAGE=image-alternate-primary
MIRROR_IMAGE_MODE=snapshot
MIRROR_POOL_MODE=image
MOUNT=test-alternate-primary
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
  # run workload that updates the data and metadata of multiple files on disk.
  # rate limit the workload such that the mirror snapshots can be taken as the
  # contents of the image are progressively changed by the workload.
  timeout $timeout bash -c "zcat $mountpt/kernel.tar.gz \
    | pv -L 256K | tar xf - -C $mountpt" || true
}

setup

start_mirrors ${CLUSTER1}
start_mirrors ${CLUSTER2}

# initial setup
create_image_and_enable_mirror ${CLUSTER1} ${POOL} ${IMAGE} \
  ${RBD_MIRROR_MODE} 10G

if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
  DEV=$(sudo rbd --cluster ${CLUSTER1} device map -t nbd \
           -o try-netlink ${POOL}/${IMAGE})
elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
  DEV=$(sudo rbd --cluster ${CLUSTER1} device map -t krbd \
           ${POOL}/${IMAGE})
else
  echo "Unknown RBD_DEVICE_TYPE: ${RBD_DEVICE_TYPE}"
  return 1
fi
sudo mkfs.ext4 ${DEV}
mkdir ${MOUNT}

TARBALL_SRC=kernel.tar.gz
wget https://download.ceph.com/qa/linux-5.4.tar.gz -O ${TARBALL_SRC}

for i in {1..25}; do
  # create mirror snapshots every few seconds under I/O
  sudo mount ${DEV} ${MOUNT}
  sudo chown $(whoami) ${MOUNT}
  take_mirror_snapshots ${CLUSTER1} ${POOL} ${IMAGE} &
  slow_untar_workload ${TARBALL_SRC} ${MOUNT} ${WORKLOAD_TIMEOUT}
  wait

  sudo umount ${MOUNT}

  # calculate hash before demotion of primary image
  DEMOTE_MD5=$(sudo md5sum ${DEV} | awk '{print $1}')
  sudo rbd --cluster ${CLUSTER1} device unmap -t ${RBD_DEVICE_TYPE} ${DEV}

  demote_image ${CLUSTER1} ${POOL} ${IMAGE}
  # wait_for_status_in_pool_dir ${CLUSTER1} ${POOL} ${IMAGE} 'up+unknown'
  wait_for_status_in_pool_dir ${CLUSTER2} ${POOL} ${IMAGE} 'up+unknown'
  promote_image ${CLUSTER2} ${POOL} ${IMAGE}

  # calculate hash after promotion of secondary image
  if [[ $RBD_DEVICE_TYPE == "nbd" ]]; then
    DEV=$(sudo rbd --cluster ${CLUSTER2} device map -t nbd \
             -o try-netlink ${POOL}/${IMAGE})
  elif [[ $RBD_DEVICE_TYPE == "krbd" ]]; then
    DEV=$(sudo rbd --cluster ${CLUSTER2} device map -t krbd ${POOL}/${IMAGE})
  fi
  PROMOTE_MD5=$(sudo md5sum ${DEV} | awk '{print $1}')

  if [[ "${DEMOTE_MD5}" != "${PROMOTE_MD5}" ]]; then
    echo "Mismatch at iteration ${i}: ${DEMOTE_MD5} != ${PROMOTE_MD5}"
    exit 1
  fi

  TEMP=${CLUSTER1}
  CLUSTER1=${CLUSTER2}
  CLUSTER2=${TEMP}
done

echo OK
