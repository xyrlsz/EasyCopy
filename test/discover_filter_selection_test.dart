import 'package:easy_copy/models/page_models.dart';
import 'package:easy_copy/services/discover_filter_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DiscoverPageData buildPage() {
    return DiscoverPageData(
      title: '发现',
      uri: 'https://example.com/comics?theme=action&ordering=-popular',
      filters: const <FilterGroupData>[
        FilterGroupData(
          label: '题材',
          options: <LinkAction>[
            LinkAction(
              label: '动作',
              href: '?theme=action&ordering=-popular',
              active: true,
            ),
            LinkAction(label: '奇幻', href: '?theme=fantasy&ordering=-popular'),
          ],
        ),
        FilterGroupData(
          label: '排序',
          options: <LinkAction>[
            LinkAction(
              label: '热门',
              href: '?theme=action&ordering=-popular',
              active: true,
            ),
            LinkAction(
              label: '最新',
              href: '?theme=action&ordering=-datetime_updated',
            ),
          ],
        ),
      ],
      items: const <ComicCardData>[],
      pager: const PagerData(),
      spotlight: const <ComicCardData>[],
    );
  }

  test(
    'optimistic selection activates the tapped discover option immediately',
    () {
      final DiscoverPageData page = buildPage();

      final DiscoverPageData nextPage = applyOptimisticDiscoverFilterSelection(
        page,
        currentUri: Uri.parse(page.uri),
        targetUri: Uri.parse(
          'https://example.com/comics?theme=fantasy&ordering=-popular',
        ),
      );

      expect(nextPage.filters[0].options[0].active, isFalse);
      expect(nextPage.filters[0].options[1].active, isTrue);
      expect(nextPage.filters[1].options[0].active, isTrue);
      expect(nextPage.filters[1].options[1].active, isFalse);
      expect(nextPage.items, same(page.items));
      expect(nextPage.pager, same(page.pager));
    },
  );

  test(
    'optimistic selection updates every group that matches the next route',
    () {
      final DiscoverPageData page = buildPage();

      final DiscoverPageData nextPage = applyOptimisticDiscoverFilterSelection(
        page,
        currentUri: Uri.parse(page.uri),
        targetUri: Uri.parse(
          'https://example.com/comics?theme=action&ordering=-datetime_updated',
        ),
      );

      expect(nextPage.filters[0].options[0].active, isTrue);
      expect(nextPage.filters[0].options[1].active, isFalse);
      expect(nextPage.filters[1].options[0].active, isFalse);
      expect(nextPage.filters[1].options[1].active, isTrue);
    },
  );
}
