import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'game_stream_pad.dart';

/// How the Android stream player ended.
enum GameStreamNativeOutcome {
  /// The player chose Save & quit.
  quit,

  /// The app sat in the background past the player's grace period.
  background,

  /// The page failed to load or its renderer died; see the message.
  error,

  /// Closed without a choice: [GameStreamNative.close], or Android itself.
  closed,
}

class GameStreamNativeResult {
  const GameStreamNativeResult(this.outcome, [this.message]);

  final GameStreamNativeOutcome outcome;
  final String? message;
}

/// The Android stream player, `GameStreamActivity`: the room in a plain
/// WebView filling its own activity, with controller input turned into page
/// calls natively. A Flutter platform view composites the page a second time
/// and routes every press through the Dart event loop, which on a TV box cost
/// about 60 ms per press and as much again per frame.
abstract final class GameStreamNative {
  static const MethodChannel _channel = MethodChannel(
    'org.moonfin.androidtv/game_stream',
  );

  /// Lets Chrome DevTools attach to the stream page. Debug builds, or a build
  /// with `--dart-define=MOONFIN_WEBVIEW_INSPECT=true` for testing on a TV.
  static const bool inspectable =
      kDebugMode || bool.fromEnvironment('MOONFIN_WEBVIEW_INSPECT');

  /// Shows [url] and completes when the player closes.
  static Future<GameStreamNativeResult> open(String url) async {
    final reply = await _channel.invokeMapMethod<String, dynamic>('open', {
      'url': url,
      'padScript': GameStreamPad.script,
      'pageScript': GameStreamPad.pageScript,
      'inspectable': inspectable,
    });
    final outcome = switch (reply?['result']) {
      'quit' => GameStreamNativeOutcome.quit,
      'background' => GameStreamNativeOutcome.background,
      'error' => GameStreamNativeOutcome.error,
      _ => GameStreamNativeOutcome.closed,
    };
    return GameStreamNativeResult(outcome, reply?['message'] as String?);
  }

  /// Closes the player if it's open, e.g. after RomM ended the session.
  static Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('close');
    } on PlatformException {
      // Nothing open.
    }
  }
}
