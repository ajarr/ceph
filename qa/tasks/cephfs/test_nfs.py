# NOTE: these tests are not yet compatible with vstart_runner.py.
import errno
import json
import time
import logging
from io import BytesIO

from tasks.mgr.mgr_test_case import MgrTestCase
from teuthology import contextutil
from teuthology.exceptions import CommandFailedError

log = logging.getLogger(__name__)

NFS_POOL_NAME = '.nfs'  # should match mgr_module.py

# TODO Add test for cluster update when ganesha can be deployed on multiple ports.
class TestNFS(MgrTestCase):
    def _cmd(self, *args):
        return self.mgr_cluster.mon_manager.raw_cluster_cmd(*args)

    def _nfs_cmd(self, *args):
        return self._cmd("nfs", *args)

    def _orch_cmd(self, *args):
        return self._cmd("orch", *args)

    def _sys_cmd(self, cmd):
        ret = self.ctx.cluster.run(args=cmd, check_status=False, stdout=BytesIO(), stderr=BytesIO())
        stdout = ret[0].stdout
        if stdout:
            return stdout.getvalue()

    def setUp(self):
        super(TestNFS, self).setUp()
        self._load_module('nfs')
        self.cluster_id = "test"
        self.export_type = "cephfs"
        self.pseudo_path = "/cephfs"
        self.path = "/"
        self.fs_name = "nfs-cephfs"
        self.expected_name = "nfs.test"
        self.sample_export = {
         "export_id": 1,
         "path": self.path,
         "cluster_id": self.cluster_id,
         "pseudo": self.pseudo_path,
         "access_type": "RW",
         "squash": "none",
         "security_label": True,
         "protocols": [
           4
         ],
         "transports": [
           "TCP"
         ],
         "fsal": {
           "name": "CEPH",
           "user_id": "nfs.test.1",
           "fs_name": self.fs_name,
         },
         "clients": []
        }

    def _check_nfs_server_status(self):
        res = self._sys_cmd(['sudo', 'systemctl', 'status', 'nfs-server'])
        if isinstance(res, bytes) and b'Active: active' in res:
            self._disable_nfs()

    def _disable_nfs(self):
        log.info("Disabling NFS")
        self._sys_cmd(['sudo', 'systemctl', 'disable', 'nfs-server', '--now'])

    def _fetch_nfs_daemons_details(self, enable_json=False):
        args = ('ps', f'--service_name={self.expected_name}')
        if enable_json:
            args = (*args, '--format=json')
        return self._orch_cmd(*args)

    def _check_nfs_cluster_event(self, expected_event, fail_msg):
        '''
        Check whether an event occured during the lifetime of the NFS service
        :param expected_event: event that was expected to occur
        :param fail_msg: message if the event did not occur
        '''
        # Wait few seconds for NFS daemons' status to be updated
        wait_time = 10
        while wait_time <= 60:
            time.sleep(wait_time)
            daemons_details = self._fetch_nfs_daemons_details(enable_json=True)
            for event in daemons_details[0]['events']:
                if expected_event in event:
                    return
            wait_time += 10
        self.fail(fail_msg)

    def _check_nfs_cluster_status(self, expected_status, fail_msg):
        '''
        Check the current status of the NFS service
        :param expected_status: Status to be verified
        :param fail_msg: Message to be printed if test failed
        '''
        # Wait few seconds for nfs cluster status to be updated
        wait_time = 10
        while wait_time <= 60:
            time.sleep(wait_time)
            if expected_status in self._fetch_nfs_daemons_details():
                return
            wait_time += 10
        self.fail(fail_msg)

    def _check_auth_ls(self, export_id=1, check_in=False):
        '''
        Tests export user id creation or deletion.
        :param export_id: Denotes export number
        :param check_in: Check specified export id
        '''
        output = self._cmd('auth', 'ls')
        client_id = f'client.nfs.{self.cluster_id}'
        if check_in:
            self.assertIn(f'{client_id}.{export_id}', output)
        else:
            self.assertNotIn(f'{client_id}.{export_id}', output)

    def _test_idempotency(self, cmd_func, cmd_args):
        '''
        Test idempotency of commands. It first runs the TestNFS test method
        for a command and then checks the result of command run again. TestNFS
        test method has required checks to verify that command works.
        :param cmd_func: TestNFS method
        :param cmd_args: nfs command arguments to be run
        '''
        cmd_func()
        ret = self.mgr_cluster.mon_manager.raw_cluster_cmd_result(*cmd_args)
        if ret != 0:
            self.fail("Idempotency test failed")

    def _test_create_cluster(self):
        '''
        Test single nfs cluster deployment.
        '''
        # Disable any running nfs ganesha daemon
        self._check_nfs_server_status()
        self._nfs_cmd('cluster', 'create', self.cluster_id)
        # Check for expected status and daemon name (nfs.<cluster_id>)
        self._check_nfs_cluster_status('running', 'NFS Ganesha cluster deployment failed')

    def _test_delete_cluster(self):
        '''
        Test deletion of a single nfs cluster.
        '''
        self._nfs_cmd('cluster', 'rm', self.cluster_id)
        self._check_nfs_cluster_status('No daemons reported',
                                       'NFS Ganesha cluster could not be deleted')

    def _test_list_cluster(self, empty=False):
        '''
        Test listing of deployed nfs clusters. If nfs cluster is deployed then
        it checks for expected cluster id. Otherwise checks nothing is listed.
        :param empty: If true it denotes no cluster is deployed.
        '''
        if empty:
            cluster_id = ''
        else:
            cluster_id = self.cluster_id
        nfs_output = self._nfs_cmd('cluster', 'ls')
        self.assertEqual(cluster_id, nfs_output.strip())

    def _create_export(self, export_id, create_fs=False, extra_cmd=None):
        '''
        Test creation of a single export.
        :param export_id: Denotes export number
        :param create_fs: If false filesytem exists. Otherwise create it.
        :param extra_cmd: List of extra arguments for creating export.
        '''
        if create_fs:
            self._cmd('fs', 'volume', 'create', self.fs_name)
            with contextutil.safe_while(sleep=5, tries=30) as proceed:
                while proceed():
                    output = self._cmd(
                        'orch', 'ls', '-f', 'json',
                        '--service-name', f'mds.{self.fs_name}'
                    )
                    j = json.loads(output)
                    if j[0]['status']['running']:
                        break
        export_cmd = ['nfs', 'export', 'create', 'cephfs',
                      '--fsname', self.fs_name, '--cluster-id', self.cluster_id]
        if isinstance(extra_cmd, list):
            export_cmd.extend(extra_cmd)
        else:
            export_cmd.extend(['--pseudo-path', self.pseudo_path])
        # Runs the nfs export create command
        self._cmd(*export_cmd)
        # Check if user id for export is created
        self._check_auth_ls(export_id, check_in=True)
        res = self._sys_cmd(['rados', '-p', NFS_POOL_NAME, '-N', self.cluster_id, 'get',
                             f'export-{export_id}', '-'])
        # Check if export object is created
        if res == b'':
            self.fail("Export cannot be created")

    def _create_default_export(self):
        '''
        Deploy a single nfs cluster and create export with default options.
        '''
        self._test_create_cluster()
        self._create_export(export_id='1', create_fs=True)

    def _delete_export(self):
        '''
        Delete an export.
        '''
        self._nfs_cmd('export', 'rm', self.cluster_id, self.pseudo_path)
        self._check_auth_ls()

    def _test_list_export(self):
        '''
        Test listing of created exports.
        '''
        nfs_output = json.loads(self._nfs_cmd('export', 'ls', self.cluster_id))
        self.assertIn(self.pseudo_path, nfs_output)

    def _test_list_detailed(self, sub_vol_path):
        '''
        Test listing of created exports with detailed option.
        :param sub_vol_path: Denotes path of subvolume
        '''
        nfs_output = json.loads(self._nfs_cmd('export', 'ls', self.cluster_id, '--detailed'))
        # Export-1 with default values (access type = rw and path = '\')
        self.assertDictEqual(self.sample_export, nfs_output[0])
        # Export-2 with r only
        self.sample_export['export_id'] = 2
        self.sample_export['pseudo'] = self.pseudo_path + '1'
        self.sample_export['access_type'] = 'RO'
        self.sample_export['fsal']['user_id'] = f'{self.expected_name}.2'
        self.assertDictEqual(self.sample_export, nfs_output[1])
        # Export-3 for subvolume with r only
        self.sample_export['export_id'] = 3
        self.sample_export['path'] = sub_vol_path
        self.sample_export['pseudo'] = self.pseudo_path + '2'
        self.sample_export['fsal']['user_id'] = f'{self.expected_name}.3'
        self.assertDictEqual(self.sample_export, nfs_output[2])
        # Export-4 for subvolume
        self.sample_export['export_id'] = 4
        self.sample_export['pseudo'] = self.pseudo_path + '3'
        self.sample_export['access_type'] = 'RW'
        self.sample_export['fsal']['user_id'] = f'{self.expected_name}.4'
        self.assertDictEqual(self.sample_export, nfs_output[3])

    def _get_export(self):
        '''
        Returns export block in json format
        '''
        return json.loads(self._nfs_cmd('export', 'info', self.cluster_id, self.pseudo_path))

    def _test_get_export(self):
        '''
        Test fetching of created export.
        '''
        nfs_output = self._get_export()
        self.assertDictEqual(self.sample_export, nfs_output)

    def _check_export_obj_deleted(self, conf_obj=False):
        '''
        Test if export or config object are deleted successfully.
        :param conf_obj: It denotes config object needs to be checked
        '''
        rados_obj_ls = self._sys_cmd(['rados', '-p', NFS_POOL_NAME, '-N', self.cluster_id, 'ls'])

        if b'export-' in rados_obj_ls or (conf_obj and b'conf-nfs' in rados_obj_ls):
            self.fail("Delete export failed")

    def _get_port_ip_info(self):
        '''
        Return port and ip for a cluster
        '''
        #{'test': {'backend': [{'hostname': 'smithi068', 'ip': '172.21.15.68', 'port': 2049}]}}
        info_output = json.loads(self._nfs_cmd('cluster', 'info', self.cluster_id))['test']['backend'][0]
        return info_output["port"], info_output["ip"]

    def _test_mnt(self, pseudo_path, port, ip, check=True):
        '''
        Test mounting of created exports
        :param pseudo_path: It is the pseudo root name
        :param port: Port of deployed nfs cluster
        :param ip: IP of deployed nfs cluster
        :param check: It denotes if i/o testing needs to be done
        '''
        tries = 3
        while True:
            try:
                self.ctx.cluster.run(
                    args=['sudo', 'mount', '-t', 'nfs', '-o', f'port={port}',
                          f'{ip}:{pseudo_path}', '/mnt'])
                break
            except CommandFailedError as e:
                if tries:
                    tries -= 1
                    time.sleep(2)
                    continue
                # Check if mount failed only when non existing pseudo path is passed
                if not check and e.exitstatus == 32:
                    return
                raise

        self.ctx.cluster.run(args=['sudo', 'chmod', '1777', '/mnt'])

        try:
            self.ctx.cluster.run(args=['touch', '/mnt/test'])
            out_mnt = self._sys_cmd(['ls', '/mnt'])
            self.assertEqual(out_mnt,  b'test\n')
        finally:
            self.ctx.cluster.run(args=['sudo', 'umount', '/mnt'])

    def _write_to_read_only_export(self, pseudo_path, port, ip):
        '''
        Check if write to read only export fails
        '''
        try:
            self._test_mnt(pseudo_path, port, ip)
        except CommandFailedError as e:
            # Write to cephfs export should fail for test to pass
            self.assertEqual(
                e.exitstatus, errno.EPERM,
                'invalid error code on trying to write to read-only export')
        else:
            self.fail('expected write to a read-only export to fail')

    def test_update_export(self):
        '''
        Test update of export's pseudo path and access type from rw to ro
        '''
        self._create_default_export()
        port, ip = self._get_port_ip_info()
        self._test_mnt(self.pseudo_path, port, ip)
        export_block = self._get_export()
        new_pseudo_path = '/testing'
        export_block['pseudo'] = new_pseudo_path
        export_block['access_type'] = 'RO'
        self.ctx.cluster.run(args=['ceph', 'nfs', 'export', 'apply',
                                   self.cluster_id, '-i', '-'],
                             stdin=json.dumps(export_block))
        # updating export's pseudo path should trigger restart of NFS service
        self._check_nfs_cluster_event('restart', 'NFS Ganesha cluster did not restart')
        self._check_nfs_cluster_status('running', 'NFS Ganesha cluster not running after restart')
        self._write_to_read_only_export(new_pseudo_path, port, ip)
        self._test_delete_cluster()

    def test_update_export_ro_to_rw(self):
        '''
        Test update of export's access level from ro to rw
        '''
        self._test_create_cluster()
        self._create_export(
            export_id='1', create_fs=True,
            extra_cmd=['--pseudo-path', self.pseudo_path, '--readonly'])
        port, ip = self._get_port_ip_info()
        self._write_to_read_only_export(self.pseudo_path, port, ip)
        original_nfs_container_ids = self._get_nfs_container_ids()
        export_block = self._get_export()
        export_block['access_type'] = 'RW'
        self.ctx.cluster.run(
            args=['ceph', 'nfs', 'export', 'apply', self.cluster_id, '-i', '-'],
            stdin=json.dumps(export_block))
        self._check_nfs_cluster_event('restart', 'NFS Ganesha cluster did not restart')
        self._test_mnt(self.pseudo_path, port, ip)
        self._test_delete_cluster()
