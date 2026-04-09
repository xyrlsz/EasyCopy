import 'dart:io';

import 'package:easy_copy/models/page_models.dart';
import 'package:easy_copy/services/navigation_request_guard.dart';
import 'package:easy_copy/services/page_cache_store.dart';
import 'package:easy_copy/services/page_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'reader revalidate refreshes timestamps without reloading chapter',
    () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'easycopy_page_repo_reader_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      DateTime now = DateTime(2026, 4, 10, 12, 0, 0);
      final PageCacheStore cacheStore = PageCacheStore(
        directoryProvider: () async => tempDir,
        now: () => now,
      );
      int freshLoadCount = 0;
      final PageRepository repository = PageRepository(
        cacheStore: cacheStore,
        standardPageLoader:
            (
              Uri uri, {
              required String authScope,
              NavigationRequestContext? requestContext,
            }) async {
              freshLoadCount += 1;
              return _readerPage(uri);
            },
        htmlPageLoader: (Uri uri, {required String authScope}) async {
          freshLoadCount += 1;
          return _readerPage(uri);
        },
      );
      final Uri readerUri = Uri.parse(
        'https://example.com/comic/demo/chapter/1',
      );
      final PageQueryKey key = PageQueryKey.forUri(
        readerUri,
        authScope: 'guest',
      );
      final CachedPageEnvelope envelope = PageCacheStore.buildEnvelope(
        routeKey: key.routeKey,
        page: _readerPage(readerUri),
        fingerprint: 'reader-fingerprint',
        authScope: 'guest',
        now: now,
      );
      await cacheStore.writeEnvelope(envelope);

      now = now.add(const Duration(hours: 1));
      await repository.revalidate(readerUri, key: key, envelope: envelope);

      final CachedPageEnvelope? refreshed = await cacheStore.read(
        key.routeKey,
        authScope: 'guest',
      );
      expect(freshLoadCount, 0);
      expect(refreshed, isNotNull);
      expect(refreshed!.validatedAt, now);
      expect(refreshed.fetchedAt, now);
    },
  );

  test('non-reader revalidate uses a single fresh load', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'easycopy_page_repo_home_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final PageCacheStore cacheStore = PageCacheStore(
      directoryProvider: () async => tempDir,
    );
    int freshLoadCount = 0;
    final PageRepository repository = PageRepository(
      cacheStore: cacheStore,
      standardPageLoader:
          (
            Uri uri, {
            required String authScope,
            NavigationRequestContext? requestContext,
          }) async {
            freshLoadCount += 1;
            return _homePage(uri);
          },
      htmlPageLoader: (Uri uri, {required String authScope}) async {
        freshLoadCount += 1;
        return _homePage(uri);
      },
    );
    final Uri homeUri = Uri.parse('https://example.com/');
    final PageQueryKey key = PageQueryKey.forUri(homeUri, authScope: 'guest');
    final CachedPageEnvelope envelope = PageCacheStore.buildEnvelope(
      routeKey: key.routeKey,
      page: _homePage(homeUri),
      fingerprint: 'home-fingerprint',
      authScope: 'guest',
    );
    await cacheStore.writeEnvelope(envelope);

    await repository.revalidate(homeUri, key: key, envelope: envelope);

    expect(freshLoadCount, 1);
  });

  test('cache payload compaction removes duplicate detail chapters', () {
    final DetailPageData detailPage = DetailPageData(
      title: 'Demo',
      uri: 'https://example.com/comic/demo',
      coverUrl: 'https://img.example.com/cover.jpg',
      aliases: '',
      authors: '',
      heat: '',
      updatedAt: '',
      status: '',
      summary: '',
      tags: const <LinkAction>[],
      startReadingHref: 'https://example.com/comic/demo/chapter/1',
      chapterGroups: const <ChapterGroupData>[
        ChapterGroupData(
          label: '主线',
          chapters: <ChapterData>[
            ChapterData(
              label: '第1话',
              href: 'https://example.com/comic/demo/chapter/1',
            ),
          ],
        ),
      ],
      chapters: const <ChapterData>[
        ChapterData(
          label: '第1话',
          href: 'https://example.com/comic/demo/chapter/1',
        ),
      ],
    );

    final CachedPageEnvelope envelope = PageCacheStore.buildEnvelope(
      routeKey: '/comic/demo',
      page: detailPage,
      fingerprint: 'detail-fingerprint',
      authScope: 'guest',
    );

    expect(envelope.payload.containsKey('chapters'), isFalse);
    expect(envelope.payload.containsKey('summary'), isFalse);

    final EasyCopyPage restored = EasyCopyPage.fromJson(envelope.payload);
    expect(restored, isA<DetailPageData>());
    expect((restored as DetailPageData).chapterGroups, hasLength(1));
    expect(restored.chapterGroups.first.chapters, hasLength(1));
  });
}

ReaderPageData _readerPage(Uri uri) {
  return ReaderPageData(
    title: 'Demo / Chapter 1',
    uri: uri.toString(),
    comicTitle: 'Demo',
    chapterTitle: 'Chapter 1',
    progressLabel: '1/3',
    imageUrls: const <String>['https://img.example.com/reader-1.jpg'],
    prevHref: '',
    nextHref: '',
    catalogHref: 'https://example.com/comic/demo',
    contentKey: 'content-key',
  );
}

HomePageData _homePage(Uri uri) {
  return HomePageData(
    title: '首页',
    uri: uri.toString(),
    heroBanners: const <HeroBannerData>[],
    sections: const <ComicSectionData>[],
  );
}
