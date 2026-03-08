import 'dart:async';

import 'package:easy_copy/config/app_config.dart';
import 'package:easy_copy/services/page_repository.dart';
import 'package:easy_copy/services/primary_tab_session_store.dart';
import 'package:easy_copy/services/standard_page_load_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  StandardPageLoadHandle<String> buildHandle(
    String uri, {
    required int loadId,
    int? targetTabIndex,
  }) {
    final Uri parsedUri = Uri.parse(uri);
    return StandardPageLoadHandle<String>(
      requestedUri: parsedUri,
      queryKey: PageQueryKey.forUri(parsedUri, authScope: 'guest'),
      intent: NavigationIntent.preserve,
      preserveCurrentPage: false,
      loadId: loadId,
      targetTabIndex: targetTabIndex ?? tabIndexForUri(parsedUri),
      completer: Completer<String>(),
    );
  }

  test('starting a new load supersedes the previous pending load', () async {
    final StandardPageLoadController<String> controller =
        StandardPageLoadController<String>();
    final StandardPageLoadHandle<String> loadA = buildHandle(
      'https://www.2026copy.com/comic/a',
      loadId: 1,
    );
    final StandardPageLoadHandle<String> loadB = buildHandle(
      'https://www.2026copy.com/comic/b',
      loadId: 2,
    );

    controller.begin(loadA);
    final Future<void> supersededExpectation = expectLater(
      loadA.completer.future,
      throwsA(isA<SupersededPageLoadException>()),
    );

    controller.begin(loadB);

    await supersededExpectation;
    expect(controller.pendingLoad, same(loadB));
  });

  test(
    'same-tab stale page results are rejected after a newer load starts',
    () {
      final StandardPageLoadHandle<String> loadB = buildHandle(
        'https://www.2026copy.com/comic/b',
        loadId: 2,
      );

      expect(
        loadB.accepts(
          Uri.parse('https://www.2026copy.com/comic/b'),
          source: StandardPageLoadEventSource.navigationRequest,
        ),
        isTrue,
      );
      expect(
        loadB.accepts(
          Uri.parse('https://www.2026copy.com/comic/a'),
          source: StandardPageLoadEventSource.pageStarted,
        ),
        isFalse,
      );
      expect(
        loadB.accepts(
          Uri.parse('https://www.2026copy.com/comic/a'),
          source: StandardPageLoadEventSource.pageFinished,
        ),
        isFalse,
      );
      expect(
        loadB.accepts(
          Uri.parse('https://www.2026copy.com/comic/a'),
          source: StandardPageLoadEventSource.payload,
        ),
        isFalse,
      );
    },
  );

  test('cross-tab stale navigation callbacks are rejected', () {
    final StandardPageLoadHandle<String> loadRank = buildHandle(
      'https://www.2026copy.com/rank/day',
      loadId: 3,
    );

    expect(
      loadRank.accepts(
        Uri.parse('https://www.2026copy.com/rank/day'),
        source: StandardPageLoadEventSource.pageStarted,
      ),
      isTrue,
    );
    expect(
      loadRank.accepts(
        Uri.parse('https://www.2026copy.com/'),
        source: StandardPageLoadEventSource.urlChange,
      ),
      isFalse,
    );
    expect(
      loadRank.accepts(
        Uri.parse('https://www.2026copy.com/'),
        source: StandardPageLoadEventSource.pageFinished,
      ),
      isFalse,
    );
  });

  test(
    'redirected routes within the accepted navigation chain are allowed',
    () {
      final StandardPageLoadHandle<String> load = buildHandle(
        'https://www.2026copy.com/topic/jump',
        loadId: 4,
      );
      final Uri requestedUri = Uri.parse('https://www.2026copy.com/topic/jump');
      final Uri redirectedUri = Uri.parse(
        'https://www.2026copy.com/comics?page=2',
      );

      expect(
        load.accepts(
          requestedUri,
          source: StandardPageLoadEventSource.navigationRequest,
        ),
        isTrue,
      );
      expect(
        load.accepts(
          requestedUri,
          source: StandardPageLoadEventSource.pageStarted,
        ),
        isTrue,
      );
      expect(
        load.accepts(
          redirectedUri,
          source: StandardPageLoadEventSource.urlChange,
        ),
        isTrue,
      );
      expect(
        load.accepts(
          redirectedUri,
          source: StandardPageLoadEventSource.pageStarted,
        ),
        isTrue,
      );
      expect(
        load.accepts(
          redirectedUri,
          source: StandardPageLoadEventSource.pageFinished,
        ),
        isTrue,
      );
      expect(
        load.accepts(
          redirectedUri,
          source: StandardPageLoadEventSource.payload,
        ),
        isTrue,
      );
    },
  );

  test(
    'detail redirects stay accepted when the detail route inherits a source tab',
    () {
      final StandardPageLoadHandle<String> load = buildHandle(
        'https://www.2026copy.com/comic/demo',
        loadId: 6,
        targetTabIndex: 3,
      );
      final Uri requestedUri = Uri.parse('https://www.2026copy.com/comic/demo');
      final Uri redirectedUri = Uri.parse(
        'https://www.2026copy.com/comic/demo?page=1',
      );

      expect(
        load.accepts(
          requestedUri,
          source: StandardPageLoadEventSource.navigationRequest,
        ),
        isTrue,
      );
      expect(
        load.accepts(
          requestedUri,
          source: StandardPageLoadEventSource.pageStarted,
        ),
        isTrue,
      );
      expect(
        load.accepts(
          redirectedUri,
          source: StandardPageLoadEventSource.urlChange,
        ),
        isTrue,
      );
      expect(
        load.accepts(
          redirectedUri,
          source: StandardPageLoadEventSource.pageStarted,
        ),
        isTrue,
      );
      expect(
        load.accepts(
          redirectedUri,
          source: StandardPageLoadEventSource.pageFinished,
        ),
        isTrue,
      );
    },
  );

  test('main frame errors for the requested route are still accepted', () {
    final StandardPageLoadHandle<String> load = buildHandle(
      'https://www.2026copy.com/comics',
      loadId: 5,
    );

    expect(
      load.accepts(
        Uri.parse('https://www.2026copy.com/comics'),
        source: StandardPageLoadEventSource.mainFrameError,
      ),
      isTrue,
    );
  });

  test('acceptedPendingNavigationLoad ignores missing and completed loads', () {
    expect(
      acceptedPendingNavigationLoad<String>(
        null,
        Uri.parse('https://www.2026copy.com/comics'),
        source: StandardPageLoadEventSource.navigationRequest,
      ),
      isNull,
    );

    final StandardPageLoadHandle<String> completedLoad = buildHandle(
      'https://www.2026copy.com/comics',
      loadId: 7,
    );
    completedLoad.completer.complete('done');

    expect(
      acceptedPendingNavigationLoad(
        completedLoad,
        Uri.parse('https://www.2026copy.com/comics'),
        source: StandardPageLoadEventSource.navigationRequest,
      ),
      isNull,
    );
  });

  test('acceptedPendingNavigationLoad returns the active accepted handle', () {
    final StandardPageLoadHandle<String> load = buildHandle(
      'https://www.2026copy.com/comic/demo',
      loadId: 8,
      targetTabIndex: 2,
    );
    final Uri requestedUri = Uri.parse('https://www.2026copy.com/comic/demo');

    final StandardPageLoadHandle<String>? acceptedLoad =
        acceptedPendingNavigationLoad(
          load,
          requestedUri,
          source: StandardPageLoadEventSource.navigationRequest,
        );

    expect(acceptedLoad, same(load));
    expect(
      acceptedPendingNavigationLoad(
        load,
        Uri.parse('https://www.2026copy.com/person/home'),
        source: StandardPageLoadEventSource.urlChange,
      ),
      isNull,
    );
  });
}
