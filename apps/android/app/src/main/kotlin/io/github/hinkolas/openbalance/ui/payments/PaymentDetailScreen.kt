package io.github.hinkolas.openbalance.ui.payments

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.QuestionMark
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.core.ArrivalRecordedData
import io.github.hinkolas.openbalance.core.ArrivalRemovedData
import io.github.hinkolas.openbalance.core.Balances
import io.github.hinkolas.openbalance.core.EventData
import io.github.hinkolas.openbalance.core.MemberId
import io.github.hinkolas.openbalance.core.Money
import io.github.hinkolas.openbalance.core.Payment
import io.github.hinkolas.openbalance.core.PaymentDeletedData
import io.github.hinkolas.openbalance.core.PaymentId
import io.github.hinkolas.openbalance.core.PaymentRecord
import io.github.hinkolas.openbalance.core.Uuids
import io.github.hinkolas.openbalance.core.lower
import io.github.hinkolas.openbalance.design.Amount
import io.github.hinkolas.openbalance.design.AmountTone
import io.github.hinkolas.openbalance.design.AmountType
import io.github.hinkolas.openbalance.design.Brand
import io.github.hinkolas.openbalance.design.ListBottomPadding
import io.github.hinkolas.openbalance.design.MemberAvatar
import io.github.hinkolas.openbalance.design.OneLine
import io.github.hinkolas.openbalance.design.PlainBlock
import io.github.hinkolas.openbalance.design.SectionFooter
import io.github.hinkolas.openbalance.design.StatusBadge
import io.github.hinkolas.openbalance.design.section
import io.github.hinkolas.openbalance.design.sectionItems
import io.github.hinkolas.openbalance.model.Dates
import io.github.hinkolas.openbalance.model.GroupUi
import io.github.hinkolas.openbalance.model.PaymentDraft
import io.github.hinkolas.openbalance.model.label
import io.github.hinkolas.openbalance.model.rememberGroupUi
import io.github.hinkolas.openbalance.sync.GroupSession
import io.github.hinkolas.openbalance.ui.ConfirmDialog
import io.github.hinkolas.openbalance.ui.LocalAppModel
import io.github.hinkolas.openbalance.ui.LocalNav
import io.github.hinkolas.openbalance.ui.TaskScaffold
import io.github.hinkolas.openbalance.ui.overview.listItemColors
import io.github.hinkolas.openbalance.ui.shell.openPaymentForm

/** One payment: both sides, what has arrived, arrivals, edit and delete. */
@Composable
fun PaymentDetailScreen(session: GroupSession, paymentId: PaymentId) {
    val ui = rememberGroupUi(session)
    val nav = LocalNav.current
    val model = LocalAppModel.current
    val record = ui.state.payments[paymentId]
    var menu by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var arrivalFor by remember { mutableStateOf<ArrivalTarget?>(null) }

    TaskScaffold(
        title = record?.let { stringResource(it.payment.displayKind.label) } ?: "",
        onClose = { nav.popBackStack() },
        back = true,
        actions = {
            if (record != null && !record.deleted && ui.canEdit(record)) {
                Box {
                    IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, stringResource(R.string.more)) }
                    DropdownMenu(menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.edit)) },
                            leadingIcon = { Icon(Icons.Outlined.Edit, null) },
                            onClick = {
                                menu = false
                                openPaymentForm(model, nav, PaymentDraft.edit(record, ui.state))
                            },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.delete), color = Brand.negative) },
                            leadingIcon = { Icon(Icons.Outlined.Delete, null, tint = Brand.negative) },
                            onClick = {
                                menu = false
                                confirmDelete = true
                            },
                        )
                    }
                }
            }
        },
    ) { padding ->
        if (record == null) {
            Column(Modifier.fillMaxSize().padding(padding), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Icon(Icons.Outlined.QuestionMark, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(stringResource(R.string.payment_not_found), style = MaterialTheme.typography.titleMedium)
            }
        } else {
            Content(ui, record, padding) { arrivalFor = it }
        }
    }

    if (confirmDelete) {
        ConfirmDialog(
            title = stringResource(R.string.delete_payment_title),
            message = stringResource(R.string.delete_payment_message),
            confirm = stringResource(R.string.delete),
            onConfirm = {
                session.submit(EventData.PaymentDeleted(PaymentDeletedData(paymentId)))
                nav.popBackStack()
            },
            onDismiss = { confirmDelete = false },
        )
    }
    arrivalFor?.let { ArrivalSheet(ui, it) { arrivalFor = null } }
}

@Composable
private fun Content(ui: GroupUi, r: PaymentRecord, padding: androidx.compose.foundation.layout.PaddingValues, confirm: (ArrivalTarget) -> Unit) {
    val res = LocalResources.current
    val p = r.payment
    val arrivals = ui.state.arrivalsOf(p.id)
    val effect = Balances.effect(p, arrivals)
    val expense = p.displayKind == Payment.Kind.Expense
    LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = ListBottomPadding) {
        item(key = "hero") {
            PlainBlock {
                Column(Modifier.fillMaxWidth().padding(vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Amount(ui.money(p.amount), style = AmountType.hero)
                    Text(p.title, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
                    Text(Dates.display(p.date), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    when {
                        r.deleted -> StatusBadge(stringResource(R.string.deleted_badge), Brand.negative)
                        p.track && effect.arrived == p.amount -> StatusBadge(stringResource(R.string.arrived_badge), Brand.positive)
                        p.track -> StatusBadge(stringResource(R.string.x_of_y_arrived, ui.money(effect.arrived), ui.money(p.amount)))
                    }
                }
            }
        }
        p.note?.let { note ->
            section("note", header = res.getString(R.string.note), rows = listOf<@Composable () -> Unit>({
                Text(note, modifier = Modifier.padding(16.dp))
            }))
        }
        sectionItems(
            "in", p.inSide.lines, { it.member },
            header = res.getString(if (expense) R.string.for_side else R.string.received_by),
            footer = if (p.track && !r.deleted) ({ SectionFooter(res.getString(R.string.only_confirmed_counts)) }) else null,
        ) { line ->
            InRow(ui, p, line, held = effect.held[line.member] ?: 0, deleted = r.deleted, confirm = confirm)
        }
        sectionItems("out", p.outSide.lines, { it.member }, header = res.getString(if (expense) R.string.paid_by else R.string.belongs_to)) { line ->
            ListItem(
                colors = listItemColors(),
                leadingContent = { MemberAvatar(ui.initial(line.member), isMe = line.member == ui.me) },
                headlineContent = { OneLine(ui.name(line.member)) },
                trailingContent = { Amount(ui.money(line.amount)) },
            )
        }
        if (arrivals.isNotEmpty()) {
            sectionItems("arrivals", arrivals, { it.id }, header = res.getString(R.string.arrivals)) { a ->
                ListItem(
                    colors = listItemColors(),
                    headlineContent = { OneLine(ui.name(a.member)) },
                    supportingContent = { Text("${ui.name(a.author)} · ${Dates.timestamp(a.at)?.let(Dates::dateTime) ?: a.at}") },
                    trailingContent = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Amount(ui.money(a.amount))
                            if (a.author == ui.me || ui.isAdmin) {
                                IconButton(onClick = { ui.session.submit(EventData.ArrivalRemoved(ArrivalRemovedData(a.id))) }) {
                                    Icon(Icons.Outlined.Delete, stringResource(R.string.remove), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                        }
                    },
                )
            }
        }
        val info = buildList<@Composable () -> Unit> {
            add { ListItem(colors = listItemColors(), headlineContent = { Text(stringResource(R.string.added_by)) }, trailingContent = { Text(ui.name(r.creator)) }) }
            r.lastEditor?.let { editor ->
                add { ListItem(colors = listItemColors(), headlineContent = { Text(stringResource(R.string.last_edited_by)) }, trailingContent = { Text(ui.name(editor)) }) }
            }
        }
        section(
            "info", rows = info,
            footer = if (r.editedConcurrently) ({ SectionFooter(res.getString(R.string.edited_concurrently), Brand.negative) }) else null,
        )
    }
}

@Composable
private fun InRow(ui: GroupUi, p: Payment, line: Payment.Line, held: Long, deleted: Boolean, confirm: (ArrivalTarget) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            MemberAvatar(ui.initial(line.member), isMe = line.member == ui.me)
            OneLine(ui.name(line.member), modifier = Modifier.weight(1f))
            if (p.track) {
                Amount("${ui.money(held)} / ${ui.money(line.amount)}", tone = if (held == line.amount) AmountTone.Positive else AmountTone.Pending)
            } else {
                Amount(ui.money(line.amount))
            }
        }
        if (p.track && line.amount > 0) {
            LinearProgressIndicator(
                progress = { held.toFloat() / line.amount.toFloat() },
                modifier = Modifier.fillMaxWidth(),
                color = Brand.positive,
            )
            if (!deleted && held < line.amount && ui.canRecordArrival(line.member)) {
                OutlinedButton(onClick = { confirm(ArrivalTarget(p.id, line.member, line.amount - held)) }) {
                    Icon(Icons.Outlined.CheckCircle, null)
                    Spacer(Modifier.padding(start = 8.dp))
                    Text(if (line.member == ui.me) stringResource(R.string.confirm_what_arrived) else stringResource(R.string.confirm_for, ui.name(line.member)))
                }
            }
        }
    }
}

data class ArrivalTarget(val payment: PaymentId, val member: MemberId, val remaining: Long)

/** "How much arrived?" Defaults to everything still open. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ArrivalSheet(ui: GroupUi, target: ArrivalTarget, onDismiss: () -> Unit) {
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val start = Money.bare(target.remaining, ui.state.currency)
    var amount by remember { mutableStateOf(TextFieldValue(start, TextRange(0, start.length))) }
    val focus = remember { FocusRequester() }
    val parsed = Money.parse(amount.text, ui.state.currency)?.takeIf { it > 0 }
    fun save() {
        val v = parsed ?: return
        ui.session.submit(EventData.ArrivalRecorded(ArrivalRecordedData(Uuids.v7().lower, target.payment, target.member, v)))
        onDismiss()
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                if (target.member == ui.me) stringResource(R.string.what_arrived) else stringResource(R.string.arrived_at, ui.name(target.member)),
                style = MaterialTheme.typography.titleLarge,
            )
            AmountField(amount, { amount = it }, ui.currencySymbol, Modifier.focusRequester(focus), imeAction = ImeAction.Done, onDone = ::save)
            Text(
                stringResource(R.string.still_expected_footer, ui.money(target.remaining)),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
                Spacer(Modifier.padding(start = 8.dp))
                Button(onClick = ::save, enabled = parsed != null) { Text(stringResource(R.string.confirm)) }
            }
        }
    }
    LaunchedEffect(Unit) { focus.requestFocus() }
}

/** The big amount input: tabular figures, centered, the currency symbol after it. */
@Composable
fun AmountField(
    value: TextFieldValue,
    onChange: (TextFieldValue) -> Unit,
    symbol: String,
    modifier: Modifier = Modifier,
    imeAction: ImeAction = ImeAction.Next,
    onDone: () -> Unit = {},
) {
    val style = AmountType.input.copy(color = MaterialTheme.colorScheme.onSurface, textAlign = TextAlign.Center)
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        androidx.compose.foundation.text.BasicTextField(
            value = value,
            onValueChange = onChange,
            textStyle = style,
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = imeAction),
            keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { onDone() }, onNext = { onDone() }),
            cursorBrush = androidx.compose.ui.graphics.SolidColor(Brand.tint),
            modifier = modifier.width(androidx.compose.foundation.layout.IntrinsicSize.Min),
            decorationBox = { inner ->
                Box(contentAlignment = Alignment.Center) {
                    if (value.text.isEmpty()) Text("0", style = style.copy(color = MaterialTheme.colorScheme.outline))
                    inner()
                }
            },
        )
        Spacer(Modifier.padding(start = 6.dp))
        Text(symbol, style = AmountType.input.copy(fontSize = AmountType.input.fontSize * 0.55f), color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
