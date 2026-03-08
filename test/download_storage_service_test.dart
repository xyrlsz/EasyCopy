import 'dart:io';

import 'package:easy_copy/models/app_preferences.dart';
import 'package:easy_copy/services/download_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('download storage service resolves the default cache root', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'easy_copy_storage_default_',
    );
    addTearDown(() => tempDir.delete(recursive: true));

    final DownloadStorageService service = DownloadStorageService(
      preferencesProvider: () async => const DownloadPreferences(),
      defaultBaseDirectoryProvider: () async => tempDir,
    );

    final DownloadStorageState state = await service.resolveState();

    expect(state.isReady, isTrue);
    expect(
      state.rootPath,
      '${tempDir.path}${Platform.pathSeparator}'
      '${DownloadStorageService.downloadsDirectoryName}',
    );
    expect(Directory(state.rootPath).existsSync(), isTrue);
  });

  test(
    'download storage service uses a custom base path when configured',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'easy_copy_storage_custom_',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final DownloadStorageService service = DownloadStorageService(
        preferencesProvider: () async => DownloadPreferences(
          mode: DownloadStorageMode.customDirectory,
          customBasePath: tempDir.path,
        ),
      );

      final DownloadStorageState state = await service.resolveState();

      expect(state.isReady, isTrue);
      expect(state.isCustom, isTrue);
      expect(state.basePath, tempDir.path);
    },
  );

  test('download storage service reports an invalid custom path', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'easy_copy_storage_invalid_',
    );
    addTearDown(() => tempDir.delete(recursive: true));
    final File invalidBase = File(
      '${tempDir.path}${Platform.pathSeparator}not-a-directory.txt',
    );
    await invalidBase.writeAsString('demo');

    final DownloadStorageService service = DownloadStorageService(
      preferencesProvider: () async => DownloadPreferences(
        mode: DownloadStorageMode.customDirectory,
        customBasePath: invalidBase.path,
      ),
    );

    final DownloadStorageState state = await service.resolveState();

    expect(state.isReady, isFalse);
    expect(state.errorMessage, isNotEmpty);
  });
}
