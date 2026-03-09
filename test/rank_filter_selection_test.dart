import 'package:easy_copy/models/page_models.dart';
import 'package:easy_copy/services/rank_filter_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  RankPageData buildPage() {
    return RankPageData(
      title: '排行',
      uri: 'https://example.com/rank?type=male&date=week',
      categories: const <LinkAction>[
        LinkAction(label: '男频', href: '?type=male&date=week', active: true),
        LinkAction(label: '女频', href: '?type=female&date=week'),
      ],
      periods: const <LinkAction>[
        LinkAction(label: '周榜', href: '?type=male&date=week', active: true),
        LinkAction(label: '月榜', href: '?type=male&date=month'),
      ],
      items: const <RankEntryData>[],
    );
  }

  test(
    'optimistic selection activates the tapped rank category immediately',
    () {
      final RankPageData page = buildPage();

      final RankPageData nextPage = applyOptimisticRankFilterSelection(
        page,
        currentUri: Uri.parse(page.uri),
        targetUri: Uri.parse('https://example.com/rank?type=female&date=week'),
      );

      expect(nextPage.categories[0].active, isFalse);
      expect(nextPage.categories[1].active, isTrue);
      expect(nextPage.periods[0].active, isTrue);
      expect(nextPage.periods[1].active, isFalse);
      expect(nextPage.items, same(page.items));
    },
  );

  test('optimistic selection updates every matching rank group', () {
    final RankPageData page = buildPage();

    final RankPageData nextPage = applyOptimisticRankFilterSelection(
      page,
      currentUri: Uri.parse(page.uri),
      targetUri: Uri.parse('https://example.com/rank?type=male&date=month'),
    );

    expect(nextPage.categories[0].active, isTrue);
    expect(nextPage.categories[1].active, isFalse);
    expect(nextPage.periods[0].active, isFalse);
    expect(nextPage.periods[1].active, isTrue);
  });
}
