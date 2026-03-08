import 'package:easy_copy/services/navigation_request_guard.dart';
import 'package:easy_copy/services/primary_tab_session_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  NavigationRequestContext buildRequest({
    required int requestId,
    required int targetTabIndex,
    NavigationRequestSourceKind sourceKind =
        NavigationRequestSourceKind.navigation,
  }) {
    return NavigationRequestContext(
      requestId: requestId,
      targetTabIndex: targetTabIndex,
      routeKey: '/comics',
      intent: NavigationIntent.preserve,
      preserveVisiblePage: true,
      sourceKind: sourceKind,
    );
  }

  test('commit requires the target tab to remain selected', () {
    final PrimaryTabRouteEntry entry = PrimaryTabRouteEntry.root(
      Uri.parse('https://example.com/comics'),
    ).copyWith(activeRequestId: 7);

    expect(
      canCommitNavigationRequest(
        currentSelectedIndex: 1,
        currentEntry: entry,
        request: buildRequest(requestId: 7, targetTabIndex: 1),
      ),
      isTrue,
    );
    expect(
      canCommitNavigationRequest(
        currentSelectedIndex: 0,
        currentEntry: entry,
        request: buildRequest(requestId: 7, targetTabIndex: 1),
      ),
      isFalse,
    );
  });

  test('stale request ids cannot commit after ownership changes', () {
    final PrimaryTabRouteEntry activeEntry = PrimaryTabRouteEntry.root(
      Uri.parse('https://example.com/person/home'),
    ).copyWith(activeRequestId: 12);
    final NavigationRequestContext staleProfileRequest = buildRequest(
      requestId: 11,
      targetTabIndex: 3,
      sourceKind: NavigationRequestSourceKind.profile,
    );

    expect(
      canCommitNavigationRequest(
        currentSelectedIndex: 3,
        currentEntry: activeEntry,
        request: staleProfileRequest,
      ),
      isFalse,
    );
  });

  test(
    'revalidate requests lose commit rights once the route is abandoned',
    () {
      final PrimaryTabRouteEntry abandonedEntry = PrimaryTabRouteEntry.root(
        Uri.parse('https://example.com/comic/demo'),
      ).copyWith(activeRequestId: 0, isLoading: false);

      expect(
        canCommitNavigationRequest(
          currentSelectedIndex: 1,
          currentEntry: abandonedEntry,
          request: buildRequest(
            requestId: 21,
            targetTabIndex: 1,
            sourceKind: NavigationRequestSourceKind.revalidate,
          ),
        ),
        isFalse,
      );
    },
  );
}
