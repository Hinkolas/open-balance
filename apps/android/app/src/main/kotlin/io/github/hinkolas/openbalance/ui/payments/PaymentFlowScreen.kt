package io.github.hinkolas.openbalance.ui.payments

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.SubdirectoryArrowRight
import androidx.compose.material.icons.outlined.CalendarToday
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconToggleButton
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.core.AmountTyping
import io.github.hinkolas.openbalance.core.EventData
import io.github.hinkolas.openbalance.core.MemberId
import io.github.hinkolas.openbalance.core.Money
import io.github.hinkolas.openbalance.core.Payment
import io.github.hinkolas.openbalance.core.SplitForm
import io.github.hinkolas.openbalance.design.Amount
import io.github.hinkolas.openbalance.design.AmountType
import io.github.hinkolas.openbalance.design.Brand
import io.github.hinkolas.openbalance.design.ListBottomPadding
import io.github.hinkolas.openbalance.design.ListHorizontalPadding
import io.github.hinkolas.openbalance.design.MemberAvatar
import io.github.hinkolas.openbalance.design.OneLine
import io.github.hinkolas.openbalance.design.PlainBlock
import io.github.hinkolas.openbalance.design.SectionFooter
import io.github.hinkolas.openbalance.design.SectionHeader
import io.github.hinkolas.openbalance.design.section
import io.github.hinkolas.openbalance.design.toneOf
import io.github.hinkolas.openbalance.model.Dates
import io.github.hinkolas.openbalance.model.GroupUi
import io.github.hinkolas.openbalance.model.PaymentDraft
import io.github.hinkolas.openbalance.model.label
import io.github.hinkolas.openbalance.model.rememberGroupUi
import io.github.hinkolas.openbalance.sync.GroupSession
import io.github.hinkolas.openbalance.ui.LocalAppModel
import io.github.hinkolas.openbalance.ui.LocalNav
import io.github.hinkolas.openbalance.ui.TaskAction
import io.github.hinkolas.openbalance.ui.TaskScaffold
import io.github.hinkolas.openbalance.ui.overview.listItemColors
import java.time.Instant
import java.time.ZoneOffset

private enum class Step { Amount, Received, Owned, Parties }

private enum class Side { Received, Owned }

/**
 * New or edited payment, one question per step:
 * amount & name → who gets the money → whom it belongs to (income),
 * amount & name → who paid → for whom (expense),
 * amount → who pays whom (settle up).
 */
@Composable
fun PaymentFlowScreen(session: GroupSession) {
    val model = LocalAppModel.current
    val nav = LocalNav.current
    val ui = rememberGroupUi(session)
    var draft by remember { mutableStateOf(model.handoff.draft?.also { model.handoff.draft = null } ?: PaymentDraft.new(Payment.Kind.Income, ui.state, ui.me)) }
    val steps = when (draft.kind) {
        Payment.Kind.Settlement -> listOf(Step.Amount, Step.Parties)
        Payment.Kind.Income -> listOf(Step.Amount, Step.Received, Step.Owned)
        Payment.Kind.Expense -> listOf(Step.Amount, Step.Owned, Step.Received)
    }
    var index by rememberSaveable { mutableStateOf(0) }
    val step = steps[index]
    val isLast = index == steps.lastIndex
    val settleTitle = stringResource(R.string.kind_settle)
    val built = draft.build(ui.state, ui.me, settleTitle)
    val focus = LocalFocusManager.current

    fun save() {
        val p = draft.build(ui.state, ui.me, settleTitle) ?: return
        session.submit(if (draft.existing == null) EventData.PaymentCreated(p) else EventData.PaymentUpdated(p))
        nav.popBackStack()
    }

    BackHandler(enabled = index > 0) { index-- }

    val canContinue = when (step) {
        Step.Amount -> draft.amountMinor(ui.state) != null && draft.hasTitle
        Step.Received -> draft.receivedResolution(ui.state, ui.me).amounts != null
        Step.Owned -> draft.ownedResolution(ui.state, ui.me).amounts != null
        Step.Parties -> built != null
    }
    TaskScaffold(
        title = when (step) {
            Step.Amount -> if (draft.existing == null) stringResource(draft.kind.label) else stringResource(R.string.edit_payment)
            Step.Parties -> stringResource(R.string.who_pays_whom)
            Step.Received -> stringResource(if (draft.kind == Payment.Kind.Expense) R.string.for_side else R.string.received_by)
            Step.Owned -> stringResource(if (draft.kind == Payment.Kind.Expense) R.string.paid_by else R.string.belongs_to)
        },
        onClose = { if (index > 0) index-- else nav.popBackStack() },
        back = index > 0,
        action = if (isLast) {
            TaskAction(stringResource(R.string.save), enabled = built != null) { save() }
        } else {
            TaskAction(stringResource(R.string.next), enabled = canContinue) {
                focus.clearFocus()
                index++
            }
        },
    ) { padding ->
        AnimatedContent(
            targetState = index,
            transitionSpec = {
                val forward = targetState > initialState
                (slideInHorizontally { if (forward) it / 3 else -it / 3 } + fadeIn()) togetherWith (slideOutHorizontally { if (forward) -it / 3 else it / 3 } + fadeOut())
            },
            label = "step",
        ) { i ->
            when (steps[i]) {
                Step.Amount -> AmountStep(ui, draft, padding) { draft = it }
                Step.Received -> SideStep(ui, draft, Side.Received, i == steps.lastIndex, padding, settleTitle) { draft = it }
                Step.Owned -> SideStep(ui, draft, Side.Owned, i == steps.lastIndex, padding, settleTitle) { draft = it }
                Step.Parties -> PartiesStep(ui, draft, padding, settleTitle) { draft = it }
            }
        }
    }
}

// MARK: - Step 1: amount and name

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AmountStep(ui: GroupUi, draft: PaymentDraft, padding: PaddingValues, update: (PaymentDraft) -> Unit) {
    val focus = remember { FocusRequester() }
    var amount by remember { mutableStateOf(TextFieldValue(draft.amount, TextRange(draft.amount.length))) }
    var pickingDate by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current
    LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = ListBottomPadding) {
        item(key = "amount") {
            PlainBlock(Modifier.padding(vertical = 16.dp)) {
                AmountField(
                    amount,
                    {
                        amount = it
                        update(draft.copy(amount = it.text))
                    },
                    ui.state.currency,
                    ui.currencySymbol,
                    Modifier.focusRequester(focus),
                    onDone = { focusManager.moveFocus(FocusDirection.Down) },
                )
                Text(
                    stringResource(
                        when (draft.kind) {
                            Payment.Kind.Income -> R.string.how_much_came_in
                            Payment.Kind.Expense -> R.string.how_much_paid
                            Payment.Kind.Settlement -> R.string.how_much_paid_back
                        },
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        item(key = "fields") {
            // A read-only field opens the date picker when tapped.
            val dateTaps = remember { MutableInteractionSource() }
            LaunchedEffect(dateTaps) {
                dateTaps.interactions.collect { if (it is PressInteraction.Release) pickingDate = true }
            }
            Column(Modifier.padding(horizontal = ListHorizontalPadding), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (draft.kind != Payment.Kind.Settlement) {
                    OutlinedTextField(
                        value = draft.title,
                        onValueChange = { update(draft.copy(title = it)) },
                        label = { Text(stringResource(if (draft.kind == Payment.Kind.Income) R.string.what_for_income else R.string.what_for_expense)) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Next),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                OutlinedTextField(
                    value = Dates.display(Dates.string(draft.date)),
                    onValueChange = {},
                    readOnly = true,
                    label = { Text(stringResource(R.string.date)) },
                    trailingIcon = { Icon(Icons.Outlined.CalendarToday, null) },
                    modifier = Modifier.fillMaxWidth(),
                    interactionSource = dateTaps,
                )
                OutlinedTextField(
                    value = draft.note,
                    onValueChange = { update(draft.copy(note = it)) },
                    label = { Text(stringResource(R.string.note)) },
                    minLines = 1,
                    maxLines = 4,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
    if (pickingDate) {
        val state = rememberDatePickerState(initialSelectedDateMillis = draft.date.atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli())
        DatePickerDialog(
            onDismissRequest = { pickingDate = false },
            confirmButton = {
                TextButton(onClick = {
                    state.selectedDateMillis?.let { update(draft.copy(date = Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate())) }
                    pickingDate = false
                }) { Text(stringResource(R.string.ok)) }
            },
            dismissButton = { TextButton(onClick = { pickingDate = false }) { Text(stringResource(R.string.cancel)) } },
        ) { DatePicker(state) }
    }
    LaunchedEffect(Unit) { if (draft.amount.isEmpty()) focus.requestFocus() }
}

// MARK: - Steps 2 and 3: one side

@Composable
private fun SideStep(ui: GroupUi, draft: PaymentDraft, side: Side, isLast: Boolean, padding: PaddingValues, settleTitle: String, update: (PaymentDraft) -> Unit) {
    val res = LocalResources.current
    val members = PaymentDraft.members(ui.state, ui.me)
    val currency = ui.state.currency
    val form = if (side == Side.Received) draft.received else draft.owned
    val resolution = if (side == Side.Received) draft.receivedResolution(ui.state, ui.me) else draft.ownedResolution(ui.state, ui.me)
    val expense = draft.kind == Payment.Kind.Expense
    fun setForm(f: SplitForm) = update(if (side == Side.Received) draft.copy(received = f) else draft.copy(owned = f))
    val focus = LocalFocusManager.current

    val status: Pair<String, Boolean>? = when {
        resolution.invalid.isNotEmpty() -> res.getString(R.string.use_amount_or_percent) to false
        resolution.usedFallback -> res.getString(
            when {
                expense && side == Side.Owned -> R.string.fallback_paid_all
                expense -> R.string.fallback_equal
                side == Side.Received -> R.string.fallback_all_to_you
                else -> R.string.fallback_same
            },
        ) to true
        resolution.amounts != null -> res.getString(R.string.adds_up) to true
        resolution.leftover > 0 -> res.getString(R.string.left_to_distribute, ui.money(resolution.leftover)) to false
        resolution.leftover < 0 -> res.getString(R.string.too_much, ui.money(-resolution.leftover)) to false
        else -> null
    }

    LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = ListBottomPadding) {
        item(key = "question") {
            PlainBlock {
                Text(
                    stringResource(
                        when {
                            expense && side == Side.Owned -> R.string.q_who_paid
                            expense -> R.string.q_for_whom
                            side == Side.Received -> R.string.q_who_gets
                            else -> R.string.q_belongs
                        },
                    ),
                    style = MaterialTheme.typography.headlineSmall,
                )
                Text(
                    stringResource(
                        when {
                            expense && side == Side.Owned -> R.string.explain_expense_paid
                            expense -> R.string.explain_expense_for
                            side == Side.Received -> R.string.explain_received
                            else -> R.string.explain_owned
                        },
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        item(key = "total") {
            SectionHeader(stringResource(R.string.total)) {
                Text(draft.amountMinor(ui.state)?.let { ui.money(it) } ?: "–", style = AmountType.caption.merge(MaterialTheme.typography.titleSmall), color = Brand.tint)
            }
        }
        val rows = buildList<@Composable () -> Unit> {
            members.forEachIndexed { i, m ->
                add {
                    MemberField(ui, m, form, resolution, currency, last = i == members.lastIndex, onChange = ::setForm) {
                        if (i == members.lastIndex) focus.clearFocus() else focus.moveFocus(FocusDirection.Down)
                    }
                }
            }
            add { RestMenu(ui, members) { m -> setForm(form.copy(text = form.text - m, rest = m)) } }
        }
        section("members", rows = rows, footer = status?.let { (text, ok) -> { SectionFooter(text, if (ok) Brand.positive else Brand.negative) } })
        if (isLast) draft.build(ui.state, ui.me, settleTitle)?.let { p -> result(ui, p) }
    }
}

@Composable
private fun MemberField(
    ui: GroupUi, m: MemberId, form: SplitForm, resolution: SplitForm.Resolution, currency: String, last: Boolean,
    onChange: (SplitForm) -> Unit, next: () -> Unit,
) {
    val field = form.field(m, currency)
    val preview = resolution.preview[m]
    val text = form.text[m] ?: ""
    val percentLabel = stringResource(R.string.percent)
    // Keeps the cursor while the text is regrouped; follows the form when it changes elsewhere (rest chosen).
    var edit by remember { mutableStateOf(TextFieldValue(text, TextRange(text.length))) }
    val shown = if (edit.text == text) edit else TextFieldValue(text, TextRange(text.length))
    val placeholder = if ((resolution.usedFallback || resolution.restMember == m) && preview != null && preview > 0) Money.bare(preview, currency) else "0"
    ListItem(
        colors = listItemColors(),
        leadingContent = { MemberAvatar(ui.initial(m), isMe = m == ui.me) },
        headlineContent = { OneLine(ui.name(m)) },
        supportingContent = when {
            resolution.restMember == m && ((preview ?: 0) > 0 || form.rest == m) -> ({ Text(stringResource(R.string.gets_the_rest)) })
            field is SplitForm.Field.Percent && preview != null -> ({ Text(stringResource(R.string.equals_amount, ui.money(preview)), style = AmountType.caption) })
            field == SplitForm.Field.Invalid -> ({ Text(stringResource(R.string.amount_or_percent), color = Brand.negative) })
            else -> null
        },
        trailingContent = {
            // The numeric pad has no "%", so a toggle in the field adds or removes it.
            val percent = shown.text.endsWith("%")
            fun commit(v: TextFieldValue) {
                edit = v
                val clearsRest = form.rest == m && v.text.isNotBlank()
                onChange(form.copy(text = form.text + (m to v.text), rest = if (clearsRest) null else form.rest))
            }
            OutlinedTextField(
                value = shown,
                onValueChange = { raw ->
                    // Amounts group as you type; a percentage keeps its "%" at the end.
                    val old = shown.text.removeSuffix("%")
                    val typed = raw.text.replace("%", "")
                    val cursor = raw.selection.start.coerceAtMost(typed.length)
                    val v = AmountTyping.next(old, typed, cursor, currency)
                        ?.let { TextFieldValue(it.text, TextRange(it.cursor)) } ?: TextFieldValue(typed, TextRange(cursor))
                    commit(if (percent) v.copy(text = v.text + "%") else v)
                },
                placeholder = { Text(placeholder, style = AmountType.row, textAlign = TextAlign.End, modifier = Modifier.fillMaxWidth()) },
                textStyle = AmountType.row.copy(textAlign = TextAlign.End),
                singleLine = true,
                isError = field == SplitForm.Field.Invalid,
                trailingIcon = {
                    IconToggleButton(
                        checked = percent,
                        onCheckedChange = { on ->
                            val base = shown.text.removeSuffix("%")
                            val text = if (on) "$base%" else base
                            commit(TextFieldValue(text, TextRange(base.length)))
                        },
                        modifier = Modifier.semantics { contentDescription = percentLabel },
                    ) {
                        Text("%", style = MaterialTheme.typography.titleMedium, color = if (percent) Brand.tint else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = if (last) ImeAction.Done else ImeAction.Next),
                keyboardActions = KeyboardActions(onNext = { next() }, onDone = { next() }),
                modifier = Modifier.widthIn(max = 180.dp),
            )
        },
    )
}

@Composable
private fun RestMenu(ui: GroupUi, members: List<MemberId>, pick: (MemberId) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        ListItem(
            modifier = Modifier.clickable { open = true },
            colors = listItemColors(),
            leadingContent = { Icon(Icons.Outlined.SubdirectoryArrowRight, null, tint = Brand.tint) },
            headlineContent = { Text(stringResource(R.string.give_rest_to), color = Brand.tint) },
        )
        DropdownMenu(open, onDismissRequest = { open = false }) {
            for (m in members) {
                DropdownMenuItem(text = { Text(ui.name(m)) }, onClick = {
                    open = false
                    pick(m)
                })
            }
        }
    }
}

// MARK: - Settle up: who pays whom

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PartiesStep(ui: GroupUi, draft: PaymentDraft, padding: PaddingValues, settleTitle: String, update: (PaymentDraft) -> Unit) {
    val members = PaymentDraft.members(ui.state, ui.me)
    val same = draft.settleFrom == draft.settleTo
    LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = ListBottomPadding) {
        item(key = "pickers") {
            Column(Modifier.padding(horizontal = ListHorizontalPadding, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                MemberPicker(ui, stringResource(R.string.from), draft.settleFrom, members) { update(draft.copy(settleFrom = it)) }
                MemberPicker(ui, stringResource(R.string.to), draft.settleTo, members) { update(draft.copy(settleTo = it)) }
            }
        }
        item(key = "pickers-footer") {
            SectionFooter(
                stringResource(if (same) R.string.pick_two else R.string.counts_once_confirmed),
                if (same) Brand.negative else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        draft.build(ui.state, ui.me, settleTitle)?.let { p -> result(ui, p) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MemberPicker(ui: GroupUi, label: String, selected: MemberId?, members: List<MemberId>, pick: (MemberId) -> Unit) {
    var open by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }) {
        OutlinedTextField(
            value = selected?.let(ui::name) ?: "",
            onValueChange = {},
            readOnly = true,
            label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(open) },
            modifier = Modifier.fillMaxWidth().menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            for (m in members) {
                DropdownMenuItem(text = { Text(ui.name(m)) }, onClick = {
                    open = false
                    pick(m)
                })
            }
        }
    }
}

// MARK: - Result

/** What the payment does to each balance once it has fully arrived. */
private fun androidx.compose.foundation.lazy.LazyListScope.result(ui: GroupUi, payment: Payment) {
    val net = LinkedHashMap<MemberId, Long>()
    for (l in payment.outSide.lines) net[l.member] = (net[l.member] ?: 0) + l.amount
    for (l in payment.inSide.lines) net[l.member] = (net[l.member] ?: 0) - l.amount
    val changed = PaymentDraft.members(ui.state, ui.me).filter { (net[it] ?: 0) != 0L }
    val rows = buildList<@Composable () -> Unit> {
        if (payment.displayKind == Payment.Kind.Income) add {
            ListItem(colors = listItemColors(), headlineContent = { Text(stringResource(R.string.yours)) }, trailingContent = { Amount(ui.money(payment.outSide.amountOf(ui.me))) })
        }
        if (changed.isEmpty()) add {
            ListItem(colors = listItemColors(), headlineContent = { Text(stringResource(R.string.nobody_owes), color = MaterialTheme.colorScheme.onSurfaceVariant) })
        }
        for (m in changed) add {
            val v = net[m] ?: 0
            ListItem(
                colors = listItemColors(),
                headlineContent = {
                    Text(
                        if (m == ui.me) {
                            stringResource(if (v > 0) R.string.you_get else R.string.you_pass_on)
                        } else {
                            stringResource(if (v > 0) R.string.member_gets else R.string.member_passes_on, ui.name(m))
                        },
                    )
                },
                trailingContent = { Amount(ui.money(v, signed = true), tone = toneOf(v)) },
            )
        }
    }
    item(key = "result-header") { SectionHeader(ui.string(R.string.result)) }
    rows.forEachIndexed { i, row -> item(key = "result-$i") { io.github.hinkolas.openbalance.design.GroupedRow(i, rows.size) { row() } } }
    if (payment.track) item(key = "result-footer") { SectionFooter(ui.string(R.string.counts_as_arrives)) }
}
