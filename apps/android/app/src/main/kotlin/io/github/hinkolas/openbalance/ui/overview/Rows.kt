package io.github.hinkolas.openbalance.ui.overview

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material.icons.outlined.ArrowCircleUp
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.core.Balances
import io.github.hinkolas.openbalance.core.LedgerState
import io.github.hinkolas.openbalance.core.MemberId
import io.github.hinkolas.openbalance.core.Payment
import io.github.hinkolas.openbalance.core.PaymentRecord
import io.github.hinkolas.openbalance.design.Amount
import io.github.hinkolas.openbalance.design.AmountTone
import io.github.hinkolas.openbalance.design.AmountType
import io.github.hinkolas.openbalance.design.OneLine
import io.github.hinkolas.openbalance.model.Dates
import io.github.hinkolas.openbalance.model.GroupUi

val Payment.Kind.icon: ImageVector
    get() = when (this) {
        Payment.Kind.Income -> Icons.Outlined.ArrowCircleDown
        Payment.Kind.Expense -> Icons.Outlined.ArrowCircleUp
        Payment.Kind.Settlement -> Icons.Outlined.SwapHoriz
    }

/** By payment date, then by when they were added; newest first. */
fun List<PaymentRecord>.newestFirst(): List<PaymentRecord> =
    sortedWith(compareByDescending<PaymentRecord> { it.payment.date }.thenByDescending { it.createdAt })

/** Money still expected to arrive at one receiver for one payment. */
data class Waiting(val record: PaymentRecord, val line: Payment.Line, val open: Long) {
    val id: String get() = record.id + line.member

    companion object {
        fun items(state: LedgerState, include: (MemberId) -> Boolean = { true }): List<Waiting> =
            state.livePayments.filter { it.payment.track }.flatMap { r ->
                val effect = Balances.effect(r.payment, state.arrivalsOf(r.id))
                r.payment.inSide.lines.mapNotNull { line ->
                    val open = line.amount - (effect.held[line.member] ?: 0)
                    if (open > 0 && include(line.member)) Waiting(r, line, open) else null
                }
            }
    }
}

private val clear = Color.Transparent

@Composable
fun listItemColors() = ListItemDefaults.colors(containerColor = clear)

/** A payment in a list: kind, title, date and who, amount and what has arrived. */
@Composable
fun PaymentRow(ui: GroupUi, record: PaymentRecord, onClick: () -> Unit) {
    val p = record.payment
    val effect = Balances.effect(p, ui.state.arrivalsOf(p.id))
    val date = Dates.display(p.date)
    val subtitle = when (p.displayKind) {
        Payment.Kind.Income -> stringResource(R.string.payment_subtitle_income, date, ui.names(p.inSide))
        Payment.Kind.Expense -> stringResource(R.string.payment_subtitle_expense, date, ui.names(p.outSide))
        Payment.Kind.Settlement -> date
    }
    ListItem(
        modifier = Modifier.clickable(onClick = onClick),
        colors = listItemColors(),
        leadingContent = { Icon(p.displayKind.icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant) },
        headlineContent = { OneLine(ui.title(p)) },
        supportingContent = { OneLine(subtitle, style = MaterialTheme.typography.bodyMedium) },
        trailingContent = {
            Column(horizontalAlignment = Alignment.End) {
                Amount(ui.money(p.amount))
                if (p.track && effect.arrived < p.amount) {
                    Text(
                        if (effect.arrived == 0L) stringResource(R.string.expected_lower) else stringResource(R.string.amount_arrived, ui.money(effect.arrived)),
                        style = AmountType.caption,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        },
    )
}

/** Money still expected for one payment at one receiver. */
@Composable
fun WaitingRow(ui: GroupUi, item: Waiting, onClick: () -> Unit, trailingAction: (@Composable () -> Unit)? = null) {
    ListItem(
        modifier = Modifier.clickable(onClick = onClick),
        colors = listItemColors(),
        headlineContent = { OneLine(item.record.payment.title) },
        supportingContent = {
            Text(if (item.line.member == ui.me) stringResource(R.string.to_you) else stringResource(R.string.to_member, ui.name(item.line.member)))
        },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Amount(ui.money(item.open), tone = AmountTone.Pending)
                if (trailingAction != null) {
                    Spacer(Modifier.width(4.dp))
                    trailingAction()
                }
            }
        },
    )
}

/** "You → Acme   1.234,56 €". Red when you pay, green when you receive. */
@Composable
fun TransferRow(ui: GroupUi, t: Balances.Transfer, tone: AmountTone? = null) {
    val pays = stringResource(R.string.pays)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            OneLine(ui.name(t.from), style = MaterialTheme.typography.bodyLarge.copy(fontWeight = if (t.from == ui.me) FontWeight.SemiBold else FontWeight.Normal), modifier = Modifier.weight(1f, fill = false))
            Icon(
                Icons.AutoMirrored.Outlined.ArrowForward, null,
                tint = MaterialTheme.colorScheme.outline,
                modifier = Modifier.size(16.dp).semantics { contentDescription = pays },
            )
            OneLine(ui.name(t.to), style = MaterialTheme.typography.bodyLarge.copy(fontWeight = if (t.to == ui.me) FontWeight.SemiBold else FontWeight.Normal), modifier = Modifier.weight(1f, fill = false))
        }
        Amount(
            ui.money(t.amount),
            tone = tone ?: when (ui.me) {
                t.from -> AmountTone.Negative
                t.to -> AmountTone.Positive
                else -> AmountTone.Neutral
            },
        )
    }
}

/** "Syncing…" / "Offline" under the balance, only when it matters. */
@Composable
fun SyncStatus(ui: GroupUi) {
    val pending by ui.session.pendingCount.collectAsStateWithLifecycle()
    val error by ui.session.lastError.collectAsStateWithLifecycle()
    val (icon, text) = when {
        error != null -> Icons.Outlined.CloudOff to if (pending > 0) pluralStringResource(R.plurals.offline_waiting, pending, pending) else stringResource(R.string.offline)
        pending > 0 -> Icons.Outlined.Sync to pluralStringResource(R.plurals.syncing_changes, pending, pending)
        else -> return
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
        Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
