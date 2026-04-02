import 'package:easy_copy/services/key_value_store.dart';
import 'package:easy_copy/services/login_credentials_store.dart';
import 'package:easy_copy/theme/app_theme.dart';
import 'package:easy_copy/widgets/native_login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('uses theme surfaces in dark mode', (WidgetTester tester) async {
    final ThemeData darkTheme = AppTheme.buildDarkTheme();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.buildLightTheme(),
        darkTheme: darkTheme,
        themeMode: ThemeMode.dark,
        home: NativeLoginScreen(
          loginUri: Uri.parse('https://example.com/web/login'),
          userAgent: 'test-agent',
          credentialsStore: LoginCredentialsStore(
            store: _MemoryKeyValueStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Scaffold scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, darkTheme.scaffoldBackgroundColor);

    final Container card = tester.widget<Container>(
      find.byKey(const ValueKey<String>('native_login_card')),
    );
    final BoxDecoration decoration = card.decoration! as BoxDecoration;
    expect(decoration.color, darkTheme.colorScheme.surface);
    expect(decoration.border?.top.color, darkTheme.colorScheme.outlineVariant);
  });
}

class _MemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}
