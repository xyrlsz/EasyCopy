import 'package:easy_copy/easy_copy_screen.dart';
import 'package:easy_copy/models/page_models.dart';
import 'package:flutter_test/flutter_test.dart';

ReaderPageData _readerPage({
  required String uri,
  required List<String> imageUrls,
}) {
  return ReaderPageData(
    title: 't',
    uri: uri,
    comicTitle: 'comic',
    chapterTitle: 'chapter',
    progressLabel: '1/1',
    imageUrls: imageUrls,
    prevHref: '',
    nextHref: '',
    catalogHref: '',
    contentKey: '',
  );
}

void main() {
  test('resolveReaderPageForDownload prefers storage cache result', () async {
    int storageCalls = 0;
    int pageCacheCalls = 0;
    int lightweightCalls = 0;
    int webviewCalls = 0;
    final Uri chapterUri = Uri.parse('https://example.com/comic/a/chapter/1');
    final ReaderPageData storagePage = _readerPage(
      uri: chapterUri.toString(),
      imageUrls: const <String>['https://img.example.com/1.jpg'],
    );

    final ReaderPageData resolved = await resolveReaderPageForDownload(
      chapterUri,
      loadFromStorageCache: (Uri _) async {
        storageCalls += 1;
        return storagePage;
      },
      loadFromPageCache: (Uri _) async {
        pageCacheCalls += 1;
        return null;
      },
      loadFromLightweightSource: (Uri _) async {
        lightweightCalls += 1;
        return _readerPage(
          uri: chapterUri.toString(),
          imageUrls: const <String>[],
        );
      },
      loadFromWebViewFallback: (Uri _) async {
        webviewCalls += 1;
        return _readerPage(
          uri: chapterUri.toString(),
          imageUrls: const <String>['https://img.example.com/fallback.jpg'],
        );
      },
    );

    expect(resolved, same(storagePage));
    expect(storageCalls, 1);
    expect(pageCacheCalls, 0);
    expect(lightweightCalls, 0);
    expect(webviewCalls, 0);
  });

  test('resolveReaderPageForDownload falls back to page cache', () async {
    int pageCacheCalls = 0;
    int lightweightCalls = 0;
    final Uri chapterUri = Uri.parse('https://example.com/comic/a/chapter/2');
    final ReaderPageData pageCache = _readerPage(
      uri: chapterUri.toString(),
      imageUrls: const <String>['https://img.example.com/2.jpg'],
    );

    final ReaderPageData resolved = await resolveReaderPageForDownload(
      chapterUri,
      loadFromStorageCache: (Uri _) async {
        return _readerPage(
          uri: chapterUri.toString(),
          imageUrls: const <String>[],
        );
      },
      loadFromPageCache: (Uri _) async {
        pageCacheCalls += 1;
        return pageCache;
      },
      loadFromLightweightSource: (Uri _) async {
        lightweightCalls += 1;
        return _readerPage(
          uri: chapterUri.toString(),
          imageUrls: const <String>[],
        );
      },
      loadFromWebViewFallback: (Uri _) async {
        fail('webview fallback should not be called when page cache is usable');
      },
    );

    expect(resolved, same(pageCache));
    expect(pageCacheCalls, 1);
    expect(lightweightCalls, 0);
  });

  test(
    'resolveReaderPageForDownload uses lightweight source before webview',
    () async {
      int lightweightCalls = 0;
      int webviewCalls = 0;
      final Uri chapterUri = Uri.parse('https://example.com/comic/a/chapter/3');
      final ReaderPageData lightweightPage = _readerPage(
        uri: chapterUri.toString(),
        imageUrls: const <String>['https://img.example.com/3.jpg'],
      );

      final ReaderPageData resolved = await resolveReaderPageForDownload(
        chapterUri,
        loadFromStorageCache: (Uri _) async => null,
        loadFromPageCache: (Uri _) async => null,
        loadFromLightweightSource: (Uri _) async {
          lightweightCalls += 1;
          return lightweightPage;
        },
        loadFromWebViewFallback: (Uri _) async {
          webviewCalls += 1;
          return _readerPage(
            uri: chapterUri.toString(),
            imageUrls: const <String>['https://img.example.com/fallback.jpg'],
          );
        },
      );

      expect(resolved, same(lightweightPage));
      expect(lightweightCalls, 1);
      expect(webviewCalls, 0);
    },
  );

  test(
    'resolveReaderPageForDownload falls back to webview when lightweight fails',
    () async {
      int webviewCalls = 0;
      final Uri chapterUri = Uri.parse('https://example.com/comic/a/chapter/4');
      final ReaderPageData fallbackPage = _readerPage(
        uri: chapterUri.toString(),
        imageUrls: const <String>['https://img.example.com/4.jpg'],
      );

      final ReaderPageData resolved = await resolveReaderPageForDownload(
        chapterUri,
        loadFromStorageCache: (Uri _) async => null,
        loadFromPageCache: (Uri _) async => null,
        loadFromLightweightSource: (Uri _) async {
          throw StateError('lightweight parsing failed');
        },
        loadFromWebViewFallback: (Uri _) async {
          webviewCalls += 1;
          return fallbackPage;
        },
      );

      expect(resolved, same(fallbackPage));
      expect(webviewCalls, 1);
    },
  );
}
