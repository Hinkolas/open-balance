package io.github.hinkolas.openbalance

import android.content.Intent
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.fragment.app.FragmentActivity
import io.github.hinkolas.openbalance.design.OpenBalanceTheme
import io.github.hinkolas.openbalance.ui.Root

/** The one activity. A FragmentActivity so the biometric prompt can attach to it. */
class MainActivity : FragmentActivity() {
    private val model get() = (application as OpenBalanceApplication).model

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) handle(intent)
        setContent {
            OpenBalanceTheme { Root(model) }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** `openbalance://join?…`, opened from the camera app, a browser or a message. */
    private fun handle(intent: Intent?) {
        if (intent?.action == Intent.ACTION_VIEW) intent.dataString?.let(model::handle)
    }
}
