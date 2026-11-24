package org.moonfin.androidtv

import android.view.KeyEvent
import android.view.MotionEvent
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * One W3C standard-layout gamepad, kept from Android key and motion events for
 * [GameStreamActivity]. The stream page reads it through the shim's
 * `window.moonfinStreamPadSet(buttons, axes)`.
 *
 * Face buttons go by position (A is the bottom one, standard index 0). A TV
 * remote's d-pad and OK drive the d-pad and A. D-pad state from keys and from
 * the hat axes is kept apart and combined, and each trigger is the larger of
 * its key and its axis, so one source releasing can't drop the other's press.
 */
class GameStreamPad {
    private val keyButtons = FloatArray(BUTTON_COUNT)
    private val hatButtons = FloatArray(BUTTON_COUNT)
    private val triggerAxes = FloatArray(2)
    private val axes = FloatArray(AXIS_COUNT)
    private var lastScript: String? = null

    /** True when [keyCode] is a pad button; [pressed] is then applied. */
    fun onKey(keyCode: Int, pressed: Boolean): Boolean {
        val index = KEY_BUTTONS[keyCode] ?: return false
        keyButtons[index] = if (pressed) 1f else 0f
        return true
    }

    /** Reads sticks, triggers and the hat from one joystick move. */
    fun onMotion(axis: (Int) -> Float) {
        axes[0] = stick(axis(MotionEvent.AXIS_X))
        axes[1] = stick(axis(MotionEvent.AXIS_Y))
        axes[2] = stick(axis(MotionEvent.AXIS_Z))
        axes[3] = stick(axis(MotionEvent.AXIS_RZ))
        triggerAxes[0] = trigger(max(axis(MotionEvent.AXIS_LTRIGGER), axis(MotionEvent.AXIS_BRAKE)))
        triggerAxes[1] = trigger(max(axis(MotionEvent.AXIS_RTRIGGER), axis(MotionEvent.AXIS_GAS)))
        val hatX = axis(MotionEvent.AXIS_HAT_X)
        val hatY = axis(MotionEvent.AXIS_HAT_Y)
        hatButtons[DPAD_LEFT] = if (hatX < -HAT_THRESHOLD) 1f else 0f
        hatButtons[DPAD_RIGHT] = if (hatX > HAT_THRESHOLD) 1f else 0f
        hatButtons[DPAD_UP] = if (hatY < -HAT_THRESHOLD) 1f else 0f
        hatButtons[DPAD_DOWN] = if (hatY > HAT_THRESHOLD) 1f else 0f
    }

    /** Releases everything, e.g. when the window loses focus. */
    fun clear() {
        keyButtons.fill(0f)
        hatButtons.fill(0f)
        triggerAxes.fill(0f)
        axes.fill(0f)
    }

    fun buttonValue(index: Int): Float {
        val trigger = when (index) {
            LEFT_TRIGGER -> triggerAxes[0]
            RIGHT_TRIGGER -> triggerAxes[1]
            else -> 0f
        }
        return max(max(keyButtons[index], hatButtons[index]), trigger)
    }

    fun axisValue(index: Int): Float = axes[index]

    fun isPressed(index: Int): Boolean = buttonValue(index) > 0.1f

    /** The page call for the current state. */
    fun script(): String {
        val buttons = (0 until BUTTON_COUNT).joinToString(",") { format(buttonValue(it)) }
        val sticks = axes.joinToString(",") { format(it) }
        return "window.moonfinStreamPadSet&&window.moonfinStreamPadSet([$buttons],[$sticks]);"
    }

    /** [script] when the state differs from the last one returned, else null. */
    fun scriptIfChanged(): String? {
        val next = script()
        if (next == lastScript) return null
        lastScript = next
        return next
    }

    /** Forgets the last sent state, so the next [scriptIfChanged] always sends. */
    fun resend() {
        lastScript = null
    }

    private fun stick(value: Float): Float = if (abs(value) < STICK_DEADZONE) 0f else round(value)

    private fun trigger(value: Float): Float = if (value < TRIGGER_DEADZONE) 0f else round(value)

    // Two decimals: finer than any game reads, coarse enough that stick noise
    // doesn't send a page call per motion event.
    private fun round(value: Float): Float = (value.coerceIn(-1f, 1f) * 100f).roundToInt() / 100f

    private fun format(value: Float): String =
        if (value == 0f) "0" else if (value == 1f) "1" else value.toString()

    companion object {
        const val BUTTON_COUNT = 17
        const val AXIS_COUNT = 4
        const val SELECT = 8
        const val START = 9
        private const val LEFT_TRIGGER = 6
        private const val RIGHT_TRIGGER = 7
        private const val DPAD_UP = 12
        private const val DPAD_DOWN = 13
        private const val DPAD_LEFT = 14
        private const val DPAD_RIGHT = 15
        private const val HAT_THRESHOLD = 0.5f
        private const val STICK_DEADZONE = 0.08f
        private const val TRIGGER_DEADZONE = 0.05f

        private val KEY_BUTTONS = mapOf(
            KeyEvent.KEYCODE_BUTTON_A to 0,
            KeyEvent.KEYCODE_DPAD_CENTER to 0,
            KeyEvent.KEYCODE_ENTER to 0,
            KeyEvent.KEYCODE_BUTTON_B to 1,
            KeyEvent.KEYCODE_BUTTON_X to 2,
            KeyEvent.KEYCODE_BUTTON_Y to 3,
            KeyEvent.KEYCODE_BUTTON_L1 to 4,
            KeyEvent.KEYCODE_BUTTON_R1 to 5,
            KeyEvent.KEYCODE_BUTTON_L2 to LEFT_TRIGGER,
            KeyEvent.KEYCODE_BUTTON_R2 to RIGHT_TRIGGER,
            KeyEvent.KEYCODE_BUTTON_SELECT to SELECT,
            KeyEvent.KEYCODE_BUTTON_START to START,
            KeyEvent.KEYCODE_BUTTON_THUMBL to 10,
            KeyEvent.KEYCODE_BUTTON_THUMBR to 11,
            KeyEvent.KEYCODE_DPAD_UP to DPAD_UP,
            KeyEvent.KEYCODE_DPAD_DOWN to DPAD_DOWN,
            KeyEvent.KEYCODE_DPAD_LEFT to DPAD_LEFT,
            KeyEvent.KEYCODE_DPAD_RIGHT to DPAD_RIGHT,
            KeyEvent.KEYCODE_BUTTON_MODE to 16,
        )
    }
}
