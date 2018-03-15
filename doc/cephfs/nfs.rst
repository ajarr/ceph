===
NFS
===

CephFS namespaces can be exported over NFS protocol using the
`NFS-Ganesha NFS server <https://github.com/nfs-ganesha/nfs-ganesha/wiki>`_.

Requirements
============

-  Ceph filesystem (preferably latest luminous or later versions)
-  'nfs-ganesha' and 'nfs-ganesha-ceph' packages (preferably the latest
   ganesha v2.5 stable or later stable versions)
-  NFS-Ganesha server host connected to the Ceph public network

Configuring NFS-Ganesha to export CephFS
========================================

NFS-Ganesha provides a File System Abstraction Layer (FSAL) to plug in different
storage backends. `FSAL_CEPH <https://github.com/nfs-ganesha/nfs-ganesha/tree/next/src/FSAL/FSAL_CEPH>`_
is the plugin FSAL for CephFS. For each NFS-Ganesha export, FSAL_CEPH uses a
libcephfs client, user-space CephFS client, to mount the CephFS path that
NFS-Ganesha exports.

Setting up NFS-Ganesha with CephFS, involves setting up NFS-Ganesha's
configuration file, and also setting up a Ceph configuration file and cephx
access credentials for the Ceph clients created by NFS-Ganesha to access
CephFS.


NFS-Ganesha configuration
-------------------------

A minimal ganesha.conf for configuring NFS-Ganesha over CephFS includes a
EXPORT block and a CEPH block. Following is an example::

    EXPORT
    {
        Export_ID = 100;
        Path = "/"
        Pseudo = "/cephfs/";
        Protocols = 4;
        # Squash = Root_Squash;

        FSAL
        {
            Name = Ceph;
            # User_Id = "{cephx user ID}";
            # Secret_Access_Key = "{cephx secret key}";
        }

        CLIENT
        {
		    Clients = 192.168.0.10,192.168.1.0/8;
		    Access_Type = RW ;
        }
    }

    # Config block for Ceph FSAL
    CEPH
    {
	    # Ceph_Conf = /etc/ceph/ceph.conf;

	    # umask = 0;
    }

EXPORT {} options

- ``Export_ID`` must be a integer value. It is the unique export ID number for
  this export.

- ``Path`` is the CephFS dir path to export.

- ``Pseudo`` is the pseudo FS path for NFSv4 exports. NFS clients will use this
  path to be mounted.

EXPORT{CLIENT {}} options

- ``Clients`` is client list entry

EXPORT {} and EXPORT{CLIENT {}} options

- ``Protocols`` are the allowed protocols. NFSv3 and v4 protocols are allowed
  by default.  Here it is set to '4' to export over NFSv4 protocols. It is
  preferred that clients use NFSv4.1+ to talk to NFS-Ganesha.

- ``Squash`` is the kind of user ID squashing performed. Root-squashing
  is enabled by default. So the operations attempted by the client's root user
  are performed as if by the local "nobody" (and "nogroup") user on the
  NFS-Ganesha server.

- ``Access_Type`` is the kind of access allowed to the clients.

EXPORT {FSAL {}} options for Ceph FSAL

- ``Name`` of FSAL should always be "Ceph".

- ``User_Id`` is the cephx user ID used by the Ceph client to connect to
  CephFS. The cephx ID needs to be created before running NFS-Ganesha, and
  should have the necessary authorization to access the CephFS path exported
  by NFS-Ganesha. See:
  `<http://docs.ceph.com/docs/master/rados/operations/user-management/>`_

- ``Secret_Access_Key`` is the secret key of the cephx ID. If not set, then it
  uses the normal search path for cephx keyring files to find a key.

CEPH {} options

- ``Ceph_Conf`` is the path to the Ceph configuration file. If not specified,
  Ceph clients use '/etc/ceph/ceph.conf'.

- ``umask`` is the user file-creation mask. These bits will be masked off from
  the unix permissions on newly created inodes. It defaults to zero.

Refer to

- `<https://github.com/nfs-ganesha/nfs-ganesha/blob/next/src/doc/man/ganesha-export-config.rst>`_
  for more details on EXPORT {} and CLIENT {} options

- `<https://github.com/nfs-ganesha/nfs-ganesha/blob/next/src/doc/man/ganesha-ceph-config.rst>`_
  for more details about Ceph FSAL {} options

- `<https://github.com/nfs-ganesha/nfs-ganesha/blob/next/src/config_samples/export.txt>`_
  for more config samples

- `<https://github.com/nfs-ganesha/nfs-ganesha/blob/next/src/config_samples/ceph.conf>`_
  for more Ceph FSAL related config samples

Configuration for libcephfs clients
-----------------------------------

Required ceph.conf for libcephfs clients includes:

* a [client] section with ``mon_host`` option set to let the clients connect
  to the Ceph cluster's monitors, e.g., ::

    [client]
            mon host = 192.168.1.7:6789, 192.168.1.8:6789, 192.168.1.9:6789

Mount using NFSv4 clients
=========================

It is preferred to mount the NFS-Ganesha exports using NFSv4.1+ protocols
to get the benefit of sessions.

Conventions for mounting NFS resources are platform-specific. The
following conventions work on Linux and some Unix platforms:

From the command line::

  mount -t nfs -o nfsvers=4.1,proto=tcp <ganesha-host-name>:<ganesha-pseudo-path> <mount-point>

Current limitations
===================

- Per running ganesha daemon, FSAL_CEPH can only export one Ceph filesystem
  although multiple directories in a Cephfile system may be exported.
