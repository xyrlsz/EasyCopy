import 'dart:async';
import 'dart:io';

import 'package:easy_copy/models/app_preferences.dart';
import 'package:easy_copy/models/page_models.dart';
import 'package:easy_copy/services/app_preferences_controller.dart';
import 'package:easy_copy/services/comic_download_service.dart';
import 'package:easy_copy/services/download_storage_service.dart';
import 'package:easy_copy/services/download_queue_store.dart';
import 'package:flutter/foundation.dart';

typedef DownloadQueueLibraryChangedCallback = Future<void> Function();
typedef DownloadQueueNoticeCallback = void Function(String message);

abstract class DownloadTaskRunner {
  Future<ReaderPageData> prepare(DownloadQueueTask task);

  Future<void> download(
    DownloadQueueTask task,
    ReaderPageData page, {
    required ChapterDownloadPauseChecker shouldPause,
    required ChapterDownloadCancelChecker shouldCancel,
    ChapterDownloadProgressCallback? onProgress,
  });
}

class DownloadQueueManager {
  DownloadQueueManager({
    required AppPreferencesController preferencesController,
    required ComicDownloadService downloadService,
    required DownloadQueueStore queueStore,
    required DownloadTaskRunner taskRunner,
    DownloadQueueLibraryChangedCallback? onLibraryChanged,
    DownloadQueueNoticeCallback? onNotice,
  }) : _preferencesController = preferencesController,
       _downloadService = downloadService,
       _queueStore = queueStore,
       _taskRunner = taskRunner,
       _onLibraryChanged = onLibraryChanged,
       _onNotice = onNotice;

  final AppPreferencesController _preferencesController;
  final ComicDownloadService _downloadService;
  final DownloadQueueStore _queueStore;
  final DownloadTaskRunner _taskRunner;
  final DownloadQueueLibraryChangedCallback? _onLibraryChanged;
  final DownloadQueueNoticeCallback? _onNotice;

  final ValueNotifier<DownloadQueueSnapshot> snapshotNotifier =
      ValueNotifier<DownloadQueueSnapshot>(const DownloadQueueSnapshot());
  final ValueNotifier<DownloadStorageState> storageStateNotifier =
      ValueNotifier<DownloadStorageState>(const DownloadStorageState.loading());
  final ValueNotifier<bool> storageBusyNotifier = ValueNotifier<bool>(false);

  final Map<String, List<DownloadQueueTask>> _pendingCancelledTaskCleanups =
      <String, List<DownloadQueueTask>>{};
  final Map<String, String> _pendingCancelledComicDeletions =
      <String, String>{};

  bool _isProcessingQueue = false;
  bool _disposed = false;

  DownloadQueueSnapshot get snapshot => snapshotNotifier.value;

  DownloadStorageState get storageState => storageStateNotifier.value;

  bool get supportsCustomStorageSelection =>
      _downloadService.supportsCustomStorageSelection;

  Future<void> restoreState() async {
    await _queueStore.ensureInitialized();
    await refreshStorageState();
    if (_disposed) {
      return;
    }
    snapshotNotifier.value = await _queueStore.read();
  }

  Future<void> restoreQueue() async {
    await _queueStore.ensureInitialized();
    if (_disposed) {
      return;
    }
    snapshotNotifier.value = await _queueStore.read();
  }

  Future<void> refreshStorageState({DownloadPreferences? preferences}) async {
    final DownloadStorageState nextState = await _downloadService
        .resolveStorageState(preferences: preferences);
    if (_disposed) {
      return;
    }
    storageStateNotifier.value = nextState;
  }

  Future<bool> addTasks(Iterable<DownloadQueueTask> newTasks) async {
    final List<DownloadQueueTask> additions = newTasks.toList(growable: false);
    if (additions.isEmpty) {
      return snapshot.isPaused && snapshot.isNotEmpty;
    }

    final DownloadQueueSnapshot currentSnapshot = snapshot;
    final bool keepPaused =
        currentSnapshot.isPaused && currentSnapshot.isNotEmpty;
    await _persistSnapshot(
      currentSnapshot.copyWith(
        isPaused: keepPaused,
        tasks: <DownloadQueueTask>[
          ...currentSnapshot.tasks,
          ...additions,
        ].toList(growable: false),
      ),
    );
    if (!keepPaused) {
      unawaited(ensureRunning());
    }
    return keepPaused;
  }

  Future<void> pauseQueue() async {
    final DownloadQueueSnapshot currentSnapshot = snapshot;
    if (currentSnapshot.isEmpty || currentSnapshot.isPaused) {
      return;
    }
    await _persistSnapshot(currentSnapshot.copyWith(isPaused: true));
  }

  Future<void> resumeQueue() async {
    final DownloadQueueSnapshot currentSnapshot = snapshot;
    if (currentSnapshot.isEmpty) {
      return;
    }

    final DateTime now = DateTime.now();
    final List<DownloadQueueTask> tasks = currentSnapshot.tasks
        .map((DownloadQueueTask task) {
          if (task.status == DownloadQueueTaskStatus.failed ||
              task.status == DownloadQueueTaskStatus.paused ||
              task.status == DownloadQueueTaskStatus.parsing ||
              task.status == DownloadQueueTaskStatus.downloading) {
            return task.copyWith(
              status: DownloadQueueTaskStatus.queued,
              progressLabel: '等待缓存',
              errorMessage: '',
              updatedAt: now,
            );
          }
          return task;
        })
        .toList(growable: false);

    await _persistSnapshot(
      currentSnapshot.copyWith(isPaused: false, tasks: tasks),
    );
    unawaited(ensureRunning());
  }

  Future<void> retryTask(DownloadQueueTask task) async {
    final DownloadQueueSnapshot currentSnapshot = snapshot;
    final int index = currentSnapshot.tasks.indexWhere(
      (DownloadQueueTask item) => item.id == task.id,
    );
    if (index == -1) {
      return;
    }

    final DateTime now = DateTime.now();
    final List<DownloadQueueTask> tasks = currentSnapshot.tasks.toList(
      growable: true,
    );
    tasks[index] = task.copyWith(
      status: DownloadQueueTaskStatus.queued,
      progressLabel: '等待缓存',
      errorMessage: '',
      updatedAt: now,
    );

    final bool shouldResume =
        currentSnapshot.isPaused &&
        currentSnapshot.activeTask?.id == task.id &&
        task.status == DownloadQueueTaskStatus.failed;
    await _persistSnapshot(
      currentSnapshot.copyWith(
        isPaused: shouldResume ? false : currentSnapshot.isPaused,
        tasks: tasks.toList(growable: false),
      ),
    );
    if (shouldResume || !currentSnapshot.isPaused) {
      unawaited(ensureRunning());
    }
  }

  Future<void> removeQueuedComic(DownloadQueueTask task) async {
    final bool removesActiveComic =
        snapshot.activeTask?.comicKey == task.comicKey;
    final List<DownloadQueueTask> removedTasks = await _removeComicFromQueue(
      task.comicKey,
    );
    if (!removesActiveComic) {
      await _downloadService.cleanupIncompleteTasks(removedTasks);
      await _notifyLibraryChanged();
    }
  }

  Future<void> removeQueuedTask(DownloadQueueTask task) async {
    final bool removesActiveTask = snapshot.activeTask?.id == task.id;
    await _removeTaskFromQueue(task);
    if (!removesActiveTask) {
      await _downloadService.cleanupIncompleteTasks(<DownloadQueueTask>[task]);
      await _notifyLibraryChanged();
    }
  }

  Future<void> deleteCachedComic(
    CachedComicLibraryEntry entry, {
    required String comicKey,
  }) async {
    final DownloadQueueTask? activeTask = snapshot.activeTask;
    final bool removesActiveComic = activeTask?.comicKey == comicKey;
    final List<DownloadQueueTask> removedTasks = await _removeComicFromQueue(
      comicKey,
    );

    if (!removesActiveComic) {
      await _downloadService.cleanupIncompleteTasks(removedTasks);
      await _downloadService.deleteCachedComic(entry);
      await _notifyLibraryChanged();
      return;
    }

    if (activeTask != null) {
      _pendingCancelledComicDeletions[activeTask.id] = entry.comicTitle;
    }
  }

  String? storageEditBlockReason() {
    if (storageBusyNotifier.value) {
      return '正在切换缓存目录，请稍后再试';
    }
    if (snapshot.isNotEmpty && !snapshot.isPaused) {
      return '请先暂停缓存队列后再切换缓存目录';
    }
    return null;
  }

  Future<List<DownloadStorageState>> loadStorageCandidates() {
    return _downloadService.loadCustomDirectoryCandidates();
  }

  Future<DownloadStorageMigrationResult?> applyStoragePreferences(
    DownloadPreferences nextPreferences,
  ) async {
    final DownloadPreferences currentPreferences =
        _preferencesController.downloadPreferences;
    if (currentPreferences.mode == nextPreferences.mode &&
        currentPreferences.customBasePath == nextPreferences.customBasePath) {
      return null;
    }

    if (!_disposed) {
      storageBusyNotifier.value = true;
    }
    try {
      final DownloadStorageMigrationResult result = await _downloadService
          .migrateCacheRoot(from: currentPreferences, to: nextPreferences);
      await _preferencesController.updateDownloadPreferences(
        (_) => nextPreferences,
      );
      if (!_disposed) {
        storageStateNotifier.value = result.storageState;
      }
      await _notifyLibraryChanged();
      return result;
    } catch (_) {
      await refreshStorageState();
      rethrow;
    } finally {
      if (!_disposed) {
        storageBusyNotifier.value = false;
      }
    }
  }

  Future<void> ensureRunning() async {
    if (_disposed ||
        _isProcessingQueue ||
        snapshot.isPaused ||
        snapshot.isEmpty) {
      return;
    }

    final DownloadStorageState nextStorageState = await _downloadService
        .resolveStorageState();
    if (_disposed) {
      return;
    }
    storageStateNotifier.value = nextStorageState;
    if (!nextStorageState.isReady) {
      await _persistSnapshot(snapshot.copyWith(isPaused: true));
      _notify(
        nextStorageState.errorMessage.isEmpty
            ? '缓存目录不可用，请检查下载管理页中的目录设置。'
            : '缓存目录不可用：${nextStorageState.errorMessage}',
      );
      return;
    }

    _isProcessingQueue = true;
    try {
      while (!_disposed) {
        final DownloadQueueSnapshot currentSnapshot = snapshot;
        if (currentSnapshot.isPaused || currentSnapshot.isEmpty) {
          break;
        }
        await _runTask(currentSnapshot.activeTask!);
      }
    } finally {
      _isProcessingQueue = false;
    }
  }

  void dispose() {
    _disposed = true;
    snapshotNotifier.dispose();
    storageStateNotifier.dispose();
    storageBusyNotifier.dispose();
  }

  Future<void> _persistSnapshot(DownloadQueueSnapshot nextSnapshot) async {
    if (_disposed) {
      return;
    }
    snapshotNotifier.value = nextSnapshot;
    if (nextSnapshot.isEmpty) {
      await _queueStore.clear();
      return;
    }
    await _queueStore.write(nextSnapshot);
  }

  Future<List<DownloadQueueTask>> _removeComicFromQueue(String comicKey) async {
    final DownloadQueueSnapshot currentSnapshot = snapshot;
    if (currentSnapshot.isEmpty) {
      return const <DownloadQueueTask>[];
    }

    final List<DownloadQueueTask> removedTasks = currentSnapshot.tasks
        .where((DownloadQueueTask task) => task.comicKey == comicKey)
        .toList(growable: false);
    if (removedTasks.isEmpty) {
      return const <DownloadQueueTask>[];
    }

    final DownloadQueueTask? activeTask = currentSnapshot.activeTask;
    final bool removesActiveComic = activeTask?.comicKey == comicKey;
    final List<DownloadQueueTask> remainingTasks = currentSnapshot.tasks
        .where((DownloadQueueTask task) => task.comicKey != comicKey)
        .toList(growable: false);

    if (removesActiveComic && activeTask != null) {
      _pendingCancelledTaskCleanups[activeTask.id] = removedTasks;
    }

    await _persistSnapshot(
      currentSnapshot.copyWith(
        isPaused: remainingTasks.isEmpty ? false : currentSnapshot.isPaused,
        tasks: remainingTasks,
      ),
    );
    return removedTasks;
  }

  Future<void> _removeTaskFromQueue(DownloadQueueTask task) async {
    final DownloadQueueSnapshot currentSnapshot = snapshot;
    if (currentSnapshot.isEmpty) {
      return;
    }

    final bool containsTask = currentSnapshot.tasks.any(
      (DownloadQueueTask item) => item.id == task.id,
    );
    if (!containsTask) {
      return;
    }

    final bool removesActiveTask = currentSnapshot.activeTask?.id == task.id;
    final List<DownloadQueueTask> remainingTasks = currentSnapshot.tasks
        .where((DownloadQueueTask item) => item.id != task.id)
        .toList(growable: false);
    if (removesActiveTask) {
      _pendingCancelledTaskCleanups[task.id] = <DownloadQueueTask>[task];
    }
    await _persistSnapshot(
      currentSnapshot.copyWith(
        isPaused: remainingTasks.isEmpty ? false : currentSnapshot.isPaused,
        tasks: remainingTasks,
      ),
    );
  }

  DownloadQueueTask? _taskById(String taskId) {
    for (final DownloadQueueTask task in snapshot.tasks) {
      if (task.id == taskId) {
        return task;
      }
    }
    return null;
  }

  Future<void> _updateTask(
    DownloadQueueTask updatedTask, {
    bool persist = true,
  }) async {
    final DownloadQueueSnapshot currentSnapshot = snapshot;
    final int index = currentSnapshot.tasks.indexWhere(
      (DownloadQueueTask task) => task.id == updatedTask.id,
    );
    if (index == -1 || _disposed) {
      return;
    }

    final List<DownloadQueueTask> tasks = currentSnapshot.tasks.toList(
      growable: true,
    );
    tasks[index] = updatedTask;
    final DownloadQueueSnapshot nextSnapshot = currentSnapshot.copyWith(
      tasks: tasks.toList(growable: false),
    );
    if (persist) {
      await _persistSnapshot(nextSnapshot);
      return;
    }
    snapshotNotifier.value = nextSnapshot;
  }

  bool _shouldPauseActiveDownload(DownloadQueueTask task) {
    return !_disposed && snapshot.isPaused && _taskById(task.id) != null;
  }

  bool _shouldCancelActiveDownload(DownloadQueueTask task) {
    return _disposed || _taskById(task.id) == null;
  }

  Future<void> _runTask(DownloadQueueTask task) async {
    await _updateTask(
      task.copyWith(
        status: DownloadQueueTaskStatus.parsing,
        progressLabel: '正在解析 ${task.chapterLabel}',
        completedImages: 0,
        totalImages: 0,
        errorMessage: '',
        updatedAt: DateTime.now(),
      ),
    );

    try {
      final ReaderPageData readerPage = await _taskRunner.prepare(task);

      if (_shouldCancelActiveDownload(task)) {
        throw const DownloadCancelledException();
      }
      if (_shouldPauseActiveDownload(task)) {
        throw const DownloadPausedException();
      }

      await _updateTask(
        task.copyWith(
          status: DownloadQueueTaskStatus.downloading,
          progressLabel: '正在缓存 ${task.chapterLabel}',
          completedImages: 0,
          totalImages: readerPage.imageUrls.length,
          errorMessage: '',
          updatedAt: DateTime.now(),
        ),
      );

      await _taskRunner.download(
        task,
        readerPage,
        shouldPause: () => _shouldPauseActiveDownload(task),
        shouldCancel: () => _shouldCancelActiveDownload(task),
        onProgress: (ChapterDownloadProgress progress) async {
          final DownloadQueueTask? latestTask = _taskById(task.id);
          if (latestTask == null || _disposed) {
            return;
          }
          await _updateTask(
            latestTask.copyWith(
              status: DownloadQueueTaskStatus.downloading,
              progressLabel: '${task.chapterLabel} · ${progress.currentLabel}',
              completedImages: progress.completedCount,
              totalImages: progress.totalCount,
              errorMessage: '',
              updatedAt: DateTime.now(),
            ),
            persist: false,
          );
        },
      );

      final DownloadQueueSnapshot currentSnapshot = snapshot;
      final List<DownloadQueueTask> remainingTasks = currentSnapshot.tasks
          .where((DownloadQueueTask item) => item.id != task.id)
          .toList(growable: false);
      await _persistSnapshot(
        currentSnapshot.copyWith(
          isPaused: remainingTasks.isEmpty ? false : currentSnapshot.isPaused,
          tasks: remainingTasks,
        ),
      );
      await _notifyLibraryChanged();

      if (remainingTasks.isEmpty) {
        _notify('后台缓存已完成');
      }
    } on DownloadPausedException {
      final DownloadQueueTask? latestTask = _taskById(task.id);
      if (latestTask != null) {
        final String pauseLabel =
            latestTask.totalImages > 0 && latestTask.completedImages > 0
            ? '已暂停 ${latestTask.completedImages}/${latestTask.totalImages}'
            : '已暂停';
        await _updateTask(
          latestTask.copyWith(
            status: DownloadQueueTaskStatus.paused,
            progressLabel: pauseLabel,
            updatedAt: DateTime.now(),
          ),
        );
      }
    } on DownloadCancelledException {
      final List<DownloadQueueTask> tasksToCleanup =
          _pendingCancelledTaskCleanups.remove(task.id) ??
          <DownloadQueueTask>[task];
      final String? comicDeletionTitle = _pendingCancelledComicDeletions.remove(
        task.id,
      );
      if (comicDeletionTitle != null) {
        await _downloadService.deleteComicCacheByTitle(comicDeletionTitle);
      } else {
        await _downloadService.cleanupIncompleteTasks(tasksToCleanup);
      }
      await _notifyLibraryChanged();
    } catch (error) {
      final DownloadQueueTask? latestTask = _taskById(task.id);
      final String message = _formatDownloadError(error);
      if (latestTask != null) {
        final DownloadQueueSnapshot currentSnapshot = snapshot;
        final List<DownloadQueueTask> tasks = currentSnapshot.tasks
            .map((DownloadQueueTask item) {
              if (item.id != latestTask.id) {
                return item;
              }
              return latestTask.copyWith(
                status: DownloadQueueTaskStatus.failed,
                progressLabel: '失败：$message',
                errorMessage: message,
                updatedAt: DateTime.now(),
              );
            })
            .toList(growable: false);
        await _persistSnapshot(
          currentSnapshot.copyWith(isPaused: true, tasks: tasks),
        );
      }
      _notify('缓存失败：$message');
    }
  }

  Future<void> _notifyLibraryChanged() async {
    if (_disposed || _onLibraryChanged == null) {
      return;
    }
    await _onLibraryChanged();
  }

  void _notify(String message) {
    if (_disposed || message.trim().isEmpty) {
      return;
    }
    _onNotice?.call(message);
  }

  String _formatDownloadError(Object error) {
    return switch (error) {
      TimeoutException _ => '章节解析超时',
      HttpException httpError => httpError.message,
      FileSystemException fileError => fileError.message,
      DownloadPausedException paused => paused.message,
      DownloadCancelledException cancelled => cancelled.message,
      _ => error.toString(),
    };
  }
}
