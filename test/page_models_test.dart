import 'package:easy_copy/models/page_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PagerData parses current and total page counts from search labels', () {
    const PagerData pager = PagerData(
      currentLabel: '2',
      totalLabel: '共15页 · 173条',
    );

    expect(pager.currentPageNumber, 2);
    expect(pager.totalPageCount, 15);
  });

  test('PagerData parses total page count from slash-style labels', () {
    const PagerData pager = PagerData(currentLabel: '8', totalLabel: '/1000');

    expect(pager.currentPageNumber, 8);
    expect(pager.totalPageCount, 1000);
  });
}
