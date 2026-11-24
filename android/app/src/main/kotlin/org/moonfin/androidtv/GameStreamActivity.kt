package org.moonfin.androidtv

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.WindowManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONObject

/**
 * Plays a RomM stream room in a plain WebView that fills its own activity.
 *
 * Inside Flutter the room ran in a platform view: its frames were drawn into a
 * texture and composited a second time, and every controller press crossed two
 * platform channels and the Dart event loop before reaching the page. Here the
 * WebView is the whole window, and [GameStreamPad] turns key and motion events
 * into a page call straight from [dispatchKeyEvent] and
 * [dispatchGenericMotionEvent].
 *
 * The Dart screen keeps the session (claim, heartbeats, Save & quit) and reads
 * this activity's result: [RESULT_QUIT], [RESULT_BACKGROUND] or [RESULT_ERROR].
 */
class GameStreamActivity : Activity() {

    companion object {
        const val EXTRA_URL = "moonfin.game_stream.url"
        const val EXTRA_PAD_SCRIPT = "moonfin.game_stream.pad_script"
        const val EXTRA_PAGE_SCRIPT = "moonfin.game_stream.page_script"
        const val EXTRA_INSPECTABLE = "moonfin.game_stream.inspectable"
        const val EXTRA_RESULT = "moonfin.game_stream.result"
        const val EXTRA_MESSAGE = "moonfin.game_stream.message"
        const val RESULT_QUIT = "quit"
        const val RESULT_BACKGROUND = "background"
        const val RESULT_ERROR = "error"

        /** RomM's own reaper waits three minutes; leave well before it. */
        private const val BACKGROUND_GRACE_MS = 60_000L
        private const val COMBO_HOLD_MS = 800L
        private const val FALLBACK_INJECT_EVERY_MS = 1_000L
        private const val FALLBACK_INJECT_FOR_MS = 20_000L
    }

    private lateinit var webView: WebView
    private val pad = GameStreamPad()
    private val handler = Handler(Looper.getMainLooper())
    private var padScript = ""
    private var pageScript: String? = null
    private var menu: AlertDialog? = null
    private var finished = false
    private var injectAtDocumentStart = false
    private var pageLoadedAt = 0L

    private val leaveInBackground = Runnable {
        finishWith(RESULT_BACKGROUND, null)
    }

    private val openMenuFromCombo = Runnable {
        if (pad.isPressed(GameStreamPad.START) && pad.isPressed(GameStreamPad.SELECT)) showMenu()
    }

    private val fallbackInject = object : Runnable {
        override fun run() {
            if (finished || !::webView.isInitialized) return
            injectIntoAllFrames()
            if (System.currentTimeMillis() - pageLoadedAt < FALLBACK_INJECT_FOR_MS) {
                handler.postDelayed(this, FALLBACK_INJECT_EVERY_MS)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(EXTRA_URL)
        if (url.isNullOrBlank()) {
            finishWith(RESULT_ERROR, "Missing stream address.")
            return
        }
        padScript = intent.getStringExtra(EXTRA_PAD_SCRIPT).orEmpty()
        pageScript = intent.getStringExtra(EXTRA_PAGE_SCRIPT)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemBars()
        WebView.setWebContentsDebuggingEnabled(intent.getBooleanExtra(EXTRA_INSPECTABLE, false))
        webView = buildWebView(url)
        setContentView(webView)
        webView.requestFocus()
        webView.loadUrl(url)
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun buildWebView(url: String): WebView = WebView(this).apply {
        setBackgroundColor(Color.BLACK)
        isFocusable = true
        isFocusableInTouchMode = true
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.mediaPlaybackRequiresUserGesture = false
        settings.setSupportZoom(false)
        val origin = originOf(url)
        if (padScript.isNotEmpty() && origin != null &&
            WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
        ) {
            // Every frame of the room's origin, the Selkies frame included, gets
            // the pad before its own scripts run.
            WebViewCompat.addDocumentStartJavaScript(this, padScript, setOf(origin))
            injectAtDocumentStart = true
        }
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = false

            override fun onPageFinished(view: WebView, url: String?) {
                pageLoadedAt = System.currentTimeMillis()
                pad.resend()
                if (!injectAtDocumentStart || pageScript != null) {
                    handler.removeCallbacks(fallbackInject)
                    handler.post(fallbackInject)
                }
            }

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) {
                    finishWith(RESULT_ERROR, "Could not open the stream. (${error.description})")
                }
            }

            override fun onReceivedHttpError(
                view: WebView,
                request: WebResourceRequest,
                errorResponse: WebResourceResponse,
            ) {
                if (request.isForMainFrame) {
                    finishWith(RESULT_ERROR, "Could not open the stream. (HTTP ${errorResponse.statusCode})")
                }
            }

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                finishWith(RESULT_ERROR, "The stream stopped unexpectedly. RomM saved your game.")
                return true
            }
        }
    }

    /**
     * Without document-start scripts, evaluates the pad (and the page script)
     * in every same-origin frame, again for a while after load: the Selkies
     * frame is added after the room page finishes. Both scripts guard against
     * running twice.
     */
    private fun injectIntoAllFrames() {
        val sources = buildList {
            if (!injectAtDocumentStart && padScript.isNotEmpty()) add(padScript)
            pageScript?.let(::add)
        }
        if (sources.isEmpty()) return
        val quoted = sources.joinToString(",") { JSONObject.quote(it) }
        webView.evaluateJavascript(
            "(function(srcs){function each(w){try{srcs.forEach(function(s){w.eval(s);});}" +
                "catch(e){return;}for(var i=0;i<w.frames.length;i++)each(w.frames[i]);}" +
                "each(window);})([$quoted]);",
            null,
        )
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (finished) return true
        val code = event.keyCode
        if (code == KeyEvent.KEYCODE_BACK || code == KeyEvent.KEYCODE_ESCAPE) {
            if (event.action == KeyEvent.ACTION_UP && !event.isCanceled) showMenu()
            return true
        }
        val pressed = event.action == KeyEvent.ACTION_DOWN
        if (event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_UP) {
            return super.dispatchKeyEvent(event)
        }
        if (pressed && event.repeatCount > 0 && pad.onKey(code, true)) return true
        if (pad.onKey(code, pressed)) {
            push()
            watchCombo()
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (finished) return true
        val fromPad = event.isFromSource(InputDevice.SOURCE_JOYSTICK) ||
            event.isFromSource(InputDevice.SOURCE_GAMEPAD)
        if (fromPad && event.action == MotionEvent.ACTION_MOVE) {
            pad.onMotion { axis -> event.getAxisValue(axis) }
            push()
            return true
        }
        return super.dispatchGenericMotionEvent(event)
    }

    private fun push() {
        if (!::webView.isInitialized) return
        pad.scriptIfChanged()?.let { webView.evaluateJavascript(it, null) }
    }

    private fun watchCombo() {
        handler.removeCallbacks(openMenuFromCombo)
        if (pad.isPressed(GameStreamPad.START) && pad.isPressed(GameStreamPad.SELECT)) {
            handler.postDelayed(openMenuFromCombo, COMBO_HOLD_MS)
        }
    }

    private fun releasePad() {
        pad.clear()
        push()
    }

    private fun showMenu() {
        if (finished || menu?.isShowing == true) return
        releasePad()
        menu = AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle("Save and quit?")
            .setMessage("RomM saves your game when the stream ends.")
            .setNegativeButton("Keep playing") { dialog, _ -> dialog.dismiss() }
            .setPositiveButton("Save & quit") { _, _ -> finishWith(RESULT_QUIT, null) }
            .setOnDismissListener {
                menu = null
                hideSystemBars()
            }
            .create()
            .also { dialog ->
                dialog.show()
                dialog.getButton(AlertDialog.BUTTON_NEGATIVE)?.requestFocus()
            }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars() else releasePad()
    }

    override fun onStart() {
        super.onStart()
        handler.removeCallbacks(leaveInBackground)
    }

    override fun onStop() {
        if (!finished && !isFinishing) handler.postDelayed(leaveInBackground, BACKGROUND_GRACE_MS)
        super.onStop()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        menu?.dismiss()
        if (::webView.isInitialized) {
            webView.stopLoading()
            webView.loadUrl("about:blank")
            webView.destroy()
        }
        super.onDestroy()
    }

    private fun finishWith(result: String, message: String?) {
        if (finished) return
        finished = true
        handler.removeCallbacksAndMessages(null)
        setResult(
            RESULT_OK,
            Intent().putExtra(EXTRA_RESULT, result).apply {
                if (message != null) putExtra(EXTRA_MESSAGE, message)
            },
        )
        finish()
    }

    private fun hideSystemBars() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowCompat.getInsetsController(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun originOf(url: String): String? {
        val uri = Uri.parse(url)
        val scheme = uri.scheme ?: return null
        val host = uri.host ?: return null
        val port = if (uri.port != -1) ":${uri.port}" else ""
        return "$scheme://$host$port"
    }
}
