package io.github.hinkolas.openbalance.ui.settle

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.core.Balances
import io.github.hinkolas.openbalance.core.MemberId
import io.github.hinkolas.openbalance.core.Payment
import io.github.hinkolas.openbalance.design.Amount
import io.github.hinkolas.openbalance.design.AmountTone
import io.github.hinkolas.openbalance.design.AmountType
import io.github.hinkolas.openbalance.design.Brand
import io.github.hinkolas.openbalance.design.MemberAvatar
import io.github.hinkolas.openbalance.design.OneLine
import io.github.hinkolas.openbalance.design.SectionFooter
import io.github.hinkolas.openbalance.design.section
import io.github.hinkolas.openbalance.design.sectionItems
import io.github.hinkolas.openbalance.model.GroupUi
import io.github.hinkolas.openbalance.model.PaymentDraft
import io.github.hinkolas.openbalance.model.rememberGroupUi
import io.github.hinkolas.openbalance.sync.GroupSession
import io.github.hinkolas.openbalance.ui.LocalAppModel
import io.github.hinkolas.openbalance.ui.LocalNav
import io.github.hinkolas.openbalance.ui.Routes
import io.github.hinkolas.openbalance.ui.overview.TransferRow
import io.github.hinkolas.openbalance.ui.overview.Waiting
import io.github.hinkolas.openbalance.ui.overview.WaitingRow
import io.github.hinkolas.openbalance.ui.overview.listItemColors
import io.github.hinkolas.openbalance.ui.shell.TabScaffold
import io.github.hinkolas.openbalance.ui.shell.openPaymentForm

private enum class PlanGroup { Pay, Get, Others }

/**
 * The Settle up tab: one plan, who pays whom once everything has arrived
 * (PROTOCOL.md §9.4), and for each transfer how much of it can be paid today
 * (§9.5). Nobody pays money they don't owe yet, and no money moves one way
 * that a pending payment would send back.
 */
@Composable
fun SettleScreen(session: GroupSession) {
    val ui = rememberGroupUi(session)
    val model = LocalAppModel.current
    val nav = LocalNav.current
    val context = LocalContext.current
    val state = ui.state
    val summary = ui.summary
    val plan = summary.expectedTransfers
    val waiting = Waiting.items(state)
    val stillExpected = waiting.sumOf { it.open }
    val sent = settlementsOnTheWay(ui, waiting, from = true)
    val incoming = settlementsOnTheWay(ui, waiting, from = false)
    val youPay = rows(ui, plan.filter { it.from == ui.me }.map { it.to }, sent.keys)
    val youGet = rows(ui, plan.filter { it.to == ui.me }.map { it.from }, incoming.keys)
    val others = plan.filter { it.from != ui.me && it.to != ui.me }
    val waitsForMoney = summary.payNow != plan
    // The plan's closing note goes under whichever plan section comes last.
    val last = when {
        others.isNotEmpty() -> PlanGroup.Others
        youGet.isNotEmpty() -> PlanGroup.Get
        youPay.isNotEmpty() -> PlanGroup.Pay
        else -> null
    }
    val fewest = context.getString(R.string.fewest_transfers)
    fun footer(note: String?, isLast: Boolean): (@Composable () -> Unit)? {
        val text = listOfNotNull(note, fewest.takeIf { isLast }).joinToString("\n\n")
        return if (text.isEmpty()) null else ({ SectionFooter(text) })
    }

    TabScaffold(session, title = { Text(stringResource(R.string.tab_settle)) }) {
        if (waitsForMoney && stillExpected > 0) {
            section("notice", rows = listOf<@Composable () -> Unit>({
                ListItem(
                    modifier = Modifier.semantics(mergeDescendants = true) {},
                    colors = listItemColors(),
                    leadingContent = { Icon(Icons.Outlined.HourglassEmpty, null, tint = MaterialTheme.colorScheme.onSurfaceVariant) },
                    headlineContent = { Text(stringResource(R.string.planned_with_money), style = MaterialTheme.typography.titleMedium) },
                    supportingContent = { Text(stringResource(R.string.planned_includes, ui.money(stillExpected))) },
                )
            }))
        }
        if (plan.isEmpty() && sent.isEmpty() && incoming.isEmpty()) {
            section("settled", rows = listOf<@Composable () -> Unit>({
                ListItem(
                    colors = listItemColors(),
                    leadingContent = { Icon(Icons.Outlined.CheckCircle, null, tint = Brand.positive) },
                    headlineContent = {
                        Text(
                            stringResource(if (summary.transfers.isEmpty()) R.string.everyone_settled else R.string.everyone_settled_once),
                            color = Brand.positive,
                        )
                    },
                )
            }))
        }
        if (youPay.isNotEmpty()) {
            sectionItems("pay", youPay, { it }, header = context.getString(R.string.you_pay),
                footer = footer(context.getString(R.string.settling_records), last == PlanGroup.Pay)) { to ->
                val now = summary.payableNow(ui.me, to)
                PlanRow(ui, to, total = amount(plan, ui.me, to), now = now, onTheWay = sent[to] ?: 0, paying = true) {
                    openPaymentForm(model, nav, PaymentDraft.settle(Balances.Transfer(ui.me, to, now), state))
                }
            }
        }
        if (youGet.isNotEmpty()) {
            sectionItems("get", youGet, { it }, header = context.getString(R.string.you_receive),
                footer = footer(context.getString(R.string.confirm_under_still_expected), last == PlanGroup.Get)) { from ->
                PlanRow(ui, from, total = amount(plan, from, ui.me), now = summary.payableNow(from, ui.me), onTheWay = incoming[from] ?: 0, paying = false) {}
            }
        }
        if (others.isNotEmpty()) {
            sectionItems(
                "others", others, { "${it.from}-${it.to}" },
                header = context.getString(if (youPay.isEmpty() && youGet.isEmpty()) R.string.who_pays_whom else R.string.between_others),
                footer = footer(null, true),
            ) { t ->
                Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    TransferRow(ui, t, tone = AmountTone.Neutral)
                    Timing(ui, t.amount, summary.payableNow(t.from, t.to))
                }
            }
        }
        if (waiting.isNotEmpty()) {
            sectionItems("expected", waiting, { it.id }, header = context.getString(R.string.still_expected)) { item ->
                WaitingRow(ui, item, onClick = { nav.navigate(Routes.payment(item.record.id)) })
            }
        }
    }
}

/**
 * One person you pay or get money from: the planned amount, the settle
 * button for what you can pay now, and below it when the rest is due.
 */
@Composable
private fun PlanRow(ui: GroupUi, member: MemberId, total: Long, now: Long, onTheWay: Long, paying: Boolean, pay: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            MemberAvatar(ui.initial(member))
            Column(Modifier.weight(1f)) {
                OneLine(ui.name(member))
                Amount(
                    ui.money(if (total > 0) total else onTheWay),
                    tone = if (total == 0L) AmountTone.Pending else if (paying) AmountTone.Negative else AmountTone.Positive,
                    style = AmountType.rowStrong,
                )
            }
            if (paying && now > 0) {
                val label = stringResource(R.string.pay_amount_to, ui.money(now), ui.name(member))
                FilledTonalButton(onClick = pay, modifier = Modifier.semantics { contentDescription = label }) {
                    Text(stringResource(R.string.pay_amount, ui.money(now)), fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum"))
                }
            }
        }
        if (total > 0) Timing(ui, total, now)
        if (onTheWay > 0) {
            Caption(
                stringResource(if (paying) R.string.sent_waiting else R.string.on_the_way_to_you, ui.money(onTheWay)),
                Icons.AutoMirrored.Outlined.Send,
            )
        }
    }
}

/**
 * When a planned transfer can happen: nothing when all of it can be paid
 * today, otherwise what is due now and what waits for money on its way.
 */
@Composable
private fun Timing(ui: GroupUi, total: Long, now: Long) {
    when {
        now == 0L -> Caption(stringResource(R.string.once_money_on_way), Icons.Outlined.Schedule)
        now < total -> Caption(stringResource(R.string.now_and_later, ui.money(now), ui.money(total - now)), Icons.Outlined.Schedule)
    }
}

@Composable
private fun Caption(text: String, icon: ImageVector) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(14.dp))
        Text(text, style = MaterialTheme.typography.bodySmall.copy(fontFeatureSettings = "tnum"), color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun amount(plan: List<Balances.Transfer>, from: MemberId, to: MemberId): Long =
    plan.firstOrNull { it.from == from && it.to == to }?.amount ?: 0

/** Members from the plan in plan order, then anyone with a settlement on the way who is no longer in the plan. */
private fun rows(ui: GroupUi, planned: List<MemberId>, extra: Set<MemberId>): List<MemberId> =
    planned + ui.state.memberOrder.filter { it in extra && it !in planned }

/**
 * Settle-up payments not confirmed yet, per counterpart: yours to others
 * (`from = true`) or others' to you. They already count in the plan, so
 * the same debt isn't paid twice.
 */
private fun settlementsOnTheWay(ui: GroupUi, waiting: List<Waiting>, from: Boolean): Map<MemberId, Long> {
    val out = LinkedHashMap<MemberId, Long>()
    for (item in waiting) {
        if (item.record.payment.displayKind != Payment.Kind.Settlement) continue
        val payer = item.record.payment.outSide.lines.firstOrNull { it.amount > 0 }?.member
        if (from && payer == ui.me) {
            out[item.line.member] = (out[item.line.member] ?: 0) + item.open
        } else if (!from && item.line.member == ui.me && payer != null) {
            out[payer] = (out[payer] ?: 0) + item.open
        }
    }
    return out
}
