import 'dart:io';

import 'package:easy_copy/models/app_preferences.dart';
import 'package:easy_copy/services/app_preferences_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

typedef DownloadPreferencesProvider = Future<DownloadPreferences> Function();
typedef DownloadBaseDirectoryProvider = Future<Directory> Function();

@immutable
class DownloadStorageState {
  const DownloadStorageState({
    required this.preferences,
    required this.basePath,
    required this.rootPath,
    required this.isCustom,
    required this.isWritable,
    required this.mayBeRemovedOnUninstall,
    this.errorMessage = '',
    this.isLoading = false,
  });

  const DownloadStorageState.loading()
    : preferences = const DownloadPreferences(),
      basePath = '',
      rootPath = '',
      isCustom = false,
      isWritable = false,
      mayBeRemovedOnUninstall = false,
      errorMessage = '',
      isLoading = true;

  final DownloadPreferences preferences;
  final String basePath;
  final String rootPath;
  final bool isCustom;
  final bool isWritable;
  final bool mayBeRemovedOnUninstall;
  final String errorMessage;
  final bool isLoading;

  bool get isReady =>
      !isLoading &&
      errorMessage.isEmpty &&
      rootPath.trim().isNotEmpty &&
      isWritable;

  String get displayPath => rootPath.trim().isNotEmpty ? rootPath : basePath;
}

class DownloadStorageService {
  DownloadStorageService({
    AppPreferencesController? preferencesController,
    DownloadPreferencesProvider? preferencesProvider,
    DownloadBaseDirectoryProvider? defaultBaseDirectoryProvider,
  }) : _preferencesController =
           preferencesController ?? AppPreferencesController.instance,
       _preferencesProvider = preferencesProvider,
       _defaultBaseDirectoryProvider =
           defaultBaseDirectoryProvider ?? _defaultBaseDirectory;

  static final DownloadStorageService instance = DownloadStorageService();
  static const String downloadsDirectoryName = 'EasyCopyDownloads';

  final AppPreferencesController _preferencesController;
  final DownloadPreferencesProvider? _preferencesProvider;
  final DownloadBaseDirectoryProvider _defaultBaseDirectoryProvider;

  bool get supportsCustomDirectorySelection => Platform.isAndroid;

  Future<DownloadStorageState> resolveState({
    DownloadPreferences? preferences,
    bool verifyWritable = true,
  }) async {
    final DownloadPreferences resolvedPreferences =
        preferences ?? await _loadPreferences();
    final String rawBasePath = resolvedPreferences.usesCustomDirectory
        ? resolvedPreferences.customBasePath.trim()
        : (await _defaultBaseDirectoryProvider()).path;
    final bool isCustom = resolvedPreferences.usesCustomDirectory;
    if (rawBasePath.isEmpty) {
      return DownloadStorageState(
        preferences: resolvedPreferences,
        basePath: '',
        rootPath: '',
        isCustom: isCustom,
        isWritable: false,
        mayBeRemovedOnUninstall: _mayBeRemovedOnUninstall(isCustom: isCustom),
        errorMessage: isCustom ? '尚未设置自定义缓存目录。' : '默认缓存目录不可用。',
      );
    }

    final Directory baseDirectory = Directory(rawBasePath);
    final Directory rootDirectory = Directory(
      _joinPath(<String>[baseDirectory.path, downloadsDirectoryName]),
    );
    try {
      await rootDirectory.create(recursive: true);
      if (verifyWritable) {
        await _verifyWritable(rootDirectory);
      }
      return DownloadStorageState(
        preferences: resolvedPreferences,
        basePath: baseDirectory.path,
        rootPath: rootDirectory.path,
        isCustom: isCustom,
        isWritable: true,
        mayBeRemovedOnUninstall: _mayBeRemovedOnUninstall(isCustom: isCustom),
      );
    } on FileSystemException catch (error) {
      return DownloadStorageState(
        preferences: resolvedPreferences,
        basePath: baseDirectory.path,
        rootPath: rootDirectory.path,
        isCustom: isCustom,
        isWritable: false,
        mayBeRemovedOnUninstall: _mayBeRemovedOnUninstall(isCustom: isCustom),
        errorMessage: error.message,
      );
    } catch (error) {
      return DownloadStorageState(
        preferences: resolvedPreferences,
        basePath: baseDirectory.path,
        rootPath: rootDirectory.path,
        isCustom: isCustom,
        isWritable: false,
        mayBeRemovedOnUninstall: _mayBeRemovedOnUninstall(isCustom: isCustom),
        errorMessage: error.toString(),
      );
    }
  }

  String summarizePath(String path) {
    final String normalized = path.trim();
    if (normalized.isEmpty) {
      return '未设置';
    }
    if (normalized.length <= 42) {
      return normalized;
    }
    final int separatorIndex = normalized.lastIndexOf(Platform.pathSeparator);
    if (separatorIndex <= 0 || separatorIndex == normalized.length - 1) {
      return '...${normalized.substring(normalized.length - 39)}';
    }
    final String tail = normalized.substring(separatorIndex);
    final int headLength = 39 - tail.length;
    if (headLength <= 4) {
      return '...$tail';
    }
    return '${normalized.substring(0, headLength)}...$tail';
  }

  Future<DownloadPreferences> _loadPreferences() async {
    if (_preferencesProvider != null) {
      return _preferencesProvider();
    }
    await _preferencesController.ensureInitialized();
    return _preferencesController.downloadPreferences;
  }

  bool _mayBeRemovedOnUninstall({required bool isCustom}) {
    if (isCustom) {
      return false;
    }
    return Platform.isAndroid || Platform.isIOS;
  }

  Future<void> _verifyWritable(Directory rootDirectory) async {
    final File probe = File(
      _joinPath(<String>[
        rootDirectory.path,
        '.storage_probe_${DateTime.now().microsecondsSinceEpoch}',
      ]),
    );
    await probe.writeAsString('ok', flush: true);
    if (await probe.exists()) {
      await probe.delete();
    }
  }

  String _joinPath(List<String> segments) {
    return segments.join(Platform.pathSeparator);
  }

  static Future<Directory> _defaultBaseDirectory() async {
    if (Platform.isAndroid) {
      return (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
    }
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return (await getDownloadsDirectory()) ??
          await getApplicationDocumentsDirectory();
    }
    return await getApplicationDocumentsDirectory();
  }
}
