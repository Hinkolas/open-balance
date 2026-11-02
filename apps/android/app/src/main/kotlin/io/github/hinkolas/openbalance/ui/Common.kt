package io.github.hinkolas.openbalance.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.design.Brand

/** The trailing action of a task screen: Next, Save, Create … */
data class TaskAction(val label: String, val enabled: Boolean = true, val busy: Boolean = false, val onClick: () -> Unit)

/**
 * A self-contained task (new payment, join, create group): close or back
 * leading, the title, and the action trailing, like a Material full-screen
 * dialog and the iOS sheets it stands in for.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TaskScaffold(
    title: String,
    onClose: () -> Unit,
    back: Boolean = false,
    action: TaskAction? = null,
    actions: @Composable () -> Unit = {},
    content: @Composable (PaddingValues) -> Unit,
) {
    val scroll = TopAppBarDefaults.pinnedScrollBehavior()
    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = {
            TopAppBar(
                title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    IconButton(onClick = onClose) {
                        if (back) {
                            Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.back))
                        } else {
                            Icon(Icons.Outlined.Close, stringResource(R.string.close))
                        }
                    }
                },
                actions = {
                    actions()
                    if (action != null) {
                        if (action.busy) {
                            Box(Modifier.padding(horizontal = 16.dp)) { CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp) }
                        } else {
                            TextButton(onClick = action.onClick, enabled = action.enabled) {
                                Text(action.label, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                },
                scrollBehavior = scroll,
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().imePadding()) { content(padding) }
    }
}

/** A yes/no question before something that can't be undone. */
@Composable
fun ConfirmDialog(title: String, message: String, confirm: String, destructive: Boolean = true, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = {
            TextButton(onClick = {
                onDismiss()
                onConfirm()
            }) { Text(confirm, color = if (destructive) Brand.negative else Brand.tint) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/** An error worth a dialog. */
@Composable
fun ErrorDialog(title: String?, message: String, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = title?.let { { Text(it) } },
        text = { Text(message) },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.ok)) } },
    )
}
