package org.moonfin.androidtv

import android.view.KeyEvent
import android.view.MotionEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GameStreamPadTest {

    private fun motion(vararg values: Pair<Int, Float>): (Int) -> Float {
        val map = values.toMap()
        return { axis -> map[axis] ?: 0f }
    }

    @Test
    fun faceButtonsGoByPositionAndTheRemoteDrivesAAndTheDpad() {
        val pad = GameStreamPad()
        assertTrue(pad.onKey(KeyEvent.KEYCODE_BUTTON_A, true))
        assertEquals(1f, pad.buttonValue(0), 0f)
        pad.onKey(KeyEvent.KEYCODE_BUTTON_A, false)
        assertEquals(0f, pad.buttonValue(0), 0f)

        pad.onKey(KeyEvent.KEYCODE_DPAD_CENTER, true)
        assertTrue(pad.isPressed(0))
        pad.onKey(KeyEvent.KEYCODE_DPAD_LEFT, true)
        assertTrue(pad.isPressed(14))
        pad.onKey(KeyEvent.KEYCODE_BUTTON_START, true)
        assertTrue(pad.isPressed(GameStreamPad.START))
    }

    @Test
    fun otherKeysAreLeftAlone() {
        val pad = GameStreamPad()
        assertFalse(pad.onKey(KeyEvent.KEYCODE_VOLUME_UP, true))
        assertFalse(pad.onKey(KeyEvent.KEYCODE_BACK, true))
    }

    @Test
    fun theHatAndDpadKeysDontReleaseEachOther() {
        val pad = GameStreamPad()
        pad.onKey(KeyEvent.KEYCODE_DPAD_UP, true)
        pad.onMotion(motion(MotionEvent.AXIS_HAT_Y to -1f))
        pad.onMotion(motion())
        assertTrue("key still holds up after the hat centres", pad.isPressed(12))
        pad.onKey(KeyEvent.KEYCODE_DPAD_UP, false)
        pad.onMotion(motion(MotionEvent.AXIS_HAT_X to 1f))
        assertFalse(pad.isPressed(12))
        assertTrue(pad.isPressed(15))
    }

    @Test
    fun triggersTakeTheLargerOfKeyAndAxis() {
        val pad = GameStreamPad()
        pad.onMotion(motion(MotionEvent.AXIS_LTRIGGER to 0.4f, MotionEvent.AXIS_GAS to 0.75f))
        assertEquals(0.4f, pad.buttonValue(6), 0.001f)
        assertEquals(0.75f, pad.buttonValue(7), 0.001f)
        pad.onKey(KeyEvent.KEYCODE_BUTTON_L2, true)
        assertEquals(1f, pad.buttonValue(6), 0f)
        pad.onKey(KeyEvent.KEYCODE_BUTTON_L2, false)
        assertEquals(0.4f, pad.buttonValue(6), 0.001f)
    }

    @Test
    fun sticksHaveADeadzoneAndTwoDecimals() {
        val pad = GameStreamPad()
        pad.onMotion(
            motion(
                MotionEvent.AXIS_X to 0.05f,
                MotionEvent.AXIS_Y to -0.987f,
                MotionEvent.AXIS_Z to 0.333f,
                MotionEvent.AXIS_RZ to 1.5f,
            ),
        )
        assertEquals(0f, pad.axisValue(0), 0f)
        assertEquals(-0.99f, pad.axisValue(1), 0.0001f)
        assertEquals(0.33f, pad.axisValue(2), 0.0001f)
        assertEquals(1f, pad.axisValue(3), 0f)
    }

    @Test
    fun scriptCarriesTheWholePadAndOnlyChangesAreSent() {
        val pad = GameStreamPad()
        val first = pad.scriptIfChanged()
        assertEquals(
            "window.moonfinStreamPadSet&&window.moonfinStreamPadSet(" +
                "[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],[0,0,0,0]);",
            first,
        )
        assertNull(pad.scriptIfChanged())
        pad.onMotion(motion(MotionEvent.AXIS_X to 0.051f))
        assertNull("noise inside the deadzone sends nothing", pad.scriptIfChanged())
        pad.onKey(KeyEvent.KEYCODE_BUTTON_B, true)
        assertEquals(
            "window.moonfinStreamPadSet&&window.moonfinStreamPadSet(" +
                "[0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],[0,0,0,0]);",
            pad.scriptIfChanged(),
        )
        pad.resend()
        assertTrue(pad.scriptIfChanged() != null)
    }

    @Test
    fun clearReleasesEverything() {
        val pad = GameStreamPad()
        pad.onKey(KeyEvent.KEYCODE_BUTTON_A, true)
        pad.onMotion(motion(MotionEvent.AXIS_X to 1f, MotionEvent.AXIS_HAT_Y to 1f, MotionEvent.AXIS_RTRIGGER to 1f))
        pad.clear()
        for (i in 0 until GameStreamPad.BUTTON_COUNT) assertEquals(0f, pad.buttonValue(i), 0f)
        for (i in 0 until GameStreamPad.AXIS_COUNT) assertEquals(0f, pad.axisValue(i), 0f)
    }
}
