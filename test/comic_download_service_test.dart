import 'dart:convert';
import 'dart:io';

import 'package:easy_copy/models/app_preferences.dart';
import 'package:easy_copy/models/page_models.dart';
import 'package:easy_copy/services/comic_download_service.dart';
import 'package:easy_copy/services/download_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  ReaderPageData buildReaderPage({
    String prevHref = '',
    String nextHref = '',
    String catalogHref = 'https://www.2026copy.com/comic/demo',
  }) {
    return ReaderPageData(
      title: 'Chapter 1',
      uri: 'https://www.2026copy.com/comic/demo/chapter/1',
      comicTitle: 'Demo Comic',
      chapterTitle: 'Chapter 1',
      progressLabel: '1/2',
      imageUrls: const <String>[
        'https://cdn.example/chapter-1/001.jpg',
        'https://cdn.example/chapter-1/002.png',
      ],
      prevHref: prevHref,
      nextHref: nextHref,
      catalogHref: catalogHref,
      contentKey: 'chapter-1',
    );
  }

  test('downloadChapter resumes from existing image files', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'easy_copy_download_service',
    );
    addTearDown(() => tempDir.delete(recursive: true));

    final List<String> requestedUrls = <String>[];
    final ComicDownloadService service = ComicDownloadService(
      client: MockClient((http.Request request) async {
        requestedUrls.add(request.url.toString());
        return http.Response.bytes(
          utf8.encode('image:${request.url.pathSegments.last}'),
          200,
          headers: <String, String>{'content-type': 'image/png'},
        );
      }),
      baseDirectoryProvider: () async => tempDir,
    );

    final Directory chapterDirectory = Directory(
      '${tempDir.path}${Platform.pathSeparator}EasyCopyDownloads'
      '${Platform.pathSeparator}Demo Comic'
      '${Platform.pathSeparator}Chapter 1',
    );
    await chapterDirectory.create(recursive: true);
    await File(
      '${chapterDirectory.path}${Platform.pathSeparator}001.jpg',
    ).writeAsBytes(utf8.encode('cached-001'));

    final ChapterDownloadResult result = await service.downloadChapter(
      buildReaderPage(),
      chapterLabel: 'Chapter 1',
      comicUri: 'https://www.2026copy.com/comic/demo',
      coverUrl: 'https://img.example/demo.jpg',
    );

    expect(
      requestedUrls,
      equals(<String>['https://cdn.example/chapter-1/002.png']),
    );
    expect(result.fileCount, 2);
    expect(
      File(
        '${chapterDirectory.path}${Platform.pathSeparator}001.jpg',
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        '${chapterDirectory.path}${Platform.pathSeparator}002.png',
      ).existsSync(),
      isTrue,
    );

    final Map<String, Object?> manifest =
        jsonDecode(await result.manifestFile.readAsString())
            as Map<String, Object?>;
    expect(manifest['imageCount'], 2);
  });

  test('deleteCachedComic removes the comic directory from disk', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'easy_copy_download_delete',
    );
    addTearDown(() => tempDir.delete(recursive: true));

    final ComicDownloadService service = ComicDownloadService(
      client: MockClient((http.Request request) async {
        return http.Response.bytes(
          utf8.encode('image:${request.url.pathSegments.last}'),
          200,
          headers: <String, String>{'content-type': 'image/jpeg'},
        );
      }),
      baseDirectoryProvider: () async => tempDir,
    );

    await service.downloadChapter(
      buildReaderPage(),
      chapterLabel: 'Chapter 1',
      comicUri: 'https://www.2026copy.com/comic/demo',
      coverUrl: 'https://img.example/demo.jpg',
    );

    final List<CachedComicLibraryEntry> library = await service
        .loadCachedLibrary();
    expect(library, hasLength(1));

    final Directory comicDirectory = Directory(
      '${tempDir.path}${Platform.pathSeparator}EasyCopyDownloads'
      '${Platform.pathSeparator}Demo Comic',
    );
    expect(comicDirectory.existsSync(), isTrue);

    await service.deleteCachedComic(library.single);

    expect(comicDirectory.existsSync(), isFalse);
  });

  test(
    'loadCachedReaderPage rebuilds a local reader payload from manifest',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'easy_copy_cached_reader_payload',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final ComicDownloadService service = ComicDownloadService(
        client: MockClient((http.Request request) async {
          return http.Response.bytes(
            utf8.encode('image:${request.url.pathSegments.last}'),
            200,
            headers: <String, String>{'content-type': 'image/jpeg'},
          );
        }),
        baseDirectoryProvider: () async => tempDir,
      );

      await service.downloadChapter(
        buildReaderPage(
          prevHref: 'https://www.2026copy.com/comic/demo/chapter/0',
          nextHref: 'https://www.2026copy.com/comic/demo/chapter/2',
        ),
        chapterLabel: 'Chapter 1',
        comicUri: 'https://www.2026copy.com/comic/demo',
        coverUrl: 'https://img.example/demo.jpg',
      );

      final ReaderPageData? cachedPage = await service.loadCachedReaderPage(
        'https://www.2026copy.com/comic/demo/chapter/1',
        prevHref: 'https://www.2026copy.com/comic/demo/chapter/0',
        nextHref: 'https://www.2026copy.com/comic/demo/chapter/2',
        catalogHref: 'https://www.2026copy.com/comic/demo',
      );

      expect(cachedPage, isNotNull);
      expect(cachedPage?.comicTitle, 'Demo Comic');
      expect(cachedPage?.chapterTitle, 'Chapter 1');
      expect(cachedPage?.prevHref, contains('/chapter/0'));
      expect(cachedPage?.nextHref, contains('/chapter/2'));
      expect(cachedPage?.imageUrls, hasLength(2));
      expect(
        cachedPage?.imageUrls.every(
          (String value) => value.startsWith('file:'),
        ),
        isTrue,
      );
    },
  );

  test(
    'loadCachedReaderPage falls back to manifest adjacent chapter links',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'easy_copy_cached_reader_manifest_links',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final ComicDownloadService service = ComicDownloadService(
        client: MockClient((http.Request request) async {
          return http.Response.bytes(
            utf8.encode('image:${request.url.pathSegments.last}'),
            200,
            headers: <String, String>{'content-type': 'image/jpeg'},
          );
        }),
        baseDirectoryProvider: () async => tempDir,
      );

      await service.downloadChapter(
        buildReaderPage(
          prevHref: 'https://www.2026copy.com/comic/demo/chapter/0',
          nextHref: 'https://www.2026copy.com/comic/demo/chapter/2',
          catalogHref: 'https://www.2026copy.com/comic/demo',
        ),
        chapterLabel: 'Chapter 1',
        comicUri: 'https://www.2026copy.com/comic/demo',
        coverUrl: 'https://img.example/demo.jpg',
      );

      final ReaderPageData? cachedPage = await service.loadCachedReaderPage(
        'https://www.2026copy.com/comic/demo/chapter/1',
      );

      expect(cachedPage, isNotNull);
      expect(cachedPage?.prevHref, contains('/chapter/0'));
      expect(cachedPage?.nextHref, contains('/chapter/2'));
      expect(cachedPage?.catalogHref, contains('/comic/demo'));
    },
  );

  test(
    'cleanupIncompleteChapter removes partial chapters and keeps completed ones',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'easy_copy_cleanup_chapter_',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final ComicDownloadService service = ComicDownloadService(
        client: MockClient((http.Request request) async {
          return http.Response.bytes(
            utf8.encode('image:${request.url.pathSegments.last}'),
            200,
            headers: <String, String>{'content-type': 'image/jpeg'},
          );
        }),
        baseDirectoryProvider: () async => tempDir,
      );

      final String rootPath =
          '${tempDir.path}${Platform.pathSeparator}'
          '${DownloadStorageService.downloadsDirectoryName}';
      final Directory partialChapterDirectory = Directory(
        '$rootPath${Platform.pathSeparator}Demo Comic'
        '${Platform.pathSeparator}Chapter 2',
      );
      await partialChapterDirectory.create(recursive: true);
      await File(
        '${partialChapterDirectory.path}${Platform.pathSeparator}001.jpg',
      ).writeAsString('partial');

      final Directory completedChapterDirectory = Directory(
        '$rootPath${Platform.pathSeparator}Demo Comic'
        '${Platform.pathSeparator}Chapter 3',
      );
      await completedChapterDirectory.create(recursive: true);
      await File(
        '${completedChapterDirectory.path}${Platform.pathSeparator}manifest.json',
      ).writeAsString('{"imageCount":1}');
      await File(
        '${completedChapterDirectory.path}${Platform.pathSeparator}001.jpg',
      ).writeAsString('done');
      await File(
        '${completedChapterDirectory.path}${Platform.pathSeparator}001.jpg.part',
      ).writeAsString('temp');

      await service.cleanupIncompleteChapter(
        comicTitle: 'Demo Comic',
        chapterLabel: 'Chapter 2',
      );
      await service.cleanupIncompleteChapter(
        comicTitle: 'Demo Comic',
        chapterLabel: 'Chapter 3',
      );

      expect(partialChapterDirectory.existsSync(), isFalse);
      expect(completedChapterDirectory.existsSync(), isTrue);
      expect(
        File(
          '${completedChapterDirectory.path}${Platform.pathSeparator}001.jpg.part',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'migrateCacheRoot copies cached data into the new storage root',
    () async {
      final Directory sourceBase = await Directory.systemTemp.createTemp(
        'easy_copy_migrate_source_',
      );
      final Directory targetBase = await Directory.systemTemp.createTemp(
        'easy_copy_migrate_target_',
      );
      addTearDown(() => sourceBase.delete(recursive: true));
      addTearDown(() => targetBase.delete(recursive: true));

      final DownloadStorageService storageService = DownloadStorageService(
        preferencesProvider: () async => const DownloadPreferences(),
        defaultBaseDirectoryProvider: () async => sourceBase,
      );
      final ComicDownloadService service = ComicDownloadService(
        client: MockClient((http.Request request) async {
          return http.Response.bytes(
            utf8.encode('image:${request.url.pathSegments.last}'),
            200,
            headers: <String, String>{'content-type': 'image/jpeg'},
          );
        }),
        storageService: storageService,
      );

      final Directory sourceChapterDirectory = Directory(
        '${sourceBase.path}${Platform.pathSeparator}'
        '${DownloadStorageService.downloadsDirectoryName}'
        '${Platform.pathSeparator}Demo Comic'
        '${Platform.pathSeparator}Chapter 1',
      );
      await sourceChapterDirectory.create(recursive: true);
      await File(
        '${sourceChapterDirectory.path}${Platform.pathSeparator}manifest.json',
      ).writeAsString('{"imageCount":1}');
      await File(
        '${sourceChapterDirectory.path}${Platform.pathSeparator}001.jpg',
      ).writeAsString('done');

      final DownloadStorageMigrationResult result = await service
          .migrateCacheRoot(
            from: const DownloadPreferences(),
            to: DownloadPreferences(
              mode: DownloadStorageMode.customDirectory,
              customBasePath: targetBase.path,
            ),
          );

      final File migratedManifest = File(
        '${result.storageState.rootPath}${Platform.pathSeparator}Demo Comic'
        '${Platform.pathSeparator}Chapter 1'
        '${Platform.pathSeparator}manifest.json',
      );
      expect(result.storageState.isReady, isTrue);
      expect(migratedManifest.existsSync(), isTrue);
      expect(sourceChapterDirectory.existsSync(), isFalse);
    },
  );
}
