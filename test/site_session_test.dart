import 'package:easy_copy/services/key_value_store.dart';
import 'package:easy_copy/services/site_session.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async {
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

void main() {
  test('saveToken clears userId and replaces cookies', () async {
    final _MemoryKeyValueStore store = _MemoryKeyValueStore();
    final SiteSession session = SiteSession(
      store: store,
      now: () => DateTime.utc(2024, 1, 1),
    );

    await session.saveToken(
      'token-old',
      cookies: <String, String>{'session': 'old', 'legacy': '1'},
    );
    await session.bindUserId('user-old');
    await session.updateFromCookieHeader('legacy=2; other=1');

    expect(session.userId, 'user-old');
    expect(session.cookies['legacy'], '2');

    await session.saveToken(
      'token-new',
      cookies: <String, String>{'session': 'new'},
    );

    expect(session.userId, isNull);
    expect(session.cookies['token'], 'token-new');
    expect(session.cookies['session'], 'new');
    expect(session.cookies.containsKey('legacy'), isFalse);
    expect(session.authScope.startsWith('token:'), isTrue);

    final SiteSession reloaded = SiteSession(
      store: store,
      now: () => DateTime.utc(2024, 1, 1),
    );
    await reloaded.ensureInitialized();
    expect(reloaded.userId, isNull);
    expect(reloaded.cookies['token'], 'token-new');
    expect(reloaded.cookies.containsKey('legacy'), isFalse);
  });
}
