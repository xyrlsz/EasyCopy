import 'dart:async';

import 'package:easy_copy/config/app_config.dart';
import 'package:easy_copy/services/page_repository.dart';
import 'package:easy_copy/services/primary_tab_session_store.dart';

enum StandardPageLoadEventSource {
  navigationRequest,
  urlChange,
  pageStarted,
  pageFinished,
  mainFrameError,
  payload,
}

class SupersededPageLoadException implements Exception {
  const SupersededPageLoadException();

  @override
  String toString() => '页面加载已被更新的导航替换。';
}

class StandardPageLoadHandle<T> {
  StandardPageLoadHandle({
    required Uri requestedUri,
    required this.queryKey,
    required this.intent,
    required this.preserveCurrentPage,
    required this.loadId,
    required this.targetTabIndex,
    required this.completer,
  }) : requestedUri = AppConfig.rewriteToCurrentHost(requestedUri),
       acceptedRouteKeys = <String>{queryKey.routeKey};

  final Uri requestedUri;
  final PageQueryKey queryKey;
  final NavigationIntent intent;
  final bool preserveCurrentPage;
  final int loadId;
  final int targetTabIndex;
  final Completer<T> completer;
  final Set<String> acceptedRouteKeys;
  final Set<String> startedRouteKeys = <String>{};

  bool hasStartedAcceptedNavigation = false;

  bool accepts(Uri uri, {required StandardPageLoadEventSource source}) {
    final Uri rewrittenUri = AppConfig.rewriteToCurrentHost(uri);
    final String routeKey = AppConfig.routeKeyForUri(rewrittenUri);
    final bool isAcceptedRoute = acceptedRouteKeys.contains(routeKey);

    switch (source) {
      case StandardPageLoadEventSource.navigationRequest:
      case StandardPageLoadEventSource.urlChange:
        if (isAcceptedRoute) {
          return true;
        }
        if (hasStartedAcceptedNavigation &&
            resolveNavigationTabIndex(
                  rewrittenUri,
                  sourceTabIndex: targetTabIndex,
                ) ==
                targetTabIndex) {
          acceptedRouteKeys.add(routeKey);
          return true;
        }
        return false;
      case StandardPageLoadEventSource.pageStarted:
        if (!isAcceptedRoute) {
          return false;
        }
        startedRouteKeys.add(routeKey);
        hasStartedAcceptedNavigation = true;
        return true;
      case StandardPageLoadEventSource.pageFinished:
      case StandardPageLoadEventSource.payload:
        return startedRouteKeys.contains(routeKey);
      case StandardPageLoadEventSource.mainFrameError:
        return acceptedRouteKeys.contains(routeKey);
    }
  }
}

class StandardPageLoadController<T> {
  StandardPageLoadHandle<T>? _pendingLoad;

  StandardPageLoadHandle<T>? get pendingLoad => _pendingLoad;

  StandardPageLoadHandle<T> begin(StandardPageLoadHandle<T> load) {
    final StandardPageLoadHandle<T>? previous = _pendingLoad;
    if (previous != null &&
        !identical(previous, load) &&
        !previous.completer.isCompleted) {
      previous.completer.completeError(const SupersededPageLoadException());
    }
    _pendingLoad = load;
    return load;
  }

  bool isCurrent(StandardPageLoadHandle<T> load) {
    return identical(_pendingLoad, load);
  }

  void clear(StandardPageLoadHandle<T> load) {
    if (identical(_pendingLoad, load)) {
      _pendingLoad = null;
    }
  }
}

StandardPageLoadHandle<T>? acceptedPendingNavigationLoad<T>(
  StandardPageLoadHandle<T>? pendingLoad,
  Uri uri, {
  required StandardPageLoadEventSource source,
}) {
  if (pendingLoad == null || pendingLoad.completer.isCompleted) {
    return null;
  }
  if (!pendingLoad.accepts(uri, source: source)) {
    return null;
  }
  return pendingLoad;
}
