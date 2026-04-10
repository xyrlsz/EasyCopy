import 'dart:async';
import 'dart:convert';

import 'package:easy_copy/config/app_config.dart';
import 'package:easy_copy/services/debug_trace.dart';
import 'package:easy_copy/services/search_api_store.dart';
import 'package:http/http.dart' as http;

typedef SearchApiHtmlExtractor = String? Function(String html);

class SearchApiResolver {
  SearchApiResolver({
    http.Client? client,
    SearchApiStore? store,
    SearchApiNowProvider? now,
    SearchApiHtmlExtractor? htmlExtractor,
  }) : _client = client ?? http.Client(),
       _store = store ?? SearchApiStore(),
       _now = now ?? DateTime.now,
       _htmlExtractor = htmlExtractor ?? extractSearchApiPathFromHtml;

  static final SearchApiResolver instance = SearchApiResolver();
  static const List<String> candidatePaths = <String>[
    '/api/kb/web/searchci/comics',
    '/api/kb/web/searchch/comics',
  ];
  static final RegExp _countApiPattern = RegExp(
    r'''countApi\s*=\s*["']([^"'\\]+)["']''',
  );

  final http.Client _client;
  final SearchApiStore _store;
  final SearchApiNowProvider _now;
  final SearchApiHtmlExtractor _htmlExtractor;

  Future<void>? _initialization;
  SearchApiSnapshot _snapshot = const SearchApiSnapshot();
  final Map<String, Future<SearchApiRecord?>> _refreshTasks =
      <String, Future<SearchApiRecord?>>{};

  Future<void> ensureInitialized() {
    return _initialization ??= _initialize();
  }

  SearchApiRecord? peekRecordForHost(String host) {
    return _snapshot.recordForHost(host);
  }

  Future<String> resolveForHost(String host) async {
    await ensureInitialized();
    return _snapshot.recordForHost(host)?.path ?? candidatePaths.first;
  }

  Future<void> recordVerifiedPath(
    String host,
    String path, {
    SearchApiSource? source,
  }) async {
    await ensureInitialized();
    final String normalizedHost = host.trim().toLowerCase();
    final String normalizedPath = _normalizeSearchPath(path);
    if (normalizedHost.isEmpty || normalizedPath.isEmpty) {
      return;
    }

    final DateTime now = _now();
    final SearchApiRecord? existing = _snapshot.recordForHost(normalizedHost);
    final SearchApiRecord next = SearchApiRecord(
      host: normalizedHost,
      path: normalizedPath,
      discoveredAt: existing != null && existing.path == normalizedPath
          ? existing.discoveredAt
          : now,
      lastVerifiedAt: now,
      source:
          source ??
          _inferSourceForPath(
            normalizedHost,
            normalizedPath,
            existing: existing,
          ),
    );
    _snapshot = _snapshot.upsert(next);
    await _store.write(_snapshot);
  }

  Future<SearchApiRecord?> refreshForHost(String host) async {
    await ensureInitialized();
    final String normalizedHost = host.trim().toLowerCase();
    if (normalizedHost.isEmpty) {
      return null;
    }
    final Future<SearchApiRecord?>? activeRefresh =
        _refreshTasks[normalizedHost];
    if (activeRefresh != null) {
      return activeRefresh;
    }
    final Future<SearchApiRecord?> refresh = _refreshForHostInternal(
      normalizedHost,
    );
    _refreshTasks[normalizedHost] = refresh;
    return refresh.whenComplete(() {
      final Future<SearchApiRecord?>? current = _refreshTasks[normalizedHost];
      if (identical(current, refresh)) {
        _refreshTasks.remove(normalizedHost);
      }
    });
  }

  Future<void> _initialize() async {
    _snapshot = await _store.read();
  }

  Future<SearchApiRecord?> _refreshForHostInternal(String host) async {
    DebugTrace.log('search_api.refresh_start', <String, Object?>{'host': host});
    final SearchApiRecord? existing = _snapshot.recordForHost(host);
    final List<_SearchApiCandidate> candidates = <_SearchApiCandidate>[
      if (existing != null)
        _SearchApiCandidate(path: existing.path, source: existing.source),
      for (final String path in candidatePaths)
        _SearchApiCandidate(path: path, source: SearchApiSource.candidateProbe),
    ];
    final Set<String> attemptedPaths = <String>{};
    for (final _SearchApiCandidate candidate in candidates) {
      final String normalizedPath = _normalizeSearchPath(candidate.path);
      if (normalizedPath.isEmpty || !attemptedPaths.add(normalizedPath)) {
        continue;
      }
      if (await _probeSearchPath(host, normalizedPath)) {
        await recordVerifiedPath(
          host,
          normalizedPath,
          source: candidate.source,
        );
        final SearchApiRecord? resolved = _snapshot.recordForHost(host);
        DebugTrace.log('search_api.refresh_success', <String, Object?>{
          'host': host,
          'path': normalizedPath,
          'source': candidate.source.jsonValue,
        });
        return resolved;
      }
    }

    final String? htmlHintPath = await _extractPathFromSearchPage(host);
    final String normalizedHintPath = _normalizeSearchPath(htmlHintPath ?? '');
    if (normalizedHintPath.isNotEmpty &&
        attemptedPaths.add(normalizedHintPath) &&
        await _probeSearchPath(host, normalizedHintPath)) {
      await recordVerifiedPath(
        host,
        normalizedHintPath,
        source: SearchApiSource.htmlHint,
      );
      final SearchApiRecord? resolved = _snapshot.recordForHost(host);
      DebugTrace.log('search_api.refresh_success', <String, Object?>{
        'host': host,
        'path': normalizedHintPath,
        'source': SearchApiSource.htmlHint.jsonValue,
      });
      return resolved;
    }

    DebugTrace.log('search_api.refresh_failed', <String, Object?>{
      'host': host,
      'lastKnownPath': existing?.path,
    });
    return null;
  }

  Future<bool> _probeSearchPath(String host, String path) async {
    try {
      final Uri uri = Uri.https(host, path, const <String, String>{
        'offset': '0',
        'platform': '2',
        'limit': '12',
        'q': 'a',
        'q_type': '',
      });
      final http.Response response = await _client.get(
        uri,
        headers: _buildRequestHeaders(),
      );
      if (response.statusCode != 200) {
        return false;
      }
      final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) {
        return false;
      }
      final Map<String, Object?> payload = decoded.map(
        (Object? key, Object? value) => MapEntry(key.toString(), value),
      );
      final int code =
          (payload['code'] as num?)?.toInt() ?? response.statusCode;
      return code == 200 && payload['results'] is Map;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _extractPathFromSearchPage(String host) async {
    try {
      final Uri uri = Uri.https(host, '/search', const <String, String>{
        'q': 'a',
        'q_type': '',
      });
      final http.Response response = await _client.get(
        uri,
        headers: _buildRequestHeaders(
          accept: 'text/html,application/xhtml+xml',
        ),
      );
      if (response.statusCode != 200) {
        return null;
      }
      return _htmlExtractor(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    } catch (_) {
      return null;
    }
  }

  SearchApiSource _inferSourceForPath(
    String host,
    String path, {
    SearchApiRecord? existing,
  }) {
    final SearchApiRecord? current = existing ?? _snapshot.recordForHost(host);
    if (current != null && current.path == path) {
      return current.source;
    }
    if (candidatePaths.contains(path)) {
      return SearchApiSource.candidateProbe;
    }
    return SearchApiSource.manualSeed;
  }

  Map<String, String> _buildRequestHeaders({
    String accept = 'application/json',
  }) {
    return <String, String>{
      'Accept': accept,
      'User-Agent': AppConfig.desktopUserAgent,
      'platform': '2',
    };
  }

  static String? extractSearchApiPathFromHtml(String html) {
    final RegExpMatch? match = _countApiPattern.firstMatch(html);
    final String path = _normalizeSearchPath(match?.group(1) ?? '');
    return path.isEmpty ? null : path;
  }
}

class _SearchApiCandidate {
  const _SearchApiCandidate({required this.path, required this.source});

  final String path;
  final SearchApiSource source;
}

String _normalizeSearchPath(String value) {
  final String normalized = value.trim();
  if (normalized.isEmpty || !normalized.startsWith('/')) {
    return '';
  }
  return normalized;
}
