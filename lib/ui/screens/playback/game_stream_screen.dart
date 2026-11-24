import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:server_core/server_core.dart';

import '../../../util/desktop_emulator_gamepad.dart';
import '../../../util/focus/gamepad/android_gamepad_channel.dart';
import '../../../util/focus/gamepad/gamepad_suppressor.dart';
import '../../../util/game_stream_native.dart';
import '../../../util/game_stream_pad.dart';
import '../../../util/platform_detection.dart';
import '../../../util/system_ui.dart';
import '../../../util/webview_client_cert.dart';
import '../../../util/webview_environment.dart';
import '../../screensaver/screensaver_controller.dart';
import 'game_audio_owner.dart';
import 'game_playback_ui.dart';
import 'playback_takeover.dart';

/// What the screen shows: waiting for RomM, the stream, or why there's none.
enum _Phase { starting, playing, failed }

/// Streams a RomM game from one of RomM's emulator containers.
///
/// The server only starts, keeps and ends the session; the video and the
/// controller go straight between this WebView and RomM's room. The room is
/// opened at the URL RomM hands out, which carries a token that only works for
/// this session. Saves and play time are RomM's: its container saves the game
/// when the session ends, however it ends.
///
/// On Android the room plays in [GameStreamNative]'s own activity, which reads
/// the controller natively; this screen keeps the session behind it.
class GameStreamScreen extends StatefulWidget {
  const GameStreamScreen({
    super.key,
    required this.libraryId,
    required this.gameId,
    this.gameName,
    this.label,
  });

  final String libraryId;
  final String gameId;
  final String? gameName;

  /// RomM's name for the emulator, like DuckStation, for the waiting screen.
  final String? label;

  @override
  State<GameStreamScreen> createState() => _GameStreamScreenState();
}

class _GameStreamScreenState extends State<GameStreamScreen>
    with GameAudioOwner, ImmersiveSystemUi, WidgetsBindingObserver {
  /// RomM ends a session after three minutes without a heartbeat; its own
  /// player beats every 30 seconds.
  static const Duration _heartbeatEvery = Duration(seconds: 30);
  static const Duration _pollEvery = Duration(milliseconds: 1500);

  /// Large games unpack before they launch, so the wait is generous.
  static const Duration _startTimeout = Duration(minutes: 5);

  /// Containers are scarce, so a session left in the background is saved and
  /// ended rather than held. A quick app switch keeps it.
  static const Duration _backgroundGrace = Duration(seconds: 60);

  /// Start and Select held together this long opens the quit menu.
  static const Duration _comboHold = Duration(milliseconds: 800);

  final MediaServerClient _client = GetIt.instance<MediaServerClient>();
  InAppWebViewController? _controller;
  ScreensaverController? _screensaver;
  DesktopEmulatorGamepad? _desktopGamepad;

  _Phase _phase = _Phase.starting;
  String? _sessionId;
  String? _roomUrl;
  String? _status;
  String? _failure;

  Timer? _heartbeat;
  Timer? _backgroundTimer;
  bool _ended = false;
  bool _exiting = false;

  /// Android plays the room in its own activity rather than in this screen.
  static bool get _usesNativePlayer => PlatformDetection.isAndroid;

  /// The Android player is showing. This screen's own lifecycle then follows
  /// the app's main activity, which is stopped behind it, so it's ignored and
  /// the player reports leaving the app instead.
  bool _nativeOpen = false;

  bool _menuOpen = false;
  int _menuSelected = 0;

  /// Buttons the stream page has been told are down, released when the menu
  /// takes the controller so none stays held in the game.
  final Set<String> _held = {};
  bool _startHeld = false;
  bool _selectHeld = false;
  Timer? _comboTimer;

  GamesApi? get _games => _client.gamesApi;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GamePlaybackSystemUi.enter(this, immersive: true);
    detachTextInputForPlayback();
    if (GetIt.instance.isRegistered<ScreensaverController>()) {
      _screensaver = GetIt.instance<ScreensaverController>()
        ..setPlaybackActive(true);
    }
    GamepadSuppressor.push();
    claimGameAudio();
    if (PlatformDetection.isAndroid) {
      AndroidGamepadChannel.ensureInstalled();
      AndroidGamepadChannel.setEmulatorInputHandler(_onNativeGamepad);
      AndroidGamepadChannel.setGameActive(true);
    } else if (PlatformDetection.isDesktop) {
      _desktopGamepad = DesktopEmulatorGamepad(
        onButton: (label, pressed, _) => _onPad(label, pressed),
      )..start();
    }
    unawaited(_start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeat?.cancel();
    _backgroundTimer?.cancel();
    _comboTimer?.cancel();
    // Left some other way than Save & quit: RomM still saves on its way out.
    _endSession();
    _screensaver?.setPlaybackActive(false);
    releaseGameAudio();
    if (PlatformDetection.isAndroid) {
      AndroidGamepadChannel.setGameActive(false);
      AndroidGamepadChannel.setEmulatorInputHandler(null);
    }
    _desktopGamepad?.stop();
    GamepadSuppressor.pop();
    unawaited(GamePlaybackSystemUi.restore(this, immersive: true));
    super.dispose();
  }

  @override
  Future<void> pauseForAudioClaim() async => _quit();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_phase != _Phase.playing || _ended || _nativeOpen) return;
    if (state == AppLifecycleState.resumed) {
      _backgroundTimer?.cancel();
      _backgroundTimer = null;
      _startHeartbeat();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _heartbeat?.cancel();
      _backgroundTimer ??= Timer(_backgroundGrace, () {
        _endSession();
        _fail(
          'The stream ended while Moonfin was in the background. '
          'RomM saved your game.',
        );
      });
    }
  }

  Future<void> _start() async {
    final games = _games;
    if (games == null) {
      _fail('This server does not support games.');
      return;
    }
    try {
      final session = await games.startStream(widget.libraryId, widget.gameId);
      if (!mounted || _exiting) {
        // Left while RomM was still claiming: don't hold its container.
        _ended = true;
        unawaited(_endFor(games, session.sessionId));
        return;
      }
      _sessionId = session.sessionId;
      final deadline = DateTime.now().add(_startTimeout);
      while (mounted && !_exiting) {
        final state = await games.streamState(
          widget.libraryId,
          widget.gameId,
          session.sessionId,
        );
        if (!mounted || _exiting) return;
        if (state.isReady) {
          setState(() {
            _roomUrl = state.roomUrl;
            _phase = _Phase.playing;
          });
          _startHeartbeat();
          if (_usesNativePlayer) unawaited(_playNative(state.roomUrl!));
          return;
        }
        if (state.hasEnded) {
          _ended = true;
          _fail('RomM could not start this game.');
          return;
        }
        if (DateTime.now().isAfter(deadline)) {
          _fail('RomM took too long to start this game.');
          return;
        }
        if (state.phase != _status) setState(() => _status = state.phase);
        await Future<void>.delayed(_pollEvery);
      }
    } on GameStreamException catch (e) {
      if (e.error != 'busy' && e.error != 'alreadyPlaying') _ended = true;
      _fail(describeStreamError(e));
    } catch (e) {
      _fail('Could not start the stream. ($e)');
    }
  }

  /// Shows the room in the Android player and acts on how it closed.
  Future<void> _playNative(String roomUrl) async {
    _nativeOpen = true;
    final GameStreamNativeResult result;
    try {
      result = await GameStreamNative.open(roomUrl);
    } on PlatformException catch (e) {
      _nativeOpen = false;
      _endSession();
      _fail('Could not open the stream. (${e.message ?? e.code})');
      return;
    }
    _nativeOpen = false;
    if (!mounted || _exiting) return;
    switch (result.outcome) {
      case GameStreamNativeOutcome.quit:
        unawaited(_quit());
      case GameStreamNativeOutcome.background:
        _endSession();
        _fail(
          'The stream ended while Moonfin was in the background. '
          'RomM saved your game.',
        );
      case GameStreamNativeOutcome.error:
        _endSession();
        _fail(result.message ?? 'The stream stopped. RomM saved your game.');
      case GameStreamNativeOutcome.closed:
        // Closed for a failure this screen already shows, or by Android.
        if (_phase != _Phase.failed) unawaited(_quit());
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_heartbeatEvery, (_) => unawaited(_beat()));
  }

  Future<void> _beat() async {
    final games = _games;
    final sessionId = _sessionId;
    if (games == null || sessionId == null || _ended) return;
    try {
      final state = await games.heartbeatStream(
        widget.libraryId,
        widget.gameId,
        sessionId,
      );
      if (state.hasEnded && mounted && !_exiting) {
        _ended = true;
        _heartbeat?.cancel();
        _fail('The stream ended. RomM saved your game.');
      }
    } catch (_) {
      // One missed beat is fine; RomM waits three minutes.
    }
  }

  void _fail(String message) {
    _heartbeat?.cancel();
    if (_nativeOpen) unawaited(GameStreamNative.close());
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _failure = message;
      _menuOpen = false;
    });
  }

  /// Ends the session at most once, without waiting.
  void _endSession() {
    final games = _games;
    final sessionId = _sessionId;
    if (_ended || games == null || sessionId == null) return;
    _ended = true;
    unawaited(_endFor(games, sessionId));
  }

  Future<void> _endFor(GamesApi games, String sessionId) => games
      .endStream(widget.libraryId, widget.gameId, sessionId)
      .timeout(const Duration(seconds: 10))
      .catchError((Object _) {});

  /// Saves in RomM, ends the session and leaves.
  Future<void> _quit() async {
    if (_exiting) return;
    _exiting = true;
    _heartbeat?.cancel();
    if (_nativeOpen) unawaited(GameStreamNative.close());
    if (mounted) {
      setState(() {
        _menuOpen = false;
        _status = 'Saving…';
      });
    }
    final games = _games;
    final sessionId = _sessionId;
    if (!_ended && games != null && sessionId != null) {
      _ended = true;
      await _endFor(games, sessionId);
    }
    if (mounted) context.pop();
  }

  void _openMenu() {
    _releaseHeld();
    setState(() {
      _menuOpen = true;
      _menuSelected = 0;
    });
  }

  void _releaseHeld() {
    for (final label in _held.toList()) {
      _send(label, false);
    }
    _held.clear();
  }

  void _send(String label, bool pressed) {
    final script = GameStreamPad.pressScript(label, pressed);
    if (script == null) return;
    pressed ? _held.add(label) : _held.remove(label);
    unawaited(
      _controller?.evaluateJavascript(source: script).catchError((_) => null),
    );
  }

  void _back() {
    switch (_phase) {
      case _Phase.playing:
        if (_menuOpen) {
          setState(() => _menuOpen = false);
        } else {
          _openMenu();
        }
      case _Phase.starting:
      case _Phase.failed:
        unawaited(_quit());
    }
  }

  Future<dynamic> _onNativeGamepad(MethodCall call) async {
    if (call.method != 'onButton') return null;
    final args = (call.arguments as Map).cast<String, dynamic>();
    final label = args['label'] as String?;
    if (label != null) _onPad(label, args['pressed'] as bool);
    return null;
  }

  void _onPad(String label, bool pressed) {
    if (label == 'START') _startHeld = pressed;
    if (label == 'SELECT') _selectHeld = pressed;
    if (_startHeld && _selectHeld) {
      _comboTimer ??= Timer(_comboHold, () {
        _comboTimer = null;
        if (mounted && _phase == _Phase.playing && !_menuOpen) _openMenu();
      });
    } else {
      _comboTimer?.cancel();
      _comboTimer = null;
    }

    if (_phase != _Phase.playing || _menuOpen) {
      if (!pressed) return;
      if (_menuOpen) {
        _menuInput(label);
      } else if (label == 'BUTTON_1' || label == 'BUTTON_2') {
        unawaited(_quit());
      }
      return;
    }

    _send(label, pressed);
  }

  void _menuInput(String label) {
    switch (label) {
      case 'DPAD_UP':
      case 'DPAD_LEFT':
      case 'DPAD_DOWN':
      case 'DPAD_RIGHT':
        setState(() => _menuSelected = 1 - _menuSelected);
      case 'BUTTON_2':
        _menuChoose(_menuSelected);
      case 'BUTTON_1':
        setState(() => _menuOpen = false);
    }
  }

  void _menuChoose(int index) {
    if (index == 0) {
      setState(() => _menuOpen = false);
    } else {
      unawaited(_quit());
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            if (_roomUrl != null &&
                _phase != _Phase.failed &&
                !_usesNativePlayer)
              Positioned.fill(child: _room()),
            if (_phase != _Phase.playing || _exiting) _message(),
            // Touch and mouse have no Back on iOS, and the page keeps Escape.
            if (_phase == _Phase.playing &&
                !_menuOpen &&
                !_exiting &&
                !PlatformDetection.isTV)
              Positioned(
                top: 8,
                left: 8,
                child: SafeArea(
                  child: IconButton(
                    tooltip: 'Save and quit',
                    color: Colors.white70,
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0x66000000),
                    ),
                    icon: const Icon(Icons.close),
                    onPressed: _openMenu,
                  ),
                ),
              ),
            if (_menuOpen) _menu(),
          ],
        ),
      ),
    );
  }

  Widget _room() => InAppWebView(
    key: const ValueKey('game-stream-webview'),
    webViewEnvironment: gWebViewEnvironment,
    initialUrlRequest: URLRequest(url: WebUri(_roomUrl!)),
    // iOS's WebKit reads controllers itself; elsewhere the app forwards them.
    initialUserScripts: PlatformDetection.isIOS
        ? null
        : UnmodifiableListView([GameStreamPad.userScript()]),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      domStorageEnabled: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      supportZoom: false,
    ),
    onWebViewCreated: (controller) => _controller = controller,
    onRenderProcessGone: (controller, detail) =>
        _fail('The stream stopped unexpectedly. RomM saved your game.'),
    onReceivedError: (controller, request, error) {
      if (request.isForMainFrame == true) {
        _fail('Could not open the stream. (${error.description})');
      }
    },
    onReceivedHttpError: (controller, request, response) {
      if (request.isForMainFrame == true) {
        _fail('Could not open the stream. (HTTP ${response.statusCode})');
      }
    },
    onReceivedServerTrustAuthRequest: gAllowSelfSignedCertificates
        ? (controller, challenge) async => ServerTrustAuthResponse(
            action: acceptsUntrustedCertificate(challenge.protectionSpace.host)
                ? ServerTrustAuthResponseAction.PROCEED
                : ServerTrustAuthResponseAction.CANCEL,
          )
        : null,
    onReceivedClientCertRequest: clientCertificateResponse,
  );

  Widget _message() {
    final failed = _phase == _Phase.failed && !_exiting;
    final title = widget.gameName ?? '';
    final text = failed
        ? _failure ?? ''
        : _exiting
        ? (_status ?? 'Saving…')
        : 'Starting ${widget.label ?? 'the stream'}…'
              '${_status == null ? '' : '\n${_describePhase(_status!)}'}';
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 22),
                    ),
                  ),
                if (!failed)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: CircularProgressIndicator(),
                  ),
                Text(
                  text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
                if (failed)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: FilledButton(
                      autofocus: true,
                      onPressed: () => unawaited(_quit()),
                      child: const Text('Back'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menu() {
    Widget option(int index, String label) {
      final selected = _menuSelected == index;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: selected
            ? FilledButton(
                onPressed: () => _menuChoose(index),
                child: Text(label),
              )
            : OutlinedButton(
                onPressed: () => _menuChoose(index),
                child: Text(label),
              ),
      );
    }

    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xCC000000),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Save and quit?',
                style: TextStyle(color: Colors.white, fontSize: 20),
              ),
              const SizedBox(height: 8),
              const Text(
                'RomM saves your game when the stream ends.',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [option(0, 'Keep playing'), option(1, 'Save & quit')],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _describePhase(String phase) => switch (phase) {
    'extracting' || 'unpacking' => 'Unpacking the game…',
    _ => phase,
  };
}

/// The message for a stream the server couldn't start.
String describeStreamError(GameStreamException e) => switch (e.error) {
  'busy' =>
    e.romName == null
        ? 'All of RomM\'s streaming stations are busy. Try again shortly.'
        : 'All of RomM\'s streaming stations are busy (${e.romName} is '
              'playing). Try again shortly.',
  'alreadyPlaying' =>
    'You are already streaming a game for this system'
        '${e.romName == null ? '' : ' (${e.romName})'}. End it first, '
        'or wait three minutes after closing it elsewhere.',
  'needsRelink' => 'Link your RomM account again in Settings to stream games.',
  'notLinked' => 'Link your RomM account in Settings to stream games.',
  'needsCardImport' =>
    'Start this game once from RomM\'s own player to set up its memory card.',
  'unreachable' => 'Could not reach RomM. Try again shortly.',
  _ => 'This game can\'t stream right now.',
};
