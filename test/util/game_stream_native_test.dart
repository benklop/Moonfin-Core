import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/util/game_stream_native.dart';
import 'package:moonfin/util/game_stream_pad.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.moonfin.androidtv/game_stream');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<GameStreamNativeResult> openWith(
    Object? reply,
    List<MethodCall> calls,
  ) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply;
    });
    return GameStreamNative.open('https://play.example/s1/?token=t');
  }

  test('open hands the room and the page scripts to the player', () async {
    final calls = <MethodCall>[];
    await openWith({'result': 'quit'}, calls);
    expect(calls.single.method, 'open');
    final args = (calls.single.arguments as Map).cast<String, Object?>();
    expect(args['url'], 'https://play.example/s1/?token=t');
    expect(args['padScript'], GameStreamPad.script);
    expect(args['pageScript'], GameStreamPad.pageScript);
    expect(args['inspectable'], isA<bool>());
  });

  test('each player result maps to its outcome', () async {
    final cases = {
      'quit': GameStreamNativeOutcome.quit,
      'background': GameStreamNativeOutcome.background,
      'error': GameStreamNativeOutcome.error,
      'closed': GameStreamNativeOutcome.closed,
      'something new': GameStreamNativeOutcome.closed,
    };
    for (final entry in cases.entries) {
      final result = await openWith({
        'result': entry.key,
        'message': 'why',
      }, []);
      expect(result.outcome, entry.value, reason: entry.key);
      expect(result.message, 'why');
    }
  });

  test('a missing reply reads as closed', () async {
    final result = await openWith(null, []);
    expect(result.outcome, GameStreamNativeOutcome.closed);
    expect(result.message, isNull);
  });

  test('close tolerates no player being open', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'NONE');
    });
    await GameStreamNative.close();
  });

  test('the pad script offers the whole-pad setter', () {
    expect(GameStreamPad.script, contains('window.moonfinStreamPadSet'));
    expect(GameStreamPad.script, contains('window.moonfinStreamPad ='));
  });
}
