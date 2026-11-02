package io.github.hinkolas.openbalance.ui.history

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.List
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.FilterAlt
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.FilterAlt
import androidx.compose.material.icons.outlined.Group
import androidx.compose.material.icons.outlined.Groups
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Payments
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.PriorityHigh
import androidx.compose.material.icons.outlined.QrCode2
import androidx.compose.material.icons.outlined.QuestionMark
import androidx.compose.material.icons.outlined.Remove
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.core.EventData
import io.github.hinkolas.openbalance.core.HistoryItem
import io.github.hinkolas.openbalance.core.MemberId
import io.github.hinkolas.openbalance.core.Payment
import io.github.hinkolas.openbalance.core.PaymentId
import io.github.hinkolas.openbalance.design.Amount
import io.github.hinkolas.openbalance.design.AmountTone
import io.github.hinkolas.openbalance.design.Brand
import io.github.hinkolas.openbalance.design.EventIcon
import io.github.hinkolas.openbalance.design.EventSubject
import io.github.hinkolas.openbalance.design.ListHorizontalPadding
import io.github.hinkolas.openbalance.design.OneLine
import io.github.hinkolas.openbalance.design.sectionItems
import io.github.hinkolas.openbalance.model.Dates
import io.github.hinkolas.openbalance.model.GroupUi
import io.github.hinkolas.openbalance.model.label
import io.github.hinkolas.openbalance.model.reasonText
import io.github.hinkolas.openbalance.model.rememberGroupUi
import io.github.hinkolas.openbalance.sync.GroupSession
import io.github.hinkolas.openbalance.ui.LocalNav
import io.github.hinkolas.openbalance.ui.Routes
import io.github.hinkolas.openbalance.ui.overview.icon
import io.github.hinkolas.openbalance.ui.shell.TabScaffold
import io.github.hinkolas.openbalance.ui.shell.TitleWithSubtitle
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

/** What History shows. Overview's "Show all" opens it on [Payments]. */
enum class HistoryFilter(val label: Int, val icon: ImageVector, val empty: Int) {
    All(R.string.filter_all, Icons.AutoMirrored.Outlined.List, R.string.empty_all),
    Payments(R.string.filter_payments, Icons.Outlined.Payments, R.string.empty_payments),
    Arrivals(R.string.filter_arrivals, Icons.Outlined.CheckCircle, R.string.empty_arrivals),
    Members(R.string.filter_members, Icons.Outlined.Group, R.string.empty_members);

    fun includes(item: HistoryItem): Boolean = when (this) {
        All -> true
        Payments -> item.data is EventData.PaymentCreated || item.data is EventData.PaymentUpdated || item.data is EventData.PaymentDeleted
        Arrivals -> item.data is EventData.ArrivalRecorded || item.data is EventData.ArrivalRemoved
        Members -> when (item.data) {
            is EventData.GroupCreated, is EventData.GroupUpdated, is EventData.MemberAdded, is EventData.MemberInviteRenewed,
            is EventData.MemberClaimed, is EventData.MemberUpdated, is EventData.MemberDeviceInvited,
            is EventData.MemberDeviceClaimed, is EventData.MemberDeviceInviteRevoked -> true
            else -> false
        }
    }
}

/** What a history row shows; built from one ledger event. */
data class HistoryEntry(
    val subject: EventSubject,
    val badge: ImageVector? = null,
    val badgeColor: Color? = null,
    val title: String,
    val detail: String,
    val amount: Long? = null,
    val tone: AmountTone = AmountTone.Neutral,
    val payment: PaymentId? = null,
)

/**
 * The ledger itself, newest first. Events every client ignored stay visible,
 * marked with the reason, so everyone sees the same thing.
 */
@Composable
fun HistoryScreen(session: GroupSession, filter: HistoryFilter, setFilter: (HistoryFilter) -> Unit) {
    val ui = rememberGroupUi(session)
    val nav = LocalNav.current
    val context = LocalContext.current
    var query by rememberSaveable { mutableStateOf("") }
    var menu by remember { mutableStateOf(false) }
    val colors = HistoryColors(positive = Brand.positive, negative = Brand.negative, neutral = MaterialTheme.colorScheme.outline)
    val all = ui.state.history
    val entries = remember(ui, colors) { all.associate { it.eventId to entry(context, ui, it, colors) } }
    val q = query.trim()
    val shown = all.asReversed().filter { item ->
        filter.includes(item) && (q.isEmpty() || entries.getValue(item.eventId).let { e -> e.title.contains(q, ignoreCase = true) || e.detail.contains(q, ignoreCase = true) })
    }
    val days = shown.groupBy { item -> Dates.timestamp(item.at)?.let(Dates::localDay) }
    val dayOrder = days.keys.sortedWith(compareByDescending<LocalDate?> { it ?: LocalDate.MIN })

    TabScaffold(
        session,
        title = { TitleWithSubtitle(stringResource(R.string.tab_history), if (filter == HistoryFilter.All) null else stringResource(filter.label)) },
        actions = {
            IconButton(onClick = { menu = true }) {
                Icon(
                    if (filter == HistoryFilter.All) Icons.Outlined.FilterAlt else Icons.Filled.FilterAlt,
                    stringResource(R.string.filter),
                    tint = if (filter == HistoryFilter.All) MaterialTheme.colorScheme.onSurfaceVariant else Brand.tint,
                )
            }
            DropdownMenu(menu, onDismissRequest = { menu = false }) {
                for (f in HistoryFilter.entries) {
                    DropdownMenuItem(
                        text = { Text(stringResource(f.label)) },
                        leadingIcon = { Icon(f.icon, null) },
                        trailingIcon = { if (f == filter) Icon(Icons.Filled.Check, null) },
                        onClick = {
                            menu = false
                            setFilter(f)
                        },
                    )
                }
            }
        },
    ) {
        item(key = "search") {
            TextField(
                value = query,
                onValueChange = { query = it },
                placeholder = { Text(stringResource(R.string.search)) },
                leadingIcon = { Icon(Icons.Outlined.Search, null) },
                trailingIcon = {
                    if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Outlined.Close, stringResource(R.string.close)) }
                },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                shape = CircleShape,
                colors = TextFieldDefaults.colors(
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                ),
                modifier = Modifier.fillMaxWidth().padding(horizontal = ListHorizontalPadding, vertical = 4.dp),
            )
        }
        if (shown.isEmpty()) {
            item(key = "empty") {
                Empty(
                    title = when {
                        all.isEmpty() -> stringResource(R.string.empty_all)
                        q.isNotEmpty() -> stringResource(R.string.no_results, q)
                        else -> stringResource(filter.empty)
                    },
                    text = if (all.isEmpty()) stringResource(R.string.history_empty_text) else null,
                    icon = if (q.isNotEmpty()) Icons.Outlined.Search else filter.icon,
                )
            }
        }
        for (day in dayOrder) {
            val items = days.getValue(day)
            sectionItems("day-$day", items, { it.eventId }, header = dayTitle(context, day)) { item ->
                val entry = entries.getValue(item.eventId)
                val pid = entry.payment
                val open = pid != null && item.rejection == null && ui.state.payments[pid] != null
                HistoryRow(
                    entry,
                    time = Dates.timestamp(item.at)?.let(Dates::time) ?: "–",
                    rejection = item.rejection?.let(context::reasonText),
                    pending = item.pending,
                    ui = ui,
                    modifier = if (open) Modifier.clickable { nav.navigate(Routes.payment(pid!!)) } else Modifier,
                )
            }
        }
    }
}

@Composable
private fun Empty(title: String, text: String?, icon: ImageVector) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(40.dp))
        Text(title, style = MaterialTheme.typography.titleMedium)
        if (text != null) Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun dayTitle(context: Context, day: LocalDate?): String {
    if (day == null) return context.getString(R.string.unknown_date)
    val today = LocalDate.now()
    if (day == today) return context.getString(R.string.today)
    if (day == today.minusDays(1)) return context.getString(R.string.yesterday)
    val pattern = if (day.year == today.year) "EEEEdMMMM" else "EEEEdMMMMy"
    val skeleton = android.text.format.DateFormat.getBestDateTimePattern(Locale.getDefault(), pattern)
    return day.format(DateTimeFormatter.ofPattern(skeleton, Locale.getDefault()))
}

/** Colors resolved in composition, for building entries outside it. */
data class HistoryColors(val positive: Color, val negative: Color, val neutral: Color)

private fun entry(context: Context, ui: GroupUi, item: HistoryItem, c: HistoryColors): HistoryEntry {
    val by = ui.objectName(item.author)
    fun s(id: Int, vararg args: Any) = context.getString(id, *args)
    fun member(id: MemberId) = EventSubject.Initial(ui.initial(id))
    fun payment(id: PaymentId): Payment? = ui.state.payments[id]?.payment
    return when (val d = item.data) {
        is EventData.GroupCreated -> HistoryEntry(
            EventSubject.Symbol(Icons.Outlined.Groups), title = d.data.name,
            detail = s(R.string.group_created_by, if (item.author == ui.me) by else d.data.admin.name),
        )
        is EventData.GroupUpdated -> HistoryEntry(
            EventSubject.Symbol(Icons.Outlined.Groups), Icons.Outlined.Edit, c.neutral, d.data.name, s(R.string.group_renamed_by, by),
        )
        is EventData.MemberAdded -> HistoryEntry(member(d.data.id), title = ui.memberName(d.data.id), detail = s(R.string.added_by_x, by))
        is EventData.MemberInviteRenewed -> HistoryEntry(member(d.data.id), Icons.Outlined.QrCode2, c.neutral, ui.memberName(d.data.id), s(R.string.new_invite_from, by))
        is EventData.MemberClaimed -> HistoryEntry(member(d.data.id), Icons.Filled.Check, c.positive, ui.memberName(d.data.id), s(R.string.joined))
        is EventData.MemberUpdated -> HistoryEntry(member(d.data.id), Icons.Outlined.Edit, c.neutral, d.data.name, s(R.string.renamed_by, by))
        is EventData.MemberDeviceInvited -> HistoryEntry(member(d.data.id), Icons.Outlined.QrCode2, c.neutral, ui.memberName(d.data.id), s(R.string.qr_for_another_device))
        is EventData.MemberDeviceClaimed -> HistoryEntry(member(d.data.id), Icons.Outlined.PhoneAndroid, c.positive, ui.memberName(d.data.id), s(R.string.added_another_device))
        is EventData.MemberDeviceInviteRevoked -> HistoryEntry(member(d.data.id), Icons.Outlined.Close, c.negative, ui.memberName(d.data.id), s(R.string.device_qr_revoked_by, by))
        is EventData.PaymentCreated -> HistoryEntry(
            EventSubject.Symbol(d.payment.displayKind.icon), title = ui.title(d.payment),
            detail = s(R.string.kind_by, s(d.payment.displayKind.label), by), amount = d.payment.amount, payment = d.payment.id,
        )
        is EventData.PaymentUpdated -> HistoryEntry(
            EventSubject.Symbol(d.payment.displayKind.icon), Icons.Outlined.Edit, c.neutral, ui.title(d.payment),
            s(R.string.edited_by, by), amount = d.payment.amount, payment = d.payment.id,
        )
        is EventData.PaymentDeleted -> {
            val p = payment(d.data.id)
            HistoryEntry(
                EventSubject.Symbol(p?.displayKind?.icon ?: Icons.Outlined.Description), Icons.Outlined.Delete, c.negative,
                p?.let(ui::title) ?: s(R.string.a_payment), s(R.string.deleted_by, by), p?.amount, AmountTone.Pending, d.data.id,
            )
        }
        is EventData.ArrivalRecorded -> {
            val a = d.data
            val p = payment(a.payment)
            val at = if (a.member == ui.me) ui.objectName(a.member) else ui.memberName(a.member)
            val detail = if (item.author == a.member) s(R.string.arrived_at, at) else s(R.string.arrived_at_confirmed_by, at, by)
            HistoryEntry(
                EventSubject.Symbol(p?.displayKind?.icon ?: Icons.Outlined.Description), Icons.Filled.Check, c.positive,
                p?.let(ui::title) ?: s(R.string.a_payment), detail, a.amount, AmountTone.Positive, a.payment,
            )
        }
        is EventData.ArrivalRemoved -> {
            val arrival = ui.state.arrivals[d.data.id]
            val p = arrival?.let { payment(it.payment) }
            HistoryEntry(
                EventSubject.Symbol(p?.displayKind?.icon ?: Icons.Outlined.Description), Icons.Outlined.Remove, c.negative,
                p?.let(ui::title) ?: s(R.string.a_payment), s(R.string.arrival_removed_by, by), arrival?.amount, AmountTone.Pending, arrival?.payment,
            )
        }
        is EventData.Unsupported -> HistoryEntry(EventSubject.Symbol(Icons.Outlined.QuestionMark), title = s(R.string.unknown_event), detail = d.type)
        null -> HistoryEntry(EventSubject.Symbol(Icons.Outlined.Lock), title = s(R.string.unreadable_event), detail = s(R.string.unreadable_detail))
    }
}

/**
 * One ledger event: icon, what it is about, what happened and by whom, and
 * the amount and time on the trailing side. One line each so long titles
 * truncate instead of wrapping, more at large font sizes.
 */
@Composable
private fun HistoryRow(entry: HistoryEntry, time: String, rejection: String?, pending: Boolean, ui: GroupUi, modifier: Modifier = Modifier) {
    val ignored = rejection != null
    val lines = if (LocalDensity.current.fontScale >= 1.5f) 3 else 1
    Row(
        modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp).semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        EventIcon(
            entry.subject,
            badge = if (ignored) Icons.Outlined.PriorityHigh else entry.badge,
            badgeColor = if (ignored) Brand.negative else entry.badgeColor ?: Brand.tint,
            muted = ignored,
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OneLine(
                    entry.title,
                    style = MaterialTheme.typography.bodyLarge.copy(textDecoration = if (ignored) TextDecoration.LineThrough else null),
                    color = if (ignored) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
                    maxLines = lines,
                    modifier = Modifier.weight(1f),
                )
                entry.amount?.let { Amount(ui.money(it), tone = if (ignored) AmountTone.Pending else entry.tone) }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OneLine(
                    rejection?.let { stringResource(R.string.ignored_reason, it) } ?: entry.detail,
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (ignored) Brand.negative else MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = lines,
                    modifier = Modifier.weight(1f),
                )
                if (pending) {
                    Icon(Icons.Outlined.Sync, stringResource(R.string.not_synced_yet), tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
                } else {
                    Text(time, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                }
            }
        }
    }
}
