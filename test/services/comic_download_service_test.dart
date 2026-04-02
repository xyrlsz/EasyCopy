import 'dart:convert';
import 'dart:io';

import 'package:easy_copy/models/app_preferences.dart';
import 'package:easy_copy/services/cached_library_index_store.dart';
import 'package:easy_copy/services/comic_download_service.dart';
import 'package:easy_copy/services/download_storage_service.dart';
import 'package:easy_copy/services/migration_delta_journal_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ComicDownloadService', () {
    late Directory tempDirectory;
    late CachedLibraryIndexStore indexStore;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'easy_copy_download_service_test_',
      );
      indexStore = CachedLibraryIndexStore(
        directoryProvider: () async => tempDirectory,
      );
    });

    tearDown(() async {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    ComicDownloadService createService() {
      return ComicDownloadService(
        baseDirectoryProvider: () async => tempDirectory,
        cachedLibraryIndexStore: indexStore,
      );
    }

    Directory defaultRoot() {
      return Directory(
        '${tempDirectory.path}${Platform.pathSeparator}'
        '${DownloadStorageService.downloadsDirectoryName}',
      );
    }

    test(
      'loadCachedLibrary rebuilds index once and reuses stored index',
      () async {
        final ComicDownloadService service = createService();
        final Directory chapterDirectory = Directory(
          '${defaultRoot().path}${Platform.pathSeparator}Comic A'
          '${Platform.pathSeparator}Chapter 1',
        );
        await chapterDirectory.create(recursive: true);
        await File(
          '${chapterDirectory.path}${Platform.pathSeparator}001.jpg',
        ).writeAsString('image');
        await File(
          '${chapterDirectory.path}${Platform.pathSeparator}manifest.json',
        ).writeAsString(
          jsonEncode(<String, Object?>{
            'comicTitle': 'Comic A',
            'comicUri': 'https://example.com/comic/a',
            'coverUrl': 'https://example.com/cover-a.jpg',
            'chapterLabel': 'Chapter 1',
            'chapterHref': 'https://example.com/comic/a/chapter/1',
            'sourceUri': 'https://example.com/comic/a/chapter/1',
            'downloadedAt': DateTime(2026, 4, 1).toIso8601String(),
            'files': <String>['001.jpg'],
            'imageCount': 1,
          }),
        );

        final List<CachedComicLibraryEntry> firstLoad = await service
            .loadCachedLibrary();
        await Directory(
          '${defaultRoot().path}${Platform.pathSeparator}Comic A',
        ).delete(recursive: true);
        final List<CachedComicLibraryEntry> secondLoad = await service
            .loadCachedLibrary();

        expect(firstLoad, hasLength(1));
        expect(firstLoad.first.cachedChapterCount, 1);
        expect(secondLoad, hasLength(1));
        expect(secondLoad.first.comicTitle, 'Comic A');
        expect(secondLoad.first.chapters.first.chapterTitle, 'Chapter 1');
      },
    );

    test('loadCachedLibrary forceRescan rebuilds stale cached index', () async {
      final ComicDownloadService service = createService();
      final Directory chapterDirectoryA = Directory(
        '${defaultRoot().path}${Platform.pathSeparator}Comic A'
        '${Platform.pathSeparator}Chapter 1',
      );
      await chapterDirectoryA.create(recursive: true);
      await File(
        '${chapterDirectoryA.path}${Platform.pathSeparator}001.jpg',
      ).writeAsString('image-a');
      await File(
        '${chapterDirectoryA.path}${Platform.pathSeparator}manifest.json',
      ).writeAsString(
        jsonEncode(<String, Object?>{
          'comicTitle': 'Comic A',
          'comicUri': 'https://example.com/comic/a',
          'coverUrl': 'https://example.com/cover-a.jpg',
          'chapterLabel': 'Chapter 1',
          'chapterHref': 'https://example.com/comic/a/chapter/1',
          'sourceUri': 'https://example.com/comic/a/chapter/1',
          'downloadedAt': DateTime(2026, 4, 1).toIso8601String(),
          'files': <String>['001.jpg'],
          'imageCount': 1,
        }),
      );

      expect(await service.loadCachedLibrary(), hasLength(1));

      final Directory chapterDirectoryB = Directory(
        '${defaultRoot().path}${Platform.pathSeparator}Comic B'
        '${Platform.pathSeparator}Chapter 2',
      );
      await chapterDirectoryB.create(recursive: true);
      await File(
        '${chapterDirectoryB.path}${Platform.pathSeparator}001.jpg',
      ).writeAsString('image-b');
      await File(
        '${chapterDirectoryB.path}${Platform.pathSeparator}manifest.json',
      ).writeAsString(
        jsonEncode(<String, Object?>{
          'comicTitle': 'Comic B',
          'comicUri': 'https://example.com/comic/b',
          'coverUrl': 'https://example.com/cover-b.jpg',
          'chapterLabel': 'Chapter 2',
          'chapterHref': 'https://example.com/comic/b/chapter/2',
          'sourceUri': 'https://example.com/comic/b/chapter/2',
          'downloadedAt': DateTime(2026, 4, 2).toIso8601String(),
          'files': <String>['001.jpg'],
          'imageCount': 1,
        }),
      );

      final List<CachedComicLibraryEntry> cachedLoad = await service
          .loadCachedLibrary();
      final List<CachedComicLibraryEntry> rescannedLoad = await service
          .loadCachedLibrary(forceRescan: true);

      expect(cachedLoad, hasLength(1));
      expect(cachedLoad.first.comicTitle, 'Comic A');
      expect(rescannedLoad, hasLength(2));
      expect(
        rescannedLoad.map((CachedComicLibraryEntry entry) => entry.comicTitle),
        containsAll(<String>['Comic A', 'Comic B']),
      );
    });

    test('migrateCacheRoot rejects nested target directories', () async {
      final ComicDownloadService service = createService();
      final Directory sourceRoot = defaultRoot();
      await sourceRoot.create(recursive: true);

      final DownloadPreferences from = const DownloadPreferences();
      final DownloadPreferences to = DownloadPreferences(
        mode: DownloadStorageMode.customDirectory,
        customBasePath:
            '${sourceRoot.path}${Platform.pathSeparator}nested_target',
        usePickedDirectoryAsRoot: true,
      );

      await expectLater(
        service.migrateCacheRoot(from: from, to: to),
        throwsA(isA<FileSystemException>()),
      );
    });

    test(
      'migrateCacheRoot copies files without deleting source directory',
      () async {
        final ComicDownloadService service = createService();
        final Directory sourceChapterDirectory = Directory(
          '${defaultRoot().path}${Platform.pathSeparator}Comic A'
          '${Platform.pathSeparator}Chapter 1',
        );
        await sourceChapterDirectory.create(recursive: true);
        await File(
          '${sourceChapterDirectory.path}${Platform.pathSeparator}001.jpg',
        ).writeAsString('image');

        final Directory targetRoot = Directory(
          '${tempDirectory.path}${Platform.pathSeparator}migrated_cache',
        );
        final DownloadStorageMigrationResult result = await service
            .migrateCacheRoot(
              from: const DownloadPreferences(),
              to: DownloadPreferences(
                mode: DownloadStorageMode.customDirectory,
                customBasePath: targetRoot.path,
                usePickedDirectoryAsRoot: true,
              ),
            );

        expect(result.cleanupFuture, isNull);
        expect(
          await File(
            '${targetRoot.path}${Platform.pathSeparator}Comic A'
            '${Platform.pathSeparator}Chapter 1'
            '${Platform.pathSeparator}001.jpg',
          ).exists(),
          isTrue,
        );
        expect(
          await File(
            '${sourceChapterDirectory.path}${Platform.pathSeparator}001.jpg',
          ).exists(),
          isTrue,
        );
      },
    );

    test(
      'applyMigrationDeltas replays chapter copy and comic delete',
      () async {
        final ComicDownloadService service = createService();
        final Directory sourceChapterDirectory = Directory(
          '${defaultRoot().path}${Platform.pathSeparator}Comic A'
          '${Platform.pathSeparator}Chapter 1',
        );
        await sourceChapterDirectory.create(recursive: true);
        await File(
          '${sourceChapterDirectory.path}${Platform.pathSeparator}001.jpg',
        ).writeAsString('source-image');

        final Directory targetRoot = Directory(
          '${tempDirectory.path}${Platform.pathSeparator}migrated_cache',
        );
        final Directory targetChapterDirectory = Directory(
          '${targetRoot.path}${Platform.pathSeparator}Comic A'
          '${Platform.pathSeparator}Chapter 1',
        );
        await targetChapterDirectory.create(recursive: true);
        await File(
          '${targetChapterDirectory.path}${Platform.pathSeparator}001.jpg',
        ).writeAsString('stale-image');

        final Directory targetDeletedComicDirectory = Directory(
          '${targetRoot.path}${Platform.pathSeparator}Comic B'
          '${Platform.pathSeparator}Chapter 9',
        );
        await targetDeletedComicDirectory.create(recursive: true);
        await File(
          '${targetDeletedComicDirectory.path}${Platform.pathSeparator}001.jpg',
        ).writeAsString('remove-me');

        await service.applyMigrationDeltas(
          from: const DownloadPreferences(),
          to: DownloadPreferences(
            mode: DownloadStorageMode.customDirectory,
            customBasePath: targetRoot.path,
            usePickedDirectoryAsRoot: true,
          ),
          entries: <MigrationDeltaEntry>[
            MigrationDeltaEntry(
              kind: MigrationDeltaKind.upsertChapter,
              relativePath: service.chapterDirectoryPath(
                'Comic A',
                'Chapter 1',
              ),
              updatedAt: DateTime(2026, 4, 2),
            ),
            MigrationDeltaEntry(
              kind: MigrationDeltaKind.deleteComic,
              relativePath: service.comicDirectoryPath('Comic B'),
              updatedAt: DateTime(2026, 4, 2),
            ),
          ],
        );

        expect(
          await File(
            '${targetChapterDirectory.path}${Platform.pathSeparator}001.jpg',
          ).readAsString(),
          'source-image',
        );
        expect(
          await Directory(
            '${targetRoot.path}${Platform.pathSeparator}Comic B',
          ).exists(),
          isFalse,
        );
      },
    );
  });
}
