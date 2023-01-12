"""
RBD support module
"""

import enum
import errno
import functools
import inspect
import rados
import rbd
from typing import cast, Any, Callable, Optional, Tuple, TypeVar

from mgr_module import CLIReadCommand, CLIWriteCommand, MgrModule, Option

from .common import NotAuthorizedError
from .mirror_snapshot_schedule import image_validator, namespace_validator, \
    LevelSpec, MirrorSnapshotScheduleHandler
from .perf import PerfHandler, OSD_PERF_QUERY_COUNTERS
from .task import TaskHandler
from .trash_purge_schedule import TrashPurgeScheduleHandler


class ImageSortBy(enum.Enum):
    write_ops = 'write_ops'
    write_bytes = 'write_bytes'
    write_latency = 'write_latency'
    read_ops = 'read_ops'
    read_bytes = 'read_bytes'
    read_latency = 'read_latency'


FuncT = TypeVar('FuncT', bound=Callable)


def handle_cmd(func: FuncT) -> FuncT:
    @functools.wraps(func)
    def wrapper(self: 'Module', *args: Any, **kwargs: Any) -> Tuple[int, str, str]:
        try:
            try:
                return func(self, *args, **kwargs)
            except NotAuthorizedError:
                raise
            except Exception:
                # log the full traceback but don't send it to the CLI user
                self.log.exception("Fatal runtime error: ")
                raise
        except rados.Error as ex:
            return -ex.errno, "", str(ex)
        except rbd.OSError as ex:
            return -ex.errno, "", str(ex)
        except rbd.Error as ex:
            return -errno.EINVAL, "", str(ex)
        except KeyError as ex:
            return -errno.ENOENT, "", str(ex)
        except ValueError as ex:
            return -errno.EINVAL, "", str(ex)
        except NotAuthorizedError as ex:
            return -errno.EACCES, "", str(ex)

    wrapper.__signature__ = inspect.signature(func)  # type: ignore[attr-defined]
    return cast(FuncT, wrapper)


class Module(MgrModule):
    MODULE_OPTIONS = [
        Option(name=MirrorSnapshotScheduleHandler.MODULE_OPTION_NAME),
        Option(name=MirrorSnapshotScheduleHandler.MODULE_OPTION_NAME_MAX_CONCURRENT_SNAP_CREATE,
               type='int',
               default=10),
        Option(name=TrashPurgeScheduleHandler.MODULE_OPTION_NAME),
    ]

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super(Module, self).__init__(*args, **kwargs)
        self.rados.wait_for_latest_osdmap()
        self.mirror_snapshot_schedule = MirrorSnapshotScheduleHandler(self)
        self.perf = PerfHandler(self)
        self.task = TaskHandler(self)
        self.trash_purge_schedule = TrashPurgeScheduleHandler(self)

    def shutdown(self) -> None:
        with self.mirror_snapshot_schedule.lock:
            # calling shutdown after acquiring lock to prevent
            # snapshot async request from being added during shutdown
            self.mirror_snapshot_schedule.shutdown()
        self.trash_purge_schedule.shutdown()
        self.task.shutdown()
        super(Module, self).shutdown()

    @CLIWriteCommand('rbd mirror snapshot schedule add')
    @handle_cmd
    def mirror_snapshot_schedule_add(self,
                                     level_spec: str,
                                     interval: str,
                                     start_time: Optional[str] = None) -> Tuple[int, str, str]:
        """
        Add rbd mirror snapshot schedule
        """
        try:
            spec = LevelSpec.from_name(
                self.mirror_snapshot_schedule, level_spec, namespace_validator, image_validator)
            return self.mirror_snapshot_schedule.add_schedule(spec, interval, start_time)
        except (rbd.ConnectionShutdown, rados.ConnectionShutdown):
            return -errno.EAGAIN, "", "try running the command again"

    @CLIWriteCommand('rbd mirror snapshot schedule remove')
    @handle_cmd
    def mirror_snapshot_schedule_remove(self,
                                        level_spec: str,
                                        interval: Optional[str] = None,
                                        start_time: Optional[str] = None) -> Tuple[int, str, str]:
        """
        Remove rbd mirror snapshot schedule
        """
        try:
            spec = LevelSpec.from_name(
                self.mirror_snapshot_schedule, level_spec, namespace_validator, image_validator)
            return self.mirror_snapshot_schedule.remove_schedule(spec, interval, start_time)
        except (rbd.ConnectionShutdown, rados.ConnectionShutdown):
            return -errno.EAGAIN, "", "try running the command again"

    @CLIReadCommand('rbd mirror snapshot schedule list')
    @handle_cmd
    def mirror_snapshot_schedule_list(self,
                                      level_spec: str = '') -> Tuple[int, str, str]:
        """
        List rbd mirror snapshot schedule
        """
        try:
            spec = LevelSpec.from_name(
                self.mirror_snapshot_schedule, level_spec, namespace_validator, image_validator)
            return self.mirror_snapshot_schedule.list(spec)
        except (rbd.ConnectionShutdown, rados.ConnectionShutdown):
            return -errno.EAGAIN, "", "try running the command again"

    @CLIReadCommand('rbd mirror snapshot schedule status')
    @handle_cmd
    def mirror_snapshot_schedule_status(self,
                                        level_spec: str = '') -> Tuple[int, str, str]:
        """
        Show rbd mirror snapshot schedule status
        """
        try:
            spec = LevelSpec.from_name(
                self.mirror_snapshot_schedule, level_spec, namespace_validator, image_validator)
            return self.mirror_snapshot_schedule.status(spec)
        except (rbd.ConnectionShutdown, rados.ConnectionShutdown):
            return -errno.EAGAIN, "", "try running the command again"

    @CLIReadCommand('rbd perf image stats')
    @handle_cmd
    def perf_image_stats(self,
                         pool_spec: Optional[str] = None,
                         sort_by: Optional[ImageSortBy] = None) -> Tuple[int, str, str]:
        """
        Retrieve current RBD IO performance stats
        """
        with self.perf.lock:
            sort_by_name = sort_by.name if sort_by else OSD_PERF_QUERY_COUNTERS[0]
            return self.perf.get_perf_stats(pool_spec, sort_by_name)

    @CLIReadCommand('rbd perf image counters')
    @handle_cmd
    def perf_image_counters(self,
                            pool_spec: Optional[str] = None,
                            sort_by: Optional[ImageSortBy] = None) -> Tuple[int, str, str]:
        """
        Retrieve current RBD IO performance counters
        """
        with self.perf.lock:
            sort_by_name = sort_by.name if sort_by else OSD_PERF_QUERY_COUNTERS[0]
            return self.perf.get_perf_counters(pool_spec, sort_by_name)

    @CLIWriteCommand('rbd task add flatten')
    @handle_cmd
    def task_add_flatten(self, image_spec: str) -> Tuple[int, str, str]:
        """
        Flatten a cloned image asynchronously in the background
        """
        with self.task.lock:
            try:
                self.task.rados.wait_for_latest_osdmap()
                return self.task.queue_flatten(image_spec)
            except (rados.ConnectionShutdown, rbd.ConnectionShutdown):
                self.log.info("TaskHandler: trying to reconnect after client blocklisted")
                self.task.reconnect()
                return -errno.EAGAIN, "", "try running the command again"

    @CLIWriteCommand('rbd task add remove')
    @handle_cmd
    def task_add_remove(self, image_spec: str) -> Tuple[int, str, str]:
        """
        Remove an image asynchronously in the background
        """
        with self.task.lock:
            try:
                self.task.rados.wait_for_latest_osdmap()
                return self.task.queue_remove(image_spec)
            except (rados.ConnectionShutdown, rbd.ConnectionShutdown):
                self.log.info("TaskHandler: trying to reconnect after client blocklisted")
                self.task.reconnect()
                return -errno.EAGAIN, "", "try running the command again"

    @CLIWriteCommand('rbd task add trash remove')
    @handle_cmd
    def task_add_trash_remove(self, image_id_spec: str) -> Tuple[int, str, str]:
        """
        Remove an image from the trash asynchronously in the background
        """
        with self.task.lock:
            try:
                self.task.rados.wait_for_latest_osdmap()
                return self.task.queue_trash_remove(image_id_spec)
            except (rados.ConnectionShutdown, rbd.ConnectionShutdown):
                self.log.info("TaskHandler: trying to reconnect after client blocklisted")
                self.task.reconnect()
                return -errno.EAGAIN, "", "try running the command again"

    @CLIWriteCommand('rbd task add migration execute')
    @handle_cmd
    def task_add_migration_execute(self, image_spec: str) -> Tuple[int, str, str]:
        """
        Execute an image migration asynchronously in the background
        """
        with self.task.lock:
            try:
                self.task.rados.wait_for_latest_osdmap()
                return self.task.queue_migration_execute(image_spec)
            except (rados.ConnectionShutdown, rbd.ConnectionShutdown):
                self.log.info("TaskHandler: trying to reconnect after client blocklisted")
                self.task.reconnect()
                return -errno.EAGAIN, "", "try running the command again"

    @CLIWriteCommand('rbd task add migration commit')
    @handle_cmd
    def task_add_migration_commit(self, image_spec: str) -> Tuple[int, str, str]:
        """
        Commit an executed migration asynchronously in the background
        """
        with self.task.lock:
            try:
                self.task.rados.wait_for_latest_osdmap()
                return self.task.queue_migration_commit(image_spec)
            except (rados.ConnectionShutdown, rbd.ConnectionShutdown):
                self.log.info("TaskHandler: trying to reconnect after client blocklisted")
                self.task.reconnect()
                return -errno.EAGAIN, "", "try running the command again"

    @CLIWriteCommand('rbd task add migration abort')
    @handle_cmd
    def task_add_migration_abort(self, image_spec: str) -> Tuple[int, str, str]:
        """
        Abort a prepared migration asynchronously in the background
        """
        with self.task.lock:
            try:
                self.task.rados.wait_for_latest_osdmap()
                return self.task.queue_migration_abort(image_spec)
            except (rados.ConnectionShutdown, rbd.ConnectionShutdown):
                self.log.info("TaskHandler: trying to reconnect after client blocklisted")
                self.task.reconnect()
                return -errno.EAGAIN, "", "try running the command again"

    @CLIWriteCommand('rbd task cancel')
    @handle_cmd
    def task_cancel(self, task_id: str) -> Tuple[int, str, str]:
        """
        Cancel a pending or running asynchronous task
        """
        with self.task.lock:
            try:
                self.task.rados.wait_for_latest_osdmap()
                return self.task.task_cancel(task_id)
            except (rados.ConnectionShutdown, rbd.ConnectionShutdown):
                self.log.info("TaskHandler: trying to reconnect after client blocklisted")
                self.task.reconnect()
                return -errno.EAGAIN, "", "try running the command again"

    @CLIReadCommand('rbd task list')
    @handle_cmd
    def task_list(self, task_id: Optional[str] = None) -> Tuple[int, str, str]:
        """
        List pending or running asynchronous tasks
        """
        with self.task.lock:
            try:
                self.task.rados.wait_for_latest_osdmap()
                return self.task.task_list(task_id)
            except (rados.ConnectionShutdown, rbd.ConnectionShutdown):
                self.log.info("TaskHandler: trying to reconnect after client blocklisted")
                self.task.reconnect()
                return -errno.EAGAIN, "", "try running the command again"

    @CLIWriteCommand('rbd trash purge schedule add')
    @handle_cmd
    def trash_purge_schedule_add(self,
                                 level_spec: str,
                                 interval: str,
                                 start_time: Optional[str] = None) -> Tuple[int, str, str]:
        """
        Add rbd trash purge schedule
        """
        try:
            spec = LevelSpec.from_name(
                self.trash_purge_schedule, level_spec, allow_image_level=False)
            return self.trash_purge_schedule.add_schedule(spec, interval, start_time)
        except (rbd.ConnectionShutdown, rados.ConnectionShutdown):
            return -errno.EAGAIN, "", "try running the command again"

    @CLIWriteCommand('rbd trash purge schedule remove')
    @handle_cmd
    def trash_purge_schedule_remove(self,
                                    level_spec: str,
                                    interval: Optional[str] = None,
                                    start_time: Optional[str] = None) -> Tuple[int, str, str]:
        """
        Remove rbd trash purge schedule
        """
        try:
            spec = LevelSpec.from_name(
                self.trash_purge_schedule, level_spec, allow_image_level=False)
            return self.trash_purge_schedule.remove_schedule(spec, interval, start_time)
        except (rbd.ConnectionShutdown, rados.ConnectionShutdown):
            return -errno.EAGAIN, "", "try running the command again"

    @CLIReadCommand('rbd trash purge schedule list')
    @handle_cmd
    def trash_purge_schedule_list(self,
                                  level_spec: str = '') -> Tuple[int, str, str]:
        """
        List rbd trash purge schedule
        """
        try:
            spec = LevelSpec.from_name(
                self.trash_purge_schedule, level_spec, allow_image_level=False)
            return self.trash_purge_schedule.list(spec)
        except (rbd.ConnectionShutdown, rados.ConnectionShutdown):
            return -errno.EAGAIN, "", "try running the command again"

    @CLIReadCommand('rbd trash purge schedule status')
    @handle_cmd
    def trash_purge_schedule_status(self,
                                    level_spec: str = '') -> Tuple[int, str, str]:
        """
        Show rbd trash purge schedule status
        """
        try:
            spec = LevelSpec.from_name(
                self.trash_purge_schedule, level_spec, allow_image_level=False)
            return self.trash_purge_schedule.status(spec)
        except (rbd.ConnectionShutdown, rados.ConnectionShutdown):
            return -errno.EAGAIN, "", "try running the command again"
