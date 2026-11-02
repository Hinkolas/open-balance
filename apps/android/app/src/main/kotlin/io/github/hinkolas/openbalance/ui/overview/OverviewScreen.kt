package io.github.hinkolas.openbalance.ui.overview

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.GppBad
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.Badge
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.design.Amount
import io.github.hinkolas.openbalance.design.AmountTone
import io.github.hinkolas.openbalance.design.AmountType
import io.github.hinkolas.openbalance.design.BalanceBar
import io.github.hinkolas.openbalance.design.Brand
import io.github.hinkolas.openbalance.design.MemberAvatar
import io.github.hinkolas.openbalance.design.OneLine
import io.github.hinkolas.openbalance.design.PlainBlock
import io.github.hinkolas.openbalance.design.SectionFooter
import io.github.hinkolas.openbalance.design.StatusBadge
import io.github.hinkolas.openbalance.design.section
import io.github.hinkolas.openbalance.design.sectionItems
import io.github.hinkolas.openbalance.design.toneOf
import io.github.hinkolas.openbalance.model.inconsistencyText
import io.github.hinkolas.openbalance.model.rememberGroupUi
import io.github.hinkolas.openbalance.sync.GroupSession
import io.github.hinkolas.openbalance.ui.LocalNav
import io.github.hinkolas.openbalance.ui.Routes
import io.github.hinkolas.openbalance.ui.payments.ArrivalSheet
import io.github.hinkolas.openbalance.ui.payments.ArrivalTarget
import io.github.hinkolas.openbalance.ui.shell.GroupSwitcherTitle
import io.github.hinkolas.openbalance.ui.shell.TabScaffold
import kotlin.math.abs

/** How many payments the overview lists before "Show all". */
private const val RECENT_LIMIT = 5

/**
 * The active group at a glance: your balance, money waiting to be
 * confirmed, everyone's balance line, recent payments. Who pays whom lives
 * in the Settle up tab.
 */
@Composable
fun OverviewScreen(session: GroupSession, showAllPayments: () -> Unit) {
    val ui = rememberGroupUi(session)
    val nav = LocalNav.current
    val res = LocalResources.current
    var arrivalFor by remember { mutableStateOf<ArrivalTarget?>(null) }
    val state = ui.state
    val summary = ui.summary
    val mine = summary.balances[ui.me] ?: 0
    val expected = summary.expected[ui.me] ?: mine
    val waiting = Waiting.items(state) { it == ui.me || state.members[it]?.isClaimed == false }
    val payments = state.livePayments.newestFirst()
    val scale = (summary.balances.values.map { abs(it) } + summary.expected.values.map { abs(it) }).maxOrNull() ?: 0

    TabScaffold(session, title = { GroupSwitcherTitle(ui) }) {
        item(key = "hero") {
            PlainBlock(Modifier.semantics(mergeDescendants = true) {}) {
                Text(stringResource(R.string.your_balance), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Amount(ui.money(mine, signed = true), tone = toneOf(mine), style = AmountType.hero)
                Text(
                    stringResource(if (mine > 0) R.string.owes_you else if (mine < 0) R.string.you_owe else R.string.settled_you),
                    style = MaterialTheme.typography.bodyMedium,
                )
                if (expected != mine) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Outlined.Schedule, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
                        Text(
                            stringResource(R.string.once_everything_arrives, ui.money(expected, signed = true)),
                            style = MaterialTheme.typography.bodyMedium.copy(fontFeatureSettings = "tnum"),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Spacer(Modifier.height(4.dp))
                SyncStatus(ui)
            }
        }

        state.inconsistency?.let { problem ->
            section("problem", rows = listOf<@Composable () -> Unit>({
                ListItem(
                    colors = listItemColors(),
                    leadingContent = { Icon(Icons.Outlined.GppBad, null, tint = Brand.negative) },
                    headlineContent = { Text(stringResource(R.string.history_unverifiable), style = MaterialTheme.typography.titleMedium) },
                    supportingContent = { Text(res.inconsistencyText(problem)) },
                )
            }))
        }

        if (waiting.isNotEmpty()) {
            sectionItems("waiting", waiting, { it.id }, header = res.getString(R.string.waiting_for_arrival)) { item ->
                WaitingRow(ui, item, onClick = { nav.navigate(Routes.payment(item.record.id)) }) {
                    FilledTonalIconButton(onClick = { arrivalFor = ArrivalTarget(item.record.id, item.line.member, item.open) }) {
                        Icon(Icons.Outlined.CheckCircle, stringResource(R.string.confirm_what_arrived))
                    }
                }
            }
        }

        sectionItems(
            "balances", state.orderedMembers, { it.id },
            header = res.getString(R.string.balances),
            footer = if (summary.expected != summary.balances) ({ SectionFooter(res.getString(R.string.faint_bar_footer)) }) else null,
        ) { m ->
            val b = summary.balances[m.id] ?: 0
            val e = summary.expected[m.id] ?: b
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp).semantics(mergeDescendants = true) {},
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                MemberAvatar(m.initial, isMe = m.id == ui.me)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OneLine(ui.name(m.id), modifier = Modifier.weight(1f, fill = false))
                            if (!m.isClaimed) StatusBadge(stringResource(R.string.invited_badge))
                        }
                        Amount(ui.money(b, signed = true), tone = toneOf(b, zero = AmountTone.Pending))
                    }
                    BalanceBar(b, e, scale)
                    if (e != b) {
                        Text(
                            stringResource(R.string.expected_amount, ui.money(e, signed = true)),
                            style = AmountType.caption,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.align(Alignment.End),
                        )
                    }
                }
            }
        }

        val recent = payments.take(RECENT_LIMIT)
        val rows = buildList<@Composable () -> Unit> {
            if (payments.isEmpty()) add {
                ListItem(colors = listItemColors(), headlineContent = { Text(stringResource(R.string.nothing_yet_tap_plus), color = MaterialTheme.colorScheme.onSurfaceVariant) })
            }
            for (r in recent) add { PaymentRow(ui, r) { nav.navigate(Routes.payment(r.id)) } }
            if (payments.size > RECENT_LIMIT) add {
                ListItem(
                    modifier = Modifier.clickable(onClick = showAllPayments),
                    colors = listItemColors(),
                    headlineContent = { Text(stringResource(R.string.show_all_in_history), color = Brand.tint) },
                    trailingContent = { Badge { Text(payments.size.toString()) } },
                )
            }
        }
        section("recent", header = res.getString(R.string.recent_payments), rows = rows)
    }

    arrivalFor?.let { target -> ArrivalSheet(ui, target) { arrivalFor = null } }
}
