import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// A virtual controller for RomM's stream page.
///
/// The stream page (a Selkies client in a same-origin frame inside RomM's
/// room) reads the browser Gamepad API: it polls `navigator.getGamepads()`
/// every few milliseconds once a `gamepadconnected` event names a pad. Android
/// System WebView and the desktop WebViews hand a page no usable pads, so the
/// app forwards the controller Flutter sees, the same way the EmulatorJS
/// player gets it: [script] replaces `getGamepads()` in every frame with one
/// standard-layout pad, and [pressScript] presses or releases its buttons.
abstract final class GameStreamPad {
  /// The W3C standard gamepad index for each of the app's controller labels
  /// (the EmulatorJS names the Android and desktop readers report). The face
  /// buttons go by position: BUTTON_2 is the bottom one, standard index 0.
  static const Map<String, int> standardIndex = {
    'BUTTON_2': 0,
    'BUTTON_1': 1,
    'BUTTON_4': 2,
    'BUTTON_0': 3,
    'BUTTON_6': 4,
    'BUTTON_7': 5,
    'LEFT_BOTTOM_SHOULDER': 6,
    'RIGHT_BOTTOM_SHOULDER': 7,
    'SELECT': 8,
    'START': 9,
    'BUTTON_10': 10,
    'BUTTON_11': 11,
    'DPAD_UP': 12,
    'DPAD_DOWN': 13,
    'DPAD_LEFT': 14,
    'DPAD_RIGHT': 15,
  };

  /// JavaScript that presses or releases [label], or null for a label the
  /// standard layout has no button for.
  static String? pressScript(String label, bool pressed) {
    final index = standardIndex[label];
    if (index == null) return null;
    return 'window.moonfinStreamPad && window.moonfinStreamPad($index, $pressed);';
  }

  /// Installed at document start in every frame. Each frame's
  /// `getGamepads()` reads one pad state kept on the top frame, which the
  /// room and the stream frame share an origin with. The pad appears on the
  /// first press, and frames are told so with `gamepadconnected`.
  static const String script = r'''
(function () {
  if (window.__moonfinPadInstalled) return;
  window.__moonfinPadInstalled = true;
  var top = window;
  try { if (window.top && window.top.document) top = window.top; } catch (e) {}
  var state = top.__moonfinPad;
  if (!state) {
    state = top.__moonfinPad = { connected: false, timestamp: 0, axes: [0, 0, 0, 0], buttons: [], frames: [] };
    for (var i = 0; i < 17; i++) state.buttons.push({ pressed: false, touched: false, value: 0 });
  }
  function pad() {
    return {
      id: 'Moonfin controller (STANDARD GAMEPAD)',
      index: 0,
      connected: true,
      mapping: 'standard',
      timestamp: state.timestamp,
      axes: state.axes.slice(),
      buttons: state.buttons.map(function (b) { return { pressed: b.pressed, touched: b.touched, value: b.value }; }),
      vibrationActuator: null
    };
  }
  try {
    // Writable too: the stream page assigns its own getGamepads (in strict
    // mode, so a read-only one throws and stops the page from starting).
    Object.defineProperty(navigator, 'getGamepads', {
      configurable: true,
      writable: true,
      value: function () { return [state.connected ? pad() : null, null, null, null]; }
    });
  } catch (e) {}
  function announce() {
    var event = new Event('gamepadconnected');
    Object.defineProperty(event, 'gamepad', { value: pad() });
    window.dispatchEvent(event);
  }
  state.frames.push(announce);
  if (state.connected) setTimeout(announce, 0);
  if (window === top) {
    window.moonfinStreamPad = function (index, pressed) {
      var button = state.buttons[index];
      if (!button) return;
      button.pressed = button.touched = !!pressed;
      button.value = pressed ? 1 : 0;
      state.timestamp = performance.now();
      if (!state.connected) {
        state.connected = true;
        state.frames.forEach(function (f) { try { f(); } catch (e) {} });
      }
    };
  }
})();
''';

  /// [script] for every frame, at document start.
  static UserScript userScript() => UserScript(
    source: script,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    forMainFrameOnly: false,
  );
}
