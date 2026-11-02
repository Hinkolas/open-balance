package io.github.hinkolas.openbalance.ui.group

import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Logout
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.PersonAdd
import androidx.compose.material.icons.outlined.QrCode2
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.core.EventData
import io.github.hinkolas.openbalance.core.GroupUpdatedData
import io.github.hinkolas.openbalance.core.Member
import io.github.hinkolas.openbalance.core.MemberId
import io.github.hinkolas.openbalance.core.MemberUpdatedData
import io.github.hinkolas.openbalance.design.Brand
import io.github.hinkolas.openbalance.design.MemberAvatar
import io.github.hinkolas.openbalance.design.OneLine
import io.github.hinkolas.openbalance.design.SectionFooter
import io.github.hinkolas.openbalance.design.section
import io.github.hinkolas.openbalance.model.DeviceOwner
import io.github.hinkolas.openbalance.model.GroupUi
import io.github.hinkolas.openbalance.model.errorText
import io.github.hinkolas.openbalance.model.rememberGroupUi
import io.github.hinkolas.openbalance.sync.GroupSession
import io.github.hinkolas.openbalance.sync.addDevice
import io.github.hinkolas.openbalance.sync.inviteLink
import io.github.hinkolas.openbalance.sync.renewInvite
import io.github.hinkolas.openbalance.ui.ConfirmDialog
import io.github.hinkolas.openbalance.ui.ErrorDialog
import io.github.hinkolas.openbalance.ui.LocalAppModel
import io.github.hinkolas.openbalance.ui.LocalNav
import io.github.hinkolas.openbalance.ui.Routes
import io.github.hinkolas.openbalance.ui.overview.listItemColors
import io.github.hinkolas.openbalance.ui.shell.TabScaffold
import kotlinx.coroutines.launch
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

sealed interface RenameTarget {
    data class Group(val name: String) : RenameTarget
    data class Member(val id: MemberId, val name: String) : RenameTarget
}

/** Members, invites and devices, this group's settings, your groups, your servers. */
@Composable
fun GroupScreen(session: GroupSession) {
    val ui = rememberGroupUi(session)
    val model = LocalAppModel.current
    val nav = LocalNav.current
    val res = LocalResources.current
    val activity = LocalActivity.current as FragmentActivity
    val scope = rememberCoroutineScope()
    val sessions by model.sessions.collectAsStateWithLifecycle()
    val servers by model.servers.collectAsStateWithLifecycle()
    val credentials by session.credentials.collectAsStateWithLifecycle()
    var renaming by remember { mutableStateOf<RenameTarget?>(null) }
    var confirmLeave by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun showInvite(member: MemberId) = scope.launch {
        if (!DeviceOwner.confirm(activity, res.getString(R.string.confirm_owner_invite))) return@launch
        try {
            // Created on another device: issue a fresh invite.
            model.handoff.invite = session.inviteLink(member) ?: session.renewInvite(member)
            nav.navigate(Routes.INVITE)
        } catch (e: Exception) {
            error = res.errorText(e)
        }
    }

    fun showDeviceInvite() = scope.launch {
        if (!DeviceOwner.confirm(activity, res.getString(R.string.confirm_owner_device))) return@launch
        try {
            model.handoff.invite = session.addDevice()
            nav.navigate(Routes.DEVICE_INVITE)
        } catch (e: Exception) {
            error = res.errorText(e)
        }
    }

    TabScaffold(session, title = { Text(stringResource(R.string.tab_group)) }, addButton = false) {
        val memberRows = buildList<@Composable () -> Unit> {
            for (m in ui.state.orderedMembers) add {
                MemberRow(ui, m, invite = { showInvite(m.id) }, rename = { renaming = RenameTarget.Member(m.id, m.name) }, addDevice = { showDeviceInvite() })
            }
            if (ui.isAdmin) add { ActionRow(Icons.Outlined.PersonAdd, stringResource(R.string.add_member)) { nav.navigate(Routes.ADD_MEMBER) } }
            add { ActionRow(Icons.Outlined.QrCode2, stringResource(R.string.add_device)) { showDeviceInvite() } }
        }
        section(
            "members", header = res.getString(R.string.members), rows = memberRows,
            footer = { SectionFooter(res.getString(if (ui.isAdmin) R.string.members_footer_admin else R.string.members_footer)) },
        )

        val groupRows = buildList<@Composable () -> Unit> {
            add { Info(stringResource(R.string.currency), ui.state.currency) }
            add { Info(stringResource(R.string.server), credentials.server.toHttpUrlOrNull()?.host ?: credentials.server) }
            if (ui.isAdmin) add { ActionRow(Icons.Outlined.Edit, stringResource(R.string.rename_group)) { renaming = RenameTarget.Group(ui.state.name) } }
        }
        section("this-group", header = res.getString(R.string.this_group), rows = groupRows)

        val yourGroups = buildList<@Composable () -> Unit> {
            for (s in sessions) add {
                val state by s.state.collectAsState()
                ListItem(
                    modifier = Modifier.clickable { model.activate(s.id) },
                    colors = listItemColors(),
                    headlineContent = { OneLine(state.name) },
                    trailingContent = { if (s.id == session.id) Icon(Icons.Filled.Check, null, tint = Brand.tint) },
                )
            }
            add { ActionRow(Icons.Outlined.QrCodeScanner, stringResource(R.string.join_with_invite)) { nav.navigate(Routes.JOIN) } }
            add { ActionRow(Icons.Outlined.Add, stringResource(R.string.create_group)) { nav.navigate(Routes.CREATE_GROUP) } }
        }
        section("groups", header = res.getString(R.string.your_groups), rows = yourGroups)

        val serverRows = buildList<@Composable () -> Unit> {
            for (s in servers) add {
                ListItem(
                    colors = listItemColors(),
                    headlineContent = { OneLine(s.name) },
                    supportingContent = { OneLine(s.server.toHttpUrlOrNull()?.host ?: s.server, style = MaterialTheme.typography.bodyMedium) },
                    trailingContent = {
                        IconButton(onClick = { model.removeServer(s) }) { Icon(Icons.Outlined.Delete, stringResource(R.string.remove)) }
                    },
                )
            }
            add { ActionRow(Icons.Outlined.Dns, stringResource(R.string.add_server)) { nav.navigate(Routes.ADD_SERVER) } }
        }
        section(
            "servers", header = res.getString(R.string.servers_you_own), rows = serverRows,
            footer = { SectionFooter(res.getString(R.string.servers_footer)) },
        )

        section(
            "leave",
            rows = listOf<@Composable () -> Unit>({
                ListItem(
                    modifier = Modifier.clickable { confirmLeave = true },
                    colors = listItemColors(),
                    leadingContent = { Icon(Icons.AutoMirrored.Outlined.Logout, null, tint = Brand.negative) },
                    headlineContent = { Text(stringResource(R.string.remove_from_device), color = Brand.negative) },
                )
            }),
            footer = { SectionFooter(res.getString(R.string.keys_on_device)) },
        )
    }

    renaming?.let { RenameSheet(session, it) { renaming = null } }
    error?.let { ErrorDialog(stringResource(R.string.couldnt_create_invite), it) { error = null } }
    if (confirmLeave) {
        ConfirmDialog(
            title = stringResource(R.string.remove_group_title),
            message = stringResource(R.string.remove_group_message),
            confirm = stringResource(R.string.remove_from_device),
            onConfirm = { model.forget(session) },
            onDismiss = { confirmLeave = false },
        )
    }
}

@Composable
private fun MemberRow(ui: GroupUi, m: Member, invite: () -> Unit, rename: () -> Unit, addDevice: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val role = stringResource(if (m.isAdmin) R.string.admin else if (m.isClaimed) R.string.joined else R.string.invited_not_joined)
    val status = if (m.keys.size > 1) stringResource(R.string.role_devices, role, m.keys.size) else role
    val canRename = ui.isAdmin || m.id == ui.me
    ListItem(
        colors = listItemColors(),
        leadingContent = { MemberAvatar(m.initial, isMe = m.id == ui.me) },
        headlineContent = { OneLine(ui.name(m.id)) },
        supportingContent = { Text(status) },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (ui.isAdmin && !m.isClaimed) {
                    FilledTonalButton(onClick = invite) {
                        Icon(Icons.Outlined.QrCode2, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(stringResource(R.string.invite))
                    }
                }
                if (canRename || m.id == ui.me) {
                    Box {
                        IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, stringResource(R.string.more)) }
                        DropdownMenu(menu, onDismissRequest = { menu = false }) {
                            if (canRename) DropdownMenuItem(
                                text = { Text(stringResource(R.string.rename)) },
                                leadingIcon = { Icon(Icons.Outlined.Edit, null) },
                                onClick = {
                                    menu = false
                                    rename()
                                },
                            )
                            if (m.id == ui.me) DropdownMenuItem(
                                text = { Text(stringResource(R.string.add_device)) },
                                leadingIcon = { Icon(Icons.Outlined.QrCode2, null) },
                                onClick = {
                                    menu = false
                                    addDevice()
                                },
                            )
                        }
                    }
                }
            }
        },
    )
}

@Composable
private fun ActionRow(icon: ImageVector, text: String, onClick: () -> Unit) {
    ListItem(
        modifier = Modifier.clickable(onClick = onClick),
        colors = listItemColors(),
        leadingContent = { Icon(icon, null, tint = Brand.tint) },
        headlineContent = { Text(text, color = Brand.tint) },
    )
}

@Composable
private fun Info(label: String, value: String) {
    ListItem(colors = listItemColors(), headlineContent = { Text(label) }, trailingContent = { Text(value, style = MaterialTheme.typography.bodyLarge) })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RenameSheet(session: GroupSession, target: RenameTarget, onDismiss: () -> Unit) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val start = when (target) {
        is RenameTarget.Group -> target.name
        is RenameTarget.Member -> target.name
    }
    var name by remember { mutableStateOf(TextFieldValue(start, TextRange(0, start.length))) }
    val trimmed = name.text.trim().take(100)
    val focus = remember { FocusRequester() }
    fun save() {
        if (trimmed.isEmpty()) return
        when (target) {
            is RenameTarget.Group -> session.submit(EventData.GroupUpdated(GroupUpdatedData(trimmed)))
            is RenameTarget.Member -> session.submit(EventData.MemberUpdated(MemberUpdatedData(target.id, trimmed)))
        }
        onDismiss()
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(stringResource(if (target is RenameTarget.Group) R.string.rename_group else R.string.rename_member), style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text(stringResource(R.string.name)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { save() }),
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
                Spacer(Modifier.width(8.dp))
                Button(onClick = ::save, enabled = trimmed.isNotEmpty()) { Text(stringResource(R.string.save)) }
            }
        }
    }
    LaunchedEffect(Unit) { focus.requestFocus() }
}
