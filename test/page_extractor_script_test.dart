import 'package:easy_copy/webview/page_extractor_script.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('page extractor script uses hardened JS literal helpers', () {
    final String script = buildPageExtractionScript(42);

    expect(
      script,
      contains('const extractAssignedString = (source, variableName) =>'),
    );
    expect(
      script,
      contains('const extractCallStringArgument = (source, functionName) =>'),
    );
    expect(
      script,
      contains("return extractAssignedString(allScriptText, 'contentKey');"),
    );
    expect(script, contains("const collectId = extractCallStringArgument("));
  });
}
