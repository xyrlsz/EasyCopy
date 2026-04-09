import 'dart:convert';
import 'dart:typed_data';

import 'package:easy_copy/config/app_config.dart';
import 'package:easy_copy/models/page_models.dart';
import 'package:easy_copy/services/site_html_page_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

void main() {
  const SiteHtmlPageParser parser = SiteHtmlPageParser.instance;

  test(
    'reader parser prefers encrypted image manifest over DOM images',
    () async {
      const String key = '0123456789abcdef';
      const String iv = 'fedcba9876543210';
      final Uri uri = Uri.parse('https://example.com/comic/demo/chapter/1');
      final String encryptedContentKey = _encryptPayload(
        jsonEncode(<String>[
          'https://img.example.com/reader-1.jpg',
          'https://img.example.com/reader-2.jpg',
        ]),
        key: key,
        iv: iv,
      );
      final String html =
          '''
<html>
  <head>
    <title>Demo - Chapter 1</title>
    <script>
      var contentKey = '$encryptedContentKey';
      var cct = '$key';
    </script>
  </head>
  <body>
    <h4 class="header">Demo / Chapter 1</h4>
    <div class="comicContent-footer-txt"><span>1/2</span></div>
    <div class="comicContent-list">
      <img src="https://img.example.com/dom-fallback.jpg" />
    </div>
  </body>
</html>
''';

      final EasyCopyPage page = await parser.parsePage(uri, html);

      expect(page, isA<ReaderPageData>());
      expect((page as ReaderPageData).imageUrls, const <String>[
        'https://img.example.com/reader-1.jpg',
        'https://img.example.com/reader-2.jpg',
      ]);
    },
  );

  test(
    'detail parser prefers chapter API results over DOM chapter links',
    () async {
      const String key = '0011223344556677';
      const String iv = '7766554433221100';
      final Uri uri = Uri.parse('https://example.com/comic/demo');
      final String encryptedResults = _encryptPayload(
        jsonEncode(<String, Object?>{
          'build': <String, Object?>{
            'path_word': 'demo',
            'type': const <Object?>[],
          },
          'groups': <Object?>[
            <String, Object?>{
              'name': '主线',
              'chapters': <Object?>[
                <String, Object?>{
                  'id': 'api-chapter',
                  'name': 'API 第1话',
                  'datetime_created': '2026-04-01',
                },
              ],
            },
          ],
        }),
        key: key,
        iv: iv,
      );
      final String html =
          '''
<html>
  <head>
    <title>Demo</title>
    <script>var ccz = '$key';</script>
  </head>
  <body>
    <div class="comicParticulars-title"></div>
    <input id="dnt" value="token" />
    <h6 title="Demo"></h6>
    <div class="comicParticulars-left-img"><img src="https://img.example.com/cover.jpg" /></div>
    <ul class="comicParticulars-title-right">
      <li><span>作者</span><a href="/author/a">Author A</a></li>
    </ul>
    <div class="comicParticulars-tag">
      <a href="/tag/hero">#Hero</a>
    </div>
    <a class="comicParticulars-botton" href="/comic/demo/chapter/dom-chapter">开始阅读</a>
    <div class="tab-content">
      <div class="tab-pane" id="dom">
        <a href="/comic/demo/chapter/dom-chapter">DOM 第1话</a>
      </div>
    </div>
  </body>
</html>
''';

      final EasyCopyPage page = await parser.parsePage(
        uri,
        html,
        loadDetailChapterResults: (DetailChapterRequest request) async {
          expect(request.slug, 'demo');
          expect(request.ccz, key);
          expect(request.dnt, 'token');
          return encryptedResults;
        },
      );

      expect(page, isA<DetailPageData>());
      final DetailPageData detailPage = page as DetailPageData;
      expect(detailPage.chapterGroups, hasLength(1));
      expect(detailPage.chapterGroups.first.label, '主线');
      expect(detailPage.chapterGroups.first.chapters.first.label, 'API 第1话');
      expect(
        detailPage.chapterGroups.first.chapters.first.href,
        AppConfig.resolvePath('/comic/demo/chapter/api-chapter').toString(),
      );
      expect(detailPage.chapters, hasLength(1));
      expect(detailPage.chapters.first.label, 'API 第1话');
    },
  );
}

String _encryptPayload(
  String plainText, {
  required String key,
  required String iv,
}) {
  final Uint8List keyBytes = Uint8List.fromList(utf8.encode(key));
  final Uint8List ivBytes = Uint8List.fromList(utf8.encode(iv));
  final PaddedBlockCipher cipher = PaddedBlockCipherImpl(
    PKCS7Padding(),
    CBCBlockCipher(AESEngine()),
  );
  cipher.init(
    true,
    PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
      ParametersWithIV<KeyParameter>(KeyParameter(keyBytes), ivBytes),
      null,
    ),
  );
  final Uint8List cipherBytes = cipher.process(
    Uint8List.fromList(utf8.encode(plainText)),
  );
  return '$iv${_hexEncode(cipherBytes)}';
}

String _hexEncode(Uint8List bytes) {
  final StringBuffer buffer = StringBuffer();
  for (final int value in bytes) {
    buffer.write(value.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
