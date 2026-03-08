import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';

class DisplayModeService {
  DisplayModeService._();

  static Future<void> requestHighRefreshRate() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } on MissingPluginException {
      // Ignore when the platform channel is unavailable in tests or unsupported builds.
    } on PlatformException {
      // Ignore devices/ROMs that reject refresh-rate overrides.
    }
  }
}
