import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

typedef SearchApiDirectoryProvider = Future<Directory> Function();
typedef SearchApiNowProvider = DateTime Function();

enum SearchApiSource {
  candidateProbe('candidate_probe'),
  htmlHint('html_hint'),
  manualSeed('manual_seed');

  const SearchApiSource(this.jsonValue);

  final String jsonValue;

  static SearchApiSource fromJson(String? value) {
    for (final SearchApiSource source in SearchApiSource.values) {
      if (source.jsonValue == value) {
        return source;
      }
    }
    return SearchApiSource.manualSeed;
  }
}

class SearchApiRecord {
  const SearchApiRecord({
    required this.host,
    required this.path,
    required this.discoveredAt,
    required this.lastVerifiedAt,
    required this.source,
  });

  final String host;
  final String path;
  final DateTime discoveredAt;
  final DateTime lastVerifiedAt;
  final SearchApiSource source;

  static SearchApiRecord? tryParse(Map<String, Object?> json) {
    final String host = _normalizeHost((json['host'] as String?) ?? '');
    final String path = _normalizePath((json['path'] as String?) ?? '');
    if (host.isEmpty || path.isEmpty) {
      return null;
    }

    final DateTime discoveredAt =
        DateTime.tryParse((json['discoveredAt'] as String?) ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final DateTime lastVerifiedAt =
        DateTime.tryParse((json['lastVerifiedAt'] as String?) ?? '') ??
        discoveredAt;

    return SearchApiRecord(
      host: host,
      path: path,
      discoveredAt: discoveredAt,
      lastVerifiedAt: lastVerifiedAt,
      source: SearchApiSource.fromJson(json['source'] as String?),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'host': host,
      'path': path,
      'discoveredAt': discoveredAt.toIso8601String(),
      'lastVerifiedAt': lastVerifiedAt.toIso8601String(),
      'source': source.jsonValue,
    };
  }

  SearchApiRecord copyWith({
    String? host,
    String? path,
    DateTime? discoveredAt,
    DateTime? lastVerifiedAt,
    SearchApiSource? source,
  }) {
    return SearchApiRecord(
      host: host ?? this.host,
      path: path ?? this.path,
      discoveredAt: discoveredAt ?? this.discoveredAt,
      lastVerifiedAt: lastVerifiedAt ?? this.lastVerifiedAt,
      source: source ?? this.source,
    );
  }
}

class SearchApiSnapshot {
  const SearchApiSnapshot({this.records = const <SearchApiRecord>[]});

  factory SearchApiSnapshot.fromJson(Map<String, Object?> json) {
    final Map<String, SearchApiRecord> recordsByHost =
        <String, SearchApiRecord>{};
    final List<Object?> values =
        (json['records'] as List<Object?>?) ?? const <Object?>[];
    for (final Object? value in values) {
      if (value is! Map) {
        continue;
      }
      final SearchApiRecord? record = SearchApiRecord.tryParse(
        value.map(
          (Object? key, Object? nested) => MapEntry(key.toString(), nested),
        ),
      );
      if (record == null) {
        continue;
      }
      recordsByHost[record.host] = record;
    }
    final List<SearchApiRecord> records =
        recordsByHost.values.toList(growable: false)..sort(
          (SearchApiRecord left, SearchApiRecord right) =>
              left.host.compareTo(right.host),
        );
    return SearchApiSnapshot(records: records);
  }

  final List<SearchApiRecord> records;

  SearchApiRecord? recordForHost(String host) {
    final String normalizedHost = _normalizeHost(host);
    if (normalizedHost.isEmpty) {
      return null;
    }
    for (final SearchApiRecord record in records) {
      if (record.host == normalizedHost) {
        return record;
      }
    }
    return null;
  }

  SearchApiSnapshot upsert(SearchApiRecord record) {
    final String normalizedHost = _normalizeHost(record.host);
    if (normalizedHost.isEmpty) {
      return this;
    }
    final List<SearchApiRecord> next =
        <SearchApiRecord>[
          for (final SearchApiRecord current in records)
            if (current.host != normalizedHost) current,
          record.copyWith(
            host: normalizedHost,
            path: _normalizePath(record.path),
          ),
        ]..sort(
          (SearchApiRecord left, SearchApiRecord right) =>
              left.host.compareTo(right.host),
        );
    return SearchApiSnapshot(records: List<SearchApiRecord>.unmodifiable(next));
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'records': records
          .map((SearchApiRecord record) => record.toJson())
          .toList(growable: false),
    };
  }
}

class SearchApiStore {
  SearchApiStore({SearchApiDirectoryProvider? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final SearchApiDirectoryProvider _directoryProvider;

  Future<SearchApiSnapshot> read() async {
    try {
      final File file = await _snapshotFile();
      if (!await file.exists()) {
        return const SearchApiSnapshot();
      }
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return const SearchApiSnapshot();
      }
      return SearchApiSnapshot.fromJson(
        decoded.map(
          (Object? key, Object? value) => MapEntry(key.toString(), value),
        ),
      );
    } catch (_) {
      return const SearchApiSnapshot();
    }
  }

  Future<void> write(SearchApiSnapshot snapshot) async {
    try {
      final File file = await _snapshotFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(snapshot.toJson()),
      );
    } catch (_) {
      // Best-effort persistence only.
    }
  }

  Future<File> _snapshotFile() async {
    final Directory directory = await _directoryProvider();
    return File(
      '${directory.path}${Platform.pathSeparator}search_api_snapshot.json',
    );
  }
}

String _normalizeHost(String value) => value.trim().toLowerCase();

String _normalizePath(String value) {
  final String normalized = value.trim();
  if (normalized.isEmpty || !normalized.startsWith('/')) {
    return '';
  }
  return normalized;
}
