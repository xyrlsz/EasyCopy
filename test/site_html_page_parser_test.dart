import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easy_copy/models/page_models.dart';
import 'package:easy_copy/services/site_html_page_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

String fixturePath(String name) {
  return 'test${Platform.pathSeparator}fixtures${Platform.pathSeparator}'
      'site${Platform.pathSeparator}$name';
}

void main() {
  const SiteHtmlPageParser parser = SiteHtmlPageParser.instance;

  test('parses homepage fixture into home sections and feature card', () async {
    final String html = await File(fixturePath('homepage.html')).readAsString();
    final HomePageData page =
        await parser.parsePage(Uri.parse('https://www.2026copy.com/'), html)
            as HomePageData;

    expect(page.title, '首頁');
    expect(page.heroBanners, isNotEmpty);
    expect(page.sections.length, greaterThanOrEqualTo(3));
    expect(page.sections.first.title, contains('漫畫推薦'));
    expect(page.sections.first.items, isNotEmpty);
    expect(page.sections.first.href, 'https://www.2026copy.com/recommend');
    expect(page.feature, isNotNull);
    expect(page.feature!.title, contains('秋番漫畫2025'));
    expect(page.feature!.href, contains('/topic/'));
  });

  test(
    'parses discover fixture with filters, items, spotlight, and pager',
    () async {
      final String html = await File(fixturePath('comics.html')).readAsString();
      final DiscoverPageData page =
          await parser.parsePage(
                Uri.parse(
                  'https://www.2026copy.com/comics?ordering=-datetime_updated',
                ),
                html,
              )
              as DiscoverPageData;

      expect(page.filters.length, 4);
      expect(page.filters.first.label, '題材');
      expect(
        page.filters.last.options.any((LinkAction item) => item.active),
        isTrue,
      );
      expect(page.items, hasLength(50));
      expect(
        page.items.map((ComicCardData item) => item.href),
        contains('https://www.2026copy.com/comic/omolaoshiheji'),
      );
      expect(page.spotlight, hasLength(5));
      expect(page.spotlight.first.title, '一日凌辱體驗');
      expect(page.pager.currentLabel, '1');
      expect(page.pager.nextHref, contains('offset=50'));
    },
  );

  test('parses rank fixture with active tabs and ranking cards', () async {
    final String html = await File(fixturePath('rank.html')).readAsString();
    final RankPageData page =
        await parser.parsePage(
              Uri.parse('https://www.2026copy.com/rank?type=male&table=day'),
              html,
            )
            as RankPageData;

    expect(page.title, contains('排行'));
    expect(page.categories.any((LinkAction item) => item.active), isTrue);
    expect(
      page.categories.firstWhere((LinkAction item) => item.active).label,
      contains('男頻'),
    );
    expect(
      page.periods.firstWhere((LinkAction item) => item.active).label,
      '日榜(上升最快)',
    );
    expect(page.items, hasLength(50));
    expect(page.items.first.title, '魔都精兵的奴隸');
    expect(
      page.items.first.href,
      'https://www.2026copy.com/comic/modujingbingdenuli',
    );
  });

  test('parses detail fixture and chapter endpoint payload together', () async {
    final String html = await File(fixturePath('series.html')).readAsString();
    final String encryptedResults = _encryptChapterPayload(
      'op0zzpvv.nzn.ocp',
      <String, Object?>{
        'build': <String, Object?>{
          'path_word': 'modujingbingdenuli',
          'type': <Object?>[
            <String, Object?>{'id': 1, 'name': '話'},
            <String, Object?>{'id': 3, 'name': '番外篇'},
          ],
        },
        'groups': <String, Object?>{
          'default': <String, Object?>{
            'path_word': 'default',
            'name': '默認',
            'chapters': <Object?>[
              <String, Object?>{
                'type': 1,
                'name': '第01话',
                'id': '52615840-10a4-11e9-b68d-00163e0ca5bd',
              },
              <String, Object?>{
                'type': 1,
                'name': '第02话',
                'id': 'c2d8f146-17b6-11e9-bfa4-00163e0ca5bd',
              },
            ],
          },
          'extra': <String, Object?>{
            'path_word': 'extra',
            'name': '番外篇',
            'chapters': <Object?>[
              <String, Object?>{
                'type': 3,
                'name': '出张版',
                'id': '956b5976-0e17-11ea-b01f-00163e0ca5bd',
              },
            ],
          },
        },
      },
    );

    final DetailPageData page =
        await parser.parsePage(
              Uri.parse('https://www.2026copy.com/comic/modujingbingdenuli'),
              html,
              loadDetailChapterResults: (DetailChapterRequest request) async {
                expect(request.slug, 'modujingbingdenuli');
                expect(request.dnt, '3');
                expect(request.ccz, 'op0zzpvv.nzn.ocp');
                return encryptedResults;
              },
            )
            as DetailPageData;

    expect(page.title, '魔都精兵的奴隸');
    expect(page.authors, '竹村洋平 / タカヒロ');
    expect(page.updatedAt, '2026-01-05');
    expect(page.status, '連載中');
    expect(page.summary, contains('在未來，日本各地出現'));
    expect(
      page.tags.map((LinkAction item) => item.label),
      containsAll(<String>['冒險', '奇幻']),
    );
    expect(page.comicId, '155edbf2-10a4-11e9-828f-00163e0ca5bd');
    expect(page.isCollected, isFalse);
    expect(
      page.startReadingHref,
      contains(
        '/comic/modujingbingdenuli/chapter/52615840-10a4-11e9-b68d-00163e0ca5bd',
      ),
    );
    expect(page.chapterGroups, hasLength(2));
    expect(page.chapterGroups.first.label, '全部');
    expect(page.chapterGroups.first.chapters, hasLength(2));
    expect(page.chapterGroups.last.label, '番外篇');
    expect(page.chapterGroups.last.chapters.single.label, '出张版');
    expect(page.chapters, hasLength(3));
  });

  test('parses topic index and topic detail pages', () async {
    const String topicIndexHtml = '''
<!DOCTYPE html>
<html lang="zh-hant">
  <head>
    <title>專題 - 拷貝漫畫 拷贝漫画</title>
  </head>
  <body>
    <main class="content-box">
      <div class="specialContent comic">
        <div class="specialContentImage">
          <a href="/topic/demo-topic-a">
            <img src="https://example.com/topic-a.jpg" alt="">
          </a>
          <span class="specialContentImageSpan">專題 A</span>
        </div>
        <div class="specialContentTextContent">推薦摘要 A</div>
        <div class="specialContentButton">
          <span class="specialContentButtonTime">2026-03-01</span>
        </div>
      </div>
      <div class="specialContent comic">
        <div class="specialContentImage">
          <a href="/topic/demo-topic-b">
            <img src="https://example.com/topic-b.jpg" alt="">
          </a>
          <span class="specialContentImageSpan">專題 B</span>
        </div>
      </div>
      <ul class="page-all">
        <li class="page-all-item active">
          <a href="/topic?offset=0">1</a>
        </li>
      </ul>
    </main>
  </body>
</html>
''';
    const String topicDetailHtml = '''
<!DOCTYPE html>
<html lang="zh-hant">
  <head>
    <title>秋番漫畫專題 - 拷貝漫畫 拷贝漫画</title>
  </head>
  <body>
    <main class="container specialDetail">
      <div class="specialDetailTitle">
        <div class="specialDetailTitleFlex">
          <span>秋番漫畫專題</span>
          <span>2026-03-01</span>
        </div>
      </div>
      <div class="row">
        <div class="col-6 specialDetailItem">
          <div class="specialDetailItemHeaderImage">
            <a href="/comic/demo-a">
              <img src="https://example.com/a.jpg" alt="">
            </a>
          </div>
          <p class="specialDetailItemHeaderContentName twoLines">
            <a href="/comic/demo-a">作品 A</a>
          </p>
        </div>
        <div class="col-6 specialDetailItem">
          <div class="specialDetailItemHeaderImage">
            <a href="/comic/demo-b">
              <img src="https://example.com/b.jpg" alt="">
            </a>
          </div>
          <p class="specialDetailItemHeaderContentName twoLines">
            <a href="/comic/demo-b">作品 B</a>
          </p>
        </div>
      </div>
    </main>
  </body>
</html>
''';

    final DiscoverPageData topicIndex =
        await parser.parsePage(
              Uri.parse('https://www.2026copy.com/topic'),
              topicIndexHtml,
            )
            as DiscoverPageData;
    final DiscoverPageData topicDetail =
        await parser.parsePage(
              Uri.parse('https://www.2026copy.com/topic/demo-topic-a'),
              topicDetailHtml,
            )
            as DiscoverPageData;

    expect(topicIndex.items, hasLength(2));
    expect(topicIndex.items.first.badge, '專題');
    expect(topicIndex.pager.currentLabel, '1');

    expect(topicDetail.title, '秋番漫畫專題');
    expect(topicDetail.items, hasLength(2));
    expect(
      topicDetail.items.first.href,
      'https://www.2026copy.com/comic/demo-a',
    );
  });

  test('parses recommend and newest pages as discover pages', () async {
    const String correlationHtml = '''
<!DOCTYPE html>
<html lang="zh-hant">
  <head>
    <title>編輯推薦 - 拷貝漫畫 拷贝漫画</title>
  </head>
  <body>
    <div class="container correlationList">
      <div class="row">
        <div class="col-auto exemptComic_Item">
          <a href="/comic/demo-a">
            <img src="https://example.com/a.jpg" alt="">
          </a>
          <div class="exemptComicItem-txt-box">
            <div class="threeLines" title="推薦作品A"></div>
          </div>
        </div>
        <div class="col-auto exemptComic_Item">
          <a href="/comic/demo-b">推薦作品B</a>
        </div>
      </div>
    </div>
    <ul class="page-all">
      <li class="page-all-item active">
        <a href="/recommend?offset=0">1</a>
      </li>
    </ul>
  </body>
</html>
''';

    final DiscoverPageData recommend =
        await parser.parsePage(
              Uri.parse('https://www.2026copy.com/recommend'),
              correlationHtml,
            )
            as DiscoverPageData;
    final DiscoverPageData newest =
        await parser.parsePage(
              Uri.parse('https://www.2026copy.com/newest'),
              correlationHtml,
            )
            as DiscoverPageData;

    expect(recommend.items, hasLength(2));
    expect(recommend.items.first.title, '推薦作品A');
    expect(recommend.pager.currentLabel, '1');

    expect(newest.items, hasLength(2));
    expect(newest.items.last.href, 'https://www.2026copy.com/comic/demo-b');
  });
}

String _encryptChapterPayload(String ccz, Map<String, Object?> payload) {
  const String prefix = '1234567890abcdef';
  final PaddedBlockCipher cipher = PaddedBlockCipherImpl(
    PKCS7Padding(),
    CBCBlockCipher(AESEngine()),
  );
  cipher.init(
    true,
    PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
      ParametersWithIV<KeyParameter>(
        KeyParameter(Uint8List.fromList(utf8.encode(ccz))),
        Uint8List.fromList(utf8.encode(prefix)),
      ),
      null,
    ),
  );

  final Uint8List encrypted = cipher.process(
    Uint8List.fromList(utf8.encode(jsonEncode(payload))),
  );
  return '$prefix${_hexEncode(encrypted)}';
}

String _hexEncode(List<int> bytes) {
  final StringBuffer buffer = StringBuffer();
  for (final int byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
