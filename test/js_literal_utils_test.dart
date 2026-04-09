import 'package:easy_copy/services/js_literal_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'extractAssignedJavaScriptString reads inline var assignment without leading whitespace',
    () {
      const String script =
          "<script>var ccz='0011223344556677';window.contentKey='cipher';</script>";

      expect(
        extractAssignedJavaScriptString(script, 'ccz'),
        '0011223344556677',
      );
      expect(extractAssignedJavaScriptString(script, 'contentKey'), 'cipher');
    },
  );
}
