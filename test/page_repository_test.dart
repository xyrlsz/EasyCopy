import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_copy/config/app_config.dart';
import 'package:easy_copy/models/page_models.dart';
import 'package:easy_copy/services/navigation_request_guard.dart';
import 'package:easy_copy/services/page_cache_store.dart';
import 'package:easy_copy/services/page_probe_service.dart';
import 'package:easy_copy/services/page_repository.dart';
import 'package:easy_copy/services/site_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'easy_copy_page_repository',
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  PageCacheStore buildCacheStore(DateTime now) {
    return PageCacheStore(
      directoryProvider: () async => tempDir,
      now: () => now,
    );
  }

  test('readCached prefers memory after the first disk-backed read', () async {
    final DateTime now = DateTime(2026, 3, 7, 12);
    int loaderCount = 0;
    final PageRepository repository = PageRepository(
      cacheStore: buildCacheStore(now),
      probeService: _buildProbeService('<html></html>'),
      apiClient: FakeSiteApiClient(_buildLoggedOutProfile),
      standardPageLoader:
          (
            Uri uri, {
            required String authScope,
            NavigationRequestContext? requestContext,
          }) async {
            loaderCount += 1;
            return HomePageData(
              title: '首页',
              uri: uri.toString(),
              heroBanners: const <HeroBannerData>[],
              sections: const <ComicSectionData>[],
            );
          },
    );

    final Uri uri = Uri.parse('https://example.com/');
    final PageQueryKey key = PageQueryKey.forUri(uri, authScope: 'guest');

    await repository.loadFresh(uri, authScope: 'guest');
    repository.clearMemory();

    final CachedPageHit? firstHit = await repository.readCached(key);
    final CachedPageHit? secondHit = await repository.readCached(key);

    expect(loaderCount, 1);
    expect(firstHit, isNotNull);
    expect(secondHit, isNotNull);
    expect(firstHit!.page.title, '首页');
    expect(secondHit!.page.title, '首页');
    expect(loaderCount, 1);
  });

  test(
    'concurrent loadFresh requests share the same underlying load',
    () async {
      final Completer<EasyCopyPage> completer = Completer<EasyCopyPage>();
      int loaderCount = 0;
      final PageRepository repository = PageRepository(
        cacheStore: buildCacheStore(DateTime(2026, 3, 7, 12)),
        probeService: _buildProbeService('<html></html>'),
        apiClient: FakeSiteApiClient(_buildLoggedOutProfile),
        standardPageLoader:
            (
              Uri uri, {
              required String authScope,
              NavigationRequestContext? requestContext,
            }) async {
              loaderCount += 1;
              return completer.future;
            },
      );

      final Uri uri = Uri.parse('https://example.com/comics');
      final Future<EasyCopyPage> futureA = repository.loadFresh(
        uri,
        authScope: 'guest',
      );
      final Future<EasyCopyPage> futureB = repository.loadFresh(
        uri,
        authScope: 'guest',
      );

      await Future<void>.delayed(Duration.zero);
      expect(loaderCount, 1);

      completer.complete(
        HomePageData(
          title: '发现',
          uri: uri.toString(),
          heroBanners: const <HeroBannerData>[],
          sections: const <ComicSectionData>[],
        ),
      );

      final List<EasyCopyPage> results = await Future.wait<EasyCopyPage>(
        <Future<EasyCopyPage>>[futureA, futureB],
      );
      expect(results[0].uri, uri.toString());
      expect(results[1].uri, uri.toString());
    },
  );

  test(
    'concurrent revalidate requests share a single probe and refresh load',
    () async {
      int loaderCount = 0;
      int probeCount = 0;
      final PageRepository repository = PageRepository(
        cacheStore: buildCacheStore(DateTime(2026, 3, 7, 12)),
        probeService: _buildProbeService(
          '<html><body><div class="content-box"><div class="swiperList"></div></div><div class="comicRank"></div><a href="/comic/new"></a></body></html>',
          onProbe: () {
            probeCount += 1;
          },
        ),
        apiClient: FakeSiteApiClient(_buildLoggedOutProfile),
        standardPageLoader:
            (
              Uri uri, {
              required String authScope,
              NavigationRequestContext? requestContext,
            }) async {
              loaderCount += 1;
              return HomePageData(
                title: loaderCount == 1 ? '旧首页' : '新首页',
                uri: uri.toString(),
                heroBanners: const <HeroBannerData>[],
                sections: const <ComicSectionData>[],
              );
            },
      );

      final Uri uri = Uri.parse('https://example.com/');
      final PageQueryKey key = PageQueryKey.forUri(uri, authScope: 'guest');
      await repository.loadFresh(uri, authScope: 'guest');
      final CachedPageHit? cachedHit = await repository.readCached(key);

      await Future.wait<void>(<Future<void>>[
        repository.revalidate(uri, key: key, envelope: cachedHit!.envelope),
        repository.revalidate(uri, key: key, envelope: cachedHit.envelope),
      ]);

      expect(probeCount, 1);
      expect(loaderCount, 2);
    },
  );

  test(
    'authenticated detail revalidation bypasses the probe shortcut',
    () async {
      int loaderCount = 0;
      int probeCount = 0;
      final PageRepository repository = PageRepository(
        cacheStore: buildCacheStore(DateTime(2026, 3, 7, 12)),
        probeService: _buildProbeService(
          '<html></html>',
          onProbe: () {
            probeCount += 1;
          },
        ),
        apiClient: FakeSiteApiClient(_buildLoggedOutProfile),
        standardPageLoader:
            (
              Uri uri, {
              required String authScope,
              NavigationRequestContext? requestContext,
            }) async {
              loaderCount += 1;
              return DetailPageData(
                title: '详情',
                uri: uri.toString(),
                coverUrl: '',
                aliases: '',
                authors: '',
                heat: '',
                updatedAt: '2026-03-07',
                status: '连载中',
                summary: '',
                tags: const <LinkAction>[],
                startReadingHref: '',
                chapterGroups: const <ChapterGroupData>[],
                chapters: const <ChapterData>[],
                comicId: 'comic-demo',
                isCollected: loaderCount.isEven,
              );
            },
      );

      final Uri uri = Uri.parse('https://example.com/comic/demo');
      final PageQueryKey key = PageQueryKey.forUri(uri, authScope: 'user:42');
      await repository.loadFresh(uri, authScope: 'user:42');
      final CachedPageHit? cachedHit = await repository.readCached(key);

      await repository.revalidate(uri, key: key, envelope: cachedHit!.envelope);

      expect(loaderCount, 2);
      expect(probeCount, 0);
    },
  );

  test('authScope remains isolated for the same route', () async {
    int loaderCount = 0;
    final PageRepository repository = PageRepository(
      cacheStore: buildCacheStore(DateTime(2026, 3, 7, 12)),
      probeService: _buildProbeService('<html></html>'),
      apiClient: FakeSiteApiClient(_buildLoggedOutProfile),
      standardPageLoader:
          (
            Uri uri, {
            required String authScope,
            NavigationRequestContext? requestContext,
          }) async {
            loaderCount += 1;
            return HomePageData(
              title: authScope,
              uri: uri.toString(),
              heroBanners: const <HeroBannerData>[],
              sections: const <ComicSectionData>[],
            );
          },
    );

    final Uri uri = Uri.parse('https://example.com/comics');
    await repository.loadFresh(uri, authScope: 'guest');
    await repository.loadFresh(uri, authScope: 'user:42');

    final CachedPageHit? guestHit = await repository.readCached(
      PageQueryKey.forUri(uri, authScope: 'guest'),
    );
    final CachedPageHit? userHit = await repository.readCached(
      PageQueryKey.forUri(uri, authScope: 'user:42'),
    );

    expect(loaderCount, 2);
    expect(guestHit!.page.title, 'guest');
    expect(userHit!.page.title, 'user:42');
  });

  test(
    'profile and normal pages share the same repository semantics',
    () async {
      final PageRepository repository = PageRepository(
        cacheStore: buildCacheStore(DateTime(2026, 3, 7, 12)),
        probeService: _buildProbeService('<html></html>'),
        apiClient: FakeSiteApiClient(
          () async => ProfilePageData(
            title: '我的',
            uri: AppConfig.profileUri.toString(),
            isLoggedIn: true,
            user: const ProfileUserData(userId: '42', username: 'demo'),
            collections: const <ProfileLibraryItem>[],
            history: const <ProfileHistoryItem>[],
          ),
        ),
        standardPageLoader:
            (
              Uri uri, {
              required String authScope,
              NavigationRequestContext? requestContext,
            }) async {
              return HomePageData(
                title: '首页',
                uri: uri.toString(),
                heroBanners: const <HeroBannerData>[],
                sections: const <ComicSectionData>[],
              );
            },
      );

      await repository.loadFresh(AppConfig.profileUri, authScope: 'user:42');
      await repository.loadFresh(
        Uri.parse('https://example.com/'),
        authScope: 'guest',
      );

      expect(
        await repository.readCached(
          PageQueryKey.forUri(AppConfig.profileUri, authScope: 'user:42'),
        ),
        isNotNull,
      );
      expect(
        await repository.readCached(
          PageQueryKey.forUri(
            Uri.parse('https://example.com/'),
            authScope: 'guest',
          ),
        ),
        isNotNull,
      );
    },
  );

  test('loadFresh stores redirected pages under the final route key', () async {
    final PageRepository repository = PageRepository(
      cacheStore: buildCacheStore(DateTime(2026, 3, 7, 12)),
      probeService: _buildProbeService('<html></html>'),
      apiClient: FakeSiteApiClient(_buildLoggedOutProfile),
      standardPageLoader:
          (
            Uri uri, {
            required String authScope,
            NavigationRequestContext? requestContext,
          }) async {
            return HomePageData(
              title: '重定向首页',
              uri: 'https://example.com/comics?page=2',
              heroBanners: const <HeroBannerData>[],
              sections: const <ComicSectionData>[],
            );
          },
    );

    final Uri requestedUri = Uri.parse('https://example.com/topic/jump');
    await repository.loadFresh(requestedUri, authScope: 'guest');

    expect(
      await repository.readCached(
        PageQueryKey.forUri(requestedUri, authScope: 'guest'),
      ),
      isNull,
    );
    expect(
      await repository.readCached(
        PageQueryKey.forUri(
          Uri.parse('https://example.com/comics?page=2'),
          authScope: 'guest',
        ),
      ),
      isNotNull,
    );
  });

  test(
    'search routes load through the API client instead of the standard loader',
    () async {
      int loaderCount = 0;
      int searchLoadCount = 0;
      final PageRepository repository = PageRepository(
        cacheStore: buildCacheStore(DateTime(2026, 3, 7, 12)),
        probeService: _buildProbeService('<html></html>'),
        apiClient: FakeSiteApiClient(
          _buildLoggedOutProfile,
          searchLoader:
              ({
                required String query,
                required int page,
                required String qType,
              }) async {
                searchLoadCount += 1;
                expect(query, 'robot');
                expect(page, 2);
                expect(qType, 'author');
                return DiscoverPageData(
                  title: '搜索',
                  uri:
                      'https://example.com/search?page=2&q=robot&q_type=author',
                  filters: const <FilterGroupData>[],
                  items: const <ComicCardData>[
                    ComicCardData(
                      title: 'Robot Hero',
                      coverUrl: '',
                      href: 'https://example.com/comic/robot-hero',
                    ),
                  ],
                  pager: const PagerData(
                    currentLabel: '2',
                    totalLabel: '共3页 · 25条',
                  ),
                  spotlight: const <ComicCardData>[],
                );
              },
        ),
        standardPageLoader:
            (
              Uri uri, {
              required String authScope,
              NavigationRequestContext? requestContext,
            }) async {
              loaderCount += 1;
              return HomePageData(
                title: 'should-not-load',
                uri: uri.toString(),
                heroBanners: const <HeroBannerData>[],
                sections: const <ComicSectionData>[],
              );
            },
      );

      final Uri searchUri = Uri.parse(
        'https://example.com/search?q=robot&page=2&q_type=author',
      );
      final EasyCopyPage page = await repository.loadFresh(
        searchUri,
        authScope: 'guest',
      );

      expect(page, isA<DiscoverPageData>());
      expect(loaderCount, 0);
      expect(searchLoadCount, 1);
    },
  );

  test(
    'standard pages use the html loader while chapter pages keep webview loader',
    () async {
      int standardLoaderCount = 0;
      int htmlLoaderCount = 0;
      final PageRepository repository = PageRepository(
        cacheStore: buildCacheStore(DateTime(2026, 3, 7, 12)),
        probeService: _buildProbeService('<html></html>'),
        apiClient: FakeSiteApiClient(_buildLoggedOutProfile),
        standardPageLoader:
            (
              Uri uri, {
              required String authScope,
              NavigationRequestContext? requestContext,
            }) async {
              standardLoaderCount += 1;
              return ReaderPageData(
                title: '阅读',
                uri: uri.toString(),
                comicTitle: 'Demo',
                chapterTitle: '第1话',
                progressLabel: '1/1',
                imageUrls: const <String>[],
                prevHref: '',
                nextHref: '',
                catalogHref: 'https://example.com/comic/demo',
              );
            },
        htmlPageLoader: (Uri uri, {required String authScope}) async {
          htmlLoaderCount += 1;
          return HomePageData(
            title: '首页',
            uri: uri.toString(),
            heroBanners: const <HeroBannerData>[],
            sections: const <ComicSectionData>[],
          );
        },
      );

      final EasyCopyPage standardPage = await repository.loadFresh(
        Uri.parse('https://example.com/comics'),
        authScope: 'guest',
      );
      final EasyCopyPage chapterPage = await repository.loadFresh(
        Uri.parse('https://example.com/comic/demo/chapter/1'),
        authScope: 'guest',
      );

      expect(standardPage, isA<HomePageData>());
      expect(chapterPage, isA<ReaderPageData>());
      expect(htmlLoaderCount, 1);
      expect(standardLoaderCount, 1);
    },
  );

  test(
    'html loader failure on standard pages does not fall back to webview loader',
    () async {
      int standardLoaderCount = 0;
      int htmlLoaderCount = 0;
      final PageRepository repository = PageRepository(
        cacheStore: buildCacheStore(DateTime(2026, 3, 7, 12)),
        probeService: _buildProbeService('<html></html>'),
        apiClient: FakeSiteApiClient(_buildLoggedOutProfile),
        standardPageLoader:
            (
              Uri uri, {
              required String authScope,
              NavigationRequestContext? requestContext,
            }) async {
              standardLoaderCount += 1;
              return HomePageData(
                title: 'legacy',
                uri: uri.toString(),
                heroBanners: const <HeroBannerData>[],
                sections: const <ComicSectionData>[],
              );
            },
        htmlPageLoader: (Uri uri, {required String authScope}) async {
          htmlLoaderCount += 1;
          throw StateError('html parse failed');
        },
      );

      await expectLater(
        repository.loadFresh(
          Uri.parse('https://example.com/recommend'),
          authScope: 'guest',
        ),
        throwsA(isA<StateError>()),
      );
      expect(htmlLoaderCount, 1);
      expect(standardLoaderCount, 0);
    },
  );

  test(
    'standard page redirects are cached under the final route key from the html loader',
    () async {
      int standardLoaderCount = 0;
      int htmlLoaderCount = 0;
      final PageRepository repository = PageRepository(
        cacheStore: buildCacheStore(DateTime(2026, 3, 7, 12)),
        probeService: _buildProbeService('<html></html>'),
        apiClient: FakeSiteApiClient(_buildLoggedOutProfile),
        standardPageLoader:
            (
              Uri uri, {
              required String authScope,
              NavigationRequestContext? requestContext,
            }) async {
              standardLoaderCount += 1;
              return HomePageData(
                title: 'unexpected',
                uri: uri.toString(),
                heroBanners: const <HeroBannerData>[],
                sections: const <ComicSectionData>[],
              );
            },
        htmlPageLoader: (Uri uri, {required String authScope}) async {
          htmlLoaderCount += 1;
          return DiscoverPageData(
            title: '发现',
            uri: 'https://example.com/comics?page=2',
            filters: const <FilterGroupData>[],
            items: const <ComicCardData>[],
            pager: const PagerData(),
            spotlight: const <ComicCardData>[],
          );
        },
      );

      final Uri requestedUri = Uri.parse('https://example.com/topic/jump');
      await repository.loadFresh(requestedUri, authScope: 'guest');

      expect(htmlLoaderCount, 1);
      expect(standardLoaderCount, 0);
      expect(
        await repository.readCached(
          PageQueryKey.forUri(requestedUri, authScope: 'guest'),
        ),
        isNull,
      );
      expect(
        await repository.readCached(
          PageQueryKey.forUri(
            Uri.parse('https://example.com/comics?page=2'),
            authScope: 'guest',
          ),
        ),
        isNotNull,
      );
    },
  );
}

PageProbeService _buildProbeService(String html, {void Function()? onProbe}) {
  return PageProbeService(
    client: MockClient((http.Request request) async {
      onProbe?.call();
      return http.Response.bytes(utf8.encode(html), 200);
    }),
    now: () => DateTime(2026, 3, 7, 12),
    userAgent: 'test-agent',
  );
}

Future<ProfilePageData> _buildLoggedOutProfile() async {
  return ProfilePageData.loggedOut(uri: AppConfig.profileUri.toString());
}

class FakeSiteApiClient extends SiteApiClient {
  FakeSiteApiClient(this._loader, {this.searchLoader})
    : super(
        client: MockClient(
          (http.Request request) async =>
              http.Response.bytes(utf8.encode('{}'), 200),
        ),
      );

  final Future<ProfilePageData> Function() _loader;
  final Future<DiscoverPageData> Function({
    required String query,
    required int page,
    required String qType,
  })?
  searchLoader;

  @override
  Future<ProfilePageData> loadProfile() {
    return _loader();
  }

  @override
  Future<DiscoverPageData> loadSearchResults({
    required String query,
    int page = 1,
    String qType = '',
  }) {
    final Future<DiscoverPageData> Function({
      required String query,
      required int page,
      required String qType,
    })?
    loader = searchLoader;
    if (loader == null) {
      return Future<DiscoverPageData>.value(
        DiscoverPageData(
          title: '搜索',
          uri: 'https://example.com/search?q=$query',
          filters: const <FilterGroupData>[],
          items: const <ComicCardData>[],
          pager: const PagerData(),
          spotlight: const <ComicCardData>[],
        ),
      );
    }
    return loader(query: query, page: page, qType: qType);
  }
}
