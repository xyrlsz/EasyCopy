import 'dart:io';

import 'package:easy_copy/models/app_preferences.dart';
import 'package:easy_copy/services/app_preferences_controller.dart';
import 'package:easy_copy/services/app_preferences_store.dart';
import 'package:easy_copy/services/comic_download_service.dart';
import 'package:easy_copy/services/download_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test(
    'cleanupStorageDirectory skips non-owned entries for picked root',
    () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'easycopy_cleanup_',
      );
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final File userFile = File(
        '${root.path}${Platform.pathSeparator}user.txt',
      );
      await userFile.writeAsString('keep');
      final Directory userDir = Directory(
        '${root.path}${Platform.pathSeparator}UserStuff',
      );
      await userDir.create();
      await File(
        '${userDir.path}${Platform.pathSeparator}note.txt',
      ).writeAsString('keep');

      final Directory appDir = Directory(
        '${root.path}${Platform.pathSeparator}ComicA',
      );
      await appDir.create();
      await File(
        '${appDir.path}${Platform.pathSeparator}.easycopy_comic',
      ).writeAsString('owned');

      final DownloadPreferences prefs = DownloadPreferences(
        mode: DownloadStorageMode.customDirectory,
        customBasePath: root.path,
        usePickedDirectoryAsRoot: true,
      );

      final AppPreferencesController prefsController = AppPreferencesController(
        store: AppPreferencesStore(directoryProvider: () async => root),
      );
      final DownloadStorageService storageService = DownloadStorageService(
        preferencesController: prefsController,
      );
      final ComicDownloadService service = ComicDownloadService(
        storageService: storageService,
      );

      final String warning = await service.cleanupStorageDirectory(
        preferences: prefs,
      );

      expect(warning, isNotEmpty);
      expect(await userFile.exists(), isTrue);
      expect(await userDir.exists(), isTrue);
      expect(await appDir.exists(), isFalse);
    },
  );
}
