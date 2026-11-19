import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/screens/playback/game_stream_screen.dart';
import 'package:moonfin/util/game_stream_pad.dart';
import 'package:server_core/server_core.dart';

MoonbaseGamesApi _api(
  void Function(RequestOptions, RequestInterceptorHandler) onRequest,
) => MoonbaseGamesApi(
  Dio()..interceptors.add(InterceptorsWrapper(onRequest: onRequest)),
  () => 'http://redstar.example:8101',
  () => 'test-token',
  ServerType.jellyfin,
);

void main() {
  test('a RomM game detail reads its stream offer', () {
    final streams = GameDetail.fromJson({
      'id': 'romm-42',
      'stream': {'label': 'DuckStation'},
    });
    expect(streams.stream?.available, isTrue);
    expect(streams.stream?.label, 'DuckStation');

    final relink = GameDetail.fromJson({
      'id': 'romm-42',
      'stream': {'needsRelink': true},
    });
    expect(relink.stream?.available, isFalse);
    expect(relink.stream?.needsRelink, isTrue);

    expect(GameDetail.fromJson({'id': 'game'}).stream, isNull);
  });

  test('stream calls go to the game\'s Stream routes', () async {
    final calls = <String>[];
    final api = _api((options, handler) {
      calls.add('${options.method} ${options.path}');
      handler.resolve(
        Response(
          requestOptions: options,
          statusCode: 200,
          data: options.method == 'POST' && !options.path.endsWith('Heartbeat')
              ? {'sessionId': 'abc', 'label': 'Station 1'}
              : {
                  'state': 'ready',
                  'roomUrl': 'https://play.example/s1/?token=t',
                },
        ),
      );
    });

    final session = await api.startStream('lib 1', 'romm-42');
    final state = await api.streamState('lib 1', 'romm-42', session.sessionId);
    await api.heartbeatStream('lib 1', 'romm-42', session.sessionId);
    await api.endStream('lib 1', 'romm-42', session.sessionId);

    expect(session.sessionId, 'abc');
    expect(state.isReady, isTrue);
    expect(state.roomUrl, 'https://play.example/s1/?token=t');
    expect(calls, [
      'POST /Moonfin/Games/lib%201/Games/romm-42/Stream',
      'GET /Moonfin/Games/lib%201/Games/romm-42/Stream/abc',
      'POST /Moonfin/Games/lib%201/Games/romm-42/Stream/abc/Heartbeat',
      'DELETE /Moonfin/Games/lib%201/Games/romm-42/Stream/abc',
    ]);
  });

  test('a refused stream carries the server\'s reason', () async {
    final api = _api(
      (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          response: Response(
            requestOptions: options,
            statusCode: 409,
            data: {'error': 'busy', 'romName': 'Crash Bandicoot'},
          ),
          type: DioExceptionType.badResponse,
        ),
      ),
    );

    final error = await api
        .startStream('lib', 'romm-42')
        .then<GameStreamException?>(
          (_) => null,
          onError: (Object e) => e as GameStreamException,
        );

    expect(error?.error, 'busy');
    expect(error?.romName, 'Crash Bandicoot');
    expect(describeStreamError(error!), contains('Crash Bandicoot'));
  });

  test('a plugin without streaming reads as unavailable', () async {
    final api = _api(
      (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 404),
          type: DioExceptionType.badResponse,
        ),
      ),
    );

    await expectLater(
      api.startStream('lib', 'romm-42'),
      throwsA(
        isA<GameStreamException>().having(
          (e) => e.error,
          'error',
          'unavailable',
        ),
      ),
    );
  });

  test('controller labels press the standard gamepad buttons', () {
    expect(GameStreamPad.pressScript('BUTTON_2', true), contains('(0, true)'));
    expect(
      GameStreamPad.pressScript('BUTTON_0', false),
      contains('(3, false)'),
    );
    expect(GameStreamPad.pressScript('START', true), contains('(9, true)'));
    expect(
      GameStreamPad.pressScript('DPAD_RIGHT', true),
      contains('(15, true)'),
    );
    expect(GameStreamPad.pressScript('LEFT_STICK_X', true), isNull);
    // Every standard button 0-15 has exactly one label.
    expect(GameStreamPad.standardIndex.values.toSet(), {
      for (var i = 0; i < 16; i++) i,
    });
    expect(GameStreamPad.userScript().forMainFrameOnly, isFalse);
  });
}
