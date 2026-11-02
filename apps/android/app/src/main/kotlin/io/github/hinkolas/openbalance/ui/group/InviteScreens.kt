package io.github.hinkolas.openbalance.ui.group

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.PersistableBundle
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.design.Brand
import io.github.hinkolas.openbalance.design.ListHorizontalPadding
import io.github.hinkolas.openbalance.design.SectionFooter
import io.github.hinkolas.openbalance.model.DeviceOwner
import io.github.hinkolas.openbalance.model.GroupUi
import io.github.hinkolas.openbalance.model.errorText
import io.github.hinkolas.openbalance.model.rememberGroupUi
import io.github.hinkolas.openbalance.sync.GroupSession
import io.github.hinkolas.openbalance.sync.InviteLink
import io.github.hinkolas.openbalance.sync.addMember
import io.github.hinkolas.openbalance.sync.revokeDeviceInvite
import io.github.hinkolas.openbalance.ui.ConfirmDialog
import io.github.hinkolas.openbalance.ui.LocalAppModel
import io.github.hinkolas.openbalance.ui.LocalNav
import io.github.hinkolas.openbalance.ui.TaskAction
import io.github.hinkolas.openbalance.ui.TaskScaffold
import io.github.hinkolas.openbalance.ui.qr.QrCode
import kotlinx.coroutines.launch

/** Admin adds a member by name, then shows their invite QR. */
@Composable
fun AddMemberScreen(session: GroupSession) {
    val ui = rememberGroupUi(session)
    val nav = LocalNav.current
    val context = LocalContext.current
    val res = LocalResources.current
    val activity = LocalActivity.current as FragmentActivity
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var link by remember { mutableStateOf<InviteLink?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val focus = remember { FocusRequester() }
    val trimmed = name.trim().take(100)

    fun add() {
        if (trimmed.isEmpty() || working) return
        working = true
        error = null
        scope.launch {
            try {
                if (DeviceOwner.confirm(activity, res.getString(R.string.confirm_owner_invite))) link = session.addMember(trimmed)
            } catch (e: Exception) {
                error = res.errorText(e)
            } finally {
                working = false
            }
        }
    }

    val shown = link
    if (shown != null) {
        TaskScaffold("", onClose = { nav.popBackStack() }, action = TaskAction(stringResource(R.string.done)) { nav.popBackStack() }) { padding ->
            InviteQrContent(ui, shown, Modifier.padding(padding))
        }
        return
    }
    TaskScaffold(
        stringResource(R.string.add_member),
        onClose = { nav.popBackStack() },
        action = TaskAction(stringResource(R.string.add), enabled = trimmed.isNotEmpty(), busy = working) { add() },
    ) { padding ->
        Column(Modifier.padding(padding).padding(horizontal = ListHorizontalPadding, vertical = 8.dp)) {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text(stringResource(R.string.name)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { add() }),
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
            )
            SectionFooter(error ?: stringResource(R.string.add_member_footer), if (error != null) Brand.negative else MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    LaunchedEffect(Unit) { focus.requestFocus() }
}

/** An unclaimed member's invite QR. */
@Composable
fun InviteScreen(session: GroupSession) {
    val ui = rememberGroupUi(session)
    val nav = LocalNav.current
    val model = LocalAppModel.current
    val link = remember { model.handoff.invite.also { model.handoff.invite = null } }
    if (link == null) {
        LaunchedEffect(Unit) { nav.popBackStack() }
        return
    }
    TaskScaffold("", onClose = { nav.popBackStack() }, action = TaskAction(stringResource(R.string.done)) { nav.popBackStack() }) { padding ->
        InviteQrContent(ui, link, Modifier.padding(padding))
    }
}

/** The QR for a further device of your own member, with a way to withdraw it. */
@Composable
fun DeviceInviteScreen(session: GroupSession) {
    val ui = rememberGroupUi(session)
    val nav = LocalNav.current
    val model = LocalAppModel.current
    val scope = rememberCoroutineScope()
    val link = remember { model.handoff.invite.also { model.handoff.invite = null } }
    var confirmRevoke by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    if (link == null) {
        LaunchedEffect(Unit) { nav.popBackStack() }
        return
    }
    TaskScaffold("", onClose = { nav.popBackStack() }, action = TaskAction(stringResource(R.string.done)) { nav.popBackStack() }) { padding ->
        InviteQrContent(ui, link, Modifier.padding(padding), isDevice = true) {
            TextButton(onClick = { confirmRevoke = true }, enabled = !working) {
                Icon(Icons.Outlined.Cancel, null, tint = Brand.negative)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.revoke_qr), color = Brand.negative)
            }
        }
    }
    if (confirmRevoke) {
        ConfirmDialog(
            title = stringResource(R.string.revoke_qr_title),
            message = stringResource(R.string.revoke_qr_message),
            confirm = stringResource(R.string.revoke),
            onConfirm = {
                working = true
                scope.launch {
                    try {
                        session.revokeDeviceInvite()
                    } catch (_: Exception) {
                    }
                    working = false
                    nav.popBackStack()
                }
            },
            onDismiss = { confirmRevoke = false },
        )
    }
}

@Composable
private fun InviteQrContent(ui: GroupUi, link: InviteLink, modifier: Modifier = Modifier, isDevice: Boolean = false, footer: @Composable () -> Unit = {}) {
    val context = LocalContext.current
    val res = LocalResources.current
    val name = ui.name(link.memberId)
    val me = ui.state.members[ui.me]?.name ?: ""
    val url = link.url
    val image = remember(url) { QrCode.image(url) }
    var copied by remember { mutableStateOf(false) }
    Column(
        modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                if (isDevice) stringResource(R.string.add_device) else stringResource(R.string.invite_member_title, name),
                style = MaterialTheme.typography.headlineSmall,
                textAlign = TextAlign.Center,
            )
            Text(
                if (isDevice) stringResource(R.string.device_invite_text, me) else stringResource(R.string.invite_member_text, name),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
        // Always dark on white, in dark mode too: scanners need the contrast.
        Image(
            image,
            contentDescription = stringResource(R.string.invite_qr_code),
            filterQuality = FilterQuality.None,
            contentScale = ContentScale.Fit,
            modifier = Modifier
                .widthIn(max = 320.dp)
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(RoundedCornerShape(20.dp))
                .background(Color.White)
                .padding(18.dp),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton(onClick = { share(context, url) }) {
                Icon(Icons.Outlined.Share, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.share))
            }
            OutlinedButton(onClick = {
                copy(context, url)
                copied = true
            }) {
                Icon(if (copied) Icons.Outlined.Check else Icons.Outlined.ContentCopy, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(stringResource(if (copied) R.string.copied else R.string.copy_link))
            }
        }
        footer()
    }
}

private fun share(context: Context, url: String) {
    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, url)
    context.startActivity(Intent.createChooser(send, null))
}

/** The link holds the group's key: mark it sensitive so the clipboard preview hides it. */
private fun copy(context: Context, url: String) {
    val clip = ClipData.newPlainText("invite", url)
    clip.description.extras = PersistableBundle().apply { putBoolean("android.content.extra.IS_SENSITIVE", true) }
    context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
}
