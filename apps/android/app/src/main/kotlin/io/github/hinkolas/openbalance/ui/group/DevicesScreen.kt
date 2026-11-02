package io.github.hinkolas.openbalance.ui.group

import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.QrCode2
import androidx.compose.material.icons.outlined.Smartphone
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.fragment.app.FragmentActivity
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.core.Bytes
import io.github.hinkolas.openbalance.design.Brand
import io.github.hinkolas.openbalance.design.ListBottomPadding
import io.github.hinkolas.openbalance.design.OneLine
import io.github.hinkolas.openbalance.design.SectionFooter
import io.github.hinkolas.openbalance.design.section
import io.github.hinkolas.openbalance.model.Dates
import io.github.hinkolas.openbalance.model.DeviceOwner
import io.github.hinkolas.openbalance.model.errorText
import io.github.hinkolas.openbalance.model.rememberGroupUi
import io.github.hinkolas.openbalance.sync.GroupSession
import io.github.hinkolas.openbalance.sync.addDevice
import io.github.hinkolas.openbalance.sync.removeDevice
import io.github.hinkolas.openbalance.ui.ConfirmDialog
import io.github.hinkolas.openbalance.ui.ErrorDialog
import io.github.hinkolas.openbalance.ui.LocalAppModel
import io.github.hinkolas.openbalance.ui.LocalNav
import io.github.hinkolas.openbalance.ui.Routes
import io.github.hinkolas.openbalance.ui.TaskScaffold
import io.github.hinkolas.openbalance.ui.overview.listItemColors
import kotlinx.coroutines.launch

/** The devices of my own member: which one this is, when each joined, remove a lost one, add another. */
@Composable
fun DevicesScreen(session: GroupSession) {
    val ui = rememberGroupUi(session)
    val model = LocalAppModel.current
    val nav = LocalNav.current
    val res = LocalResources.current
    val activity = LocalActivity.current as FragmentActivity
    val scope = rememberCoroutineScope()
    var removing by remember { mutableStateOf<Bytes?>(null) }
    var error by remember { mutableStateOf<Pair<Int, String>?>(null) }
    val keys = ui.state.members[ui.me]?.keys ?: emptyList()

    fun addDevice() = scope.launch {
        if (!DeviceOwner.confirm(activity, res.getString(R.string.confirm_owner_device))) return@launch
        try {
            model.handoff.invite = session.addDevice()
            nav.navigate(Routes.DEVICE_INVITE)
        } catch (e: Exception) {
            error = R.string.couldnt_create_invite to res.errorText(e)
        }
    }

    TaskScaffold(stringResource(R.string.your_devices), onClose = { nav.popBackStack() }, back = true) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = ListBottomPadding) {
            val rows = buildList<@Composable () -> Unit> {
                for (key in keys) add {
                    val mine = key == session.deviceKey
                    val code = keyCode(key)
                    val added = ui.state.keyAddedAt[key]?.let(Dates::timestamp)?.let { Dates.display(Dates.localDay(it).toString()) }
                    ListItem(
                        colors = listItemColors(),
                        leadingContent = { Icon(if (mine) Icons.Outlined.Smartphone else Icons.Outlined.PhoneAndroid, null, tint = MaterialTheme.colorScheme.onSurfaceVariant) },
                        headlineContent = { OneLine(stringResource(if (mine) R.string.this_device else R.string.other_device)) },
                        supportingContent = { Text(if (added != null) stringResource(R.string.device_added_code, added, code) else code) },
                        trailingContent = {
                            if (!mine) IconButton(onClick = { removing = key }) { Icon(Icons.Outlined.Delete, stringResource(R.string.remove)) }
                        },
                    )
                }
                add {
                    ListItem(
                        modifier = Modifier.clickable { addDevice() },
                        colors = listItemColors(),
                        leadingContent = { Icon(Icons.Outlined.QrCode2, null, tint = Brand.tint) },
                        headlineContent = { Text(stringResource(R.string.add_device), color = Brand.tint) },
                    )
                }
            }
            section(
                "devices", rows = rows,
                footer = { SectionFooter(res.getString(if (ui.isAdmin) R.string.devices_footer_admin else R.string.devices_footer)) },
            )
        }
    }

    removing?.let { key ->
        ConfirmDialog(
            title = stringResource(R.string.remove_device_title),
            message = stringResource(R.string.remove_device_message),
            confirm = stringResource(R.string.remove),
            onConfirm = {
                scope.launch {
                    try {
                        session.removeDevice(session.me, key)
                    } catch (e: Exception) {
                        error = R.string.couldnt_remove_device to res.errorText(e)
                    }
                }
            },
            onDismiss = { removing = null },
        )
    }
    error?.let { (title, message) -> ErrorDialog(stringResource(title), message) { error = null } }
}

/** The first 4 bytes of a key in uppercase hex, two groups: "3F2A 91C0". */
internal fun keyCode(key: Bytes): String {
    val hex = key.toByteArray().take(4).joinToString("") { "%02X".format(it.toInt() and 0xFF) }
    return hex.chunked(4).joinToString(" ")
}
