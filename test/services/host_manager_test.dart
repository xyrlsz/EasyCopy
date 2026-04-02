import 'dart:convert';
import 'dart:io';

import 'package:easy_copy/services/host_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HostManager', () {
    late Directory tempDirectory;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp(
        'copy_fullter_host_manager_test_',
      );
    });

    tearDown(() async {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    test('ignores legacy pinned host snapshot without pin mode', () async {
      final File snapshotFile = File(
        '${tempDirectory.path}${Platform.pathSeparator}host_probe.json',
      );
      await snapshotFile.writeAsString(
        jsonEncode(<String, Object?>{
          'selectedHost': 'b.example.com',
          'checkedAt': DateTime(2026, 4, 1).toIso8601String(),
          'sessionPinnedHost': 'a.example.com',
          'probes': <Map<String, Object?>>[
            <String, Object?>{
              'host': 'b.example.com',
              'success': true,
              'latencyMs': 20,
            },
          ],
        }),
      );

      final HostManager manager = HostManager(
        candidateHosts: const <String>['a.example.com', 'b.example.com'],
        directoryProvider: () async => tempDirectory,
        connectivityRunner: (String host) async => true,
        probeRunner: (String host) async => HostProbeRecord(
          host: host,
          success: true,
          latencyMs: host == 'b.example.com' ? 10 : 30,
        ),
      );

      await manager.ensureInitialized();

      expect(manager.sessionPinnedHost, isNull);
      expect(manager.currentHost, 'b.example.com');
    });

    test('restores manual pin saved by current version', () async {
      final HostManager firstManager = HostManager(
        candidateHosts: const <String>['a.example.com', 'b.example.com'],
        directoryProvider: () async => tempDirectory,
        connectivityRunner: (String host) async => true,
        probeRunner: (String host) async => HostProbeRecord(
          host: host,
          success: true,
          latencyMs: host == 'b.example.com' ? 10 : 30,
        ),
      );
      await firstManager.ensureInitialized();
      await firstManager.pinSessionHost('a.example.com');

      final HostManager secondManager = HostManager(
        candidateHosts: const <String>['a.example.com', 'b.example.com'],
        directoryProvider: () async => tempDirectory,
        connectivityRunner: (String host) async => true,
        probeRunner: (String host) async => HostProbeRecord(
          host: host,
          success: true,
          latencyMs: host == 'b.example.com' ? 10 : 30,
        ),
      );

      await secondManager.ensureInitialized();

      expect(secondManager.sessionPinnedHost, 'a.example.com');
      expect(secondManager.currentHost, 'a.example.com');
    });

    test('drops unavailable pinned host on startup and falls back', () async {
      final File snapshotFile = File(
        '${tempDirectory.path}${Platform.pathSeparator}host_probe.json',
      );
      await snapshotFile.writeAsString(
        jsonEncode(<String, Object?>{
          'selectedHost': 'a.example.com',
          'checkedAt': DateTime(2026, 4, 1).toIso8601String(),
          'pinMode': 'manual',
          'sessionPinnedHost': 'a.example.com',
          'probes': <Map<String, Object?>>[
            <String, Object?>{
              'host': 'a.example.com',
              'success': true,
              'latencyMs': 10,
            },
            <String, Object?>{
              'host': 'b.example.com',
              'success': true,
              'latencyMs': 20,
            },
          ],
        }),
      );

      final HostManager manager = HostManager(
        candidateHosts: const <String>['a.example.com', 'b.example.com'],
        directoryProvider: () async => tempDirectory,
        connectivityRunner: (String host) async => host == 'b.example.com',
        probeRunner: (String host) async => HostProbeRecord(
          host: host,
          success: host == 'b.example.com',
          latencyMs: host == 'b.example.com' ? 12 : 999999,
        ),
      );

      await manager.ensureInitialized();

      expect(manager.sessionPinnedHost, isNull);
      expect(manager.currentHost, 'b.example.com');
      expect(manager.candidateHosts, const <String>['b.example.com']);
    });

    test(
      'only keeps reachable successful hosts as selectable candidates',
      () async {
        final HostManager manager = HostManager(
          candidateHosts: const <String>[
            'a.example.com',
            'b.example.com',
            'c.example.com',
          ],
          directoryProvider: () async => tempDirectory,
          connectivityRunner: (String host) async => host != 'c.example.com',
          probeRunner: (String host) async => HostProbeRecord(
            host: host,
            success: host == 'a.example.com',
            latencyMs: switch (host) {
              'a.example.com' => 15,
              'b.example.com' => 30,
              _ => 999999,
            },
          ),
        );

        await manager.ensureInitialized();

        expect(manager.candidateHosts, const <String>['a.example.com']);
        expect(
          manager.snapshot?.probes.map((HostProbeRecord probe) => probe.host),
          containsAll(<String>['a.example.com', 'b.example.com']),
        );
        expect(
          manager.snapshot?.probes.map((HostProbeRecord probe) => probe.host),
          isNot(contains('c.example.com')),
        );
      },
    );
  });
}
