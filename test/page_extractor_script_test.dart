import 'package:easy_copy/webview/page_extractor_script.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'reader extraction script does not force materialize images by scroll',
    () {
      final String script = buildPageExtractionScript(7);
      expect(
        script,
        isNot(contains("window.dispatchEvent(new Event('scroll'))")),
      );
      expect(script, isNot(contains('materializeReaderImages')));
      expect(script, isNot(contains('state.attempts < 48')));
    },
  );

  test(
    'reader extraction script still embeds load id and schedules retries',
    () {
      final String script = buildPageExtractionScript(123);
      expect(script, contains('const loadId = 123;'));
      expect(script, contains('needsMoreTime(type)'));
      expect(script, contains('setTimeout(tick, 160)'));
    },
  );
}
