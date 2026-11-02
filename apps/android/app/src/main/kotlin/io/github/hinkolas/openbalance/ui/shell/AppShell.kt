package io.github.hinkolas.openbalance.ui.shell

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material.icons.outlined.ArrowCircleUp
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.Group
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.core.Payment
import io.github.hinkolas.openbalance.design.ListBottomPadding
import io.github.hinkolas.openbalance.model.GroupUi
import io.github.hinkolas.openbalance.model.PaymentDraft
import io.github.hinkolas.openbalance.model.label
import io.github.hinkolas.openbalance.model.rememberGroupUi
import io.github.hinkolas.openbalance.sync.GroupSession
import io.github.hinkolas.openbalance.ui.LocalAppModel
import io.github.hinkolas.openbalance.ui.LocalNav
import io.github.hinkolas.openbalance.ui.Routes
import io.github.hinkolas.openbalance.ui.group.GroupScreen
import io.github.hinkolas.openbalance.ui.history.HistoryFilter
import io.github.hinkolas.openbalance.ui.history.HistoryScreen
import io.github.hinkolas.openbalance.ui.overview.OverviewScreen
import io.github.hinkolas.openbalance.ui.settle.SettleScreen
import kotlinx.coroutines.launch

enum class AppTab(val label: Int, val icon: ImageVector, val selectedIcon: ImageVector) {
    Overview(R.string.tab_overview, Icons.Outlined.BarChart, Icons.Filled.BarChart),
    Settle(R.string.tab_settle, Icons.Outlined.SwapHoriz, Icons.Filled.SwapHoriz),
    History(R.string.tab_history, Icons.Outlined.History, Icons.Filled.History),
    Group(R.string.tab_group, Icons.Outlined.Group, Icons.Filled.Group),
}

/**
 * Four sections as tabs in the navigation bar. Adding a payment is an action,
 * so it is a floating button on the sections where it fits, never a tab.
 */
@Composable
fun AppShell(session: GroupSession) {
    var tab by rememberSaveable { mutableStateOf(AppTab.Overview) }
    var historyFilter by rememberSaveable { mutableStateOf(HistoryFilter.All) }
    Scaffold(
        contentWindowInsets = WindowInsets(0),
        bottomBar = {
            NavigationBar {
                for (t in AppTab.entries) {
                    NavigationBarItem(
                        selected = tab == t,
                        onClick = { tab = t },
                        icon = { Icon(if (tab == t) t.selectedIcon else t.icon, null) },
                        label = { Text(stringResource(t.label)) },
                    )
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(bottom = padding.calculateBottomPadding()).consumeWindowInsets(WindowInsets.navigationBars)) {
            when (tab) {
                AppTab.Overview -> OverviewScreen(session, showAllPayments = {
                    historyFilter = HistoryFilter.Payments
                    tab = AppTab.History
                })
                AppTab.Settle -> SettleScreen(session)
                AppTab.History -> HistoryScreen(session, historyFilter) { historyFilter = it }
                AppTab.Group -> GroupScreen(session)
            }
        }
    }
}

/**
 * A section's frame: a large top app bar that collapses on scroll, pull to
 * refresh, and optionally the + button.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TabScaffold(
    session: GroupSession,
    title: @Composable () -> Unit,
    addButton: Boolean = true,
    actions: @Composable () -> Unit = {},
    listState: LazyListState = rememberLazyListState(),
    content: LazyListScope.() -> Unit,
) {
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    Scaffold(
        topBar = {
            LargeTopAppBar(title = title, actions = { actions() }, scrollBehavior = scroll)
        },
        floatingActionButton = { if (addButton) AddPaymentButton(session) },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = {
                refreshing = true
                scope.launch {
                    try {
                        session.syncNow()
                    } catch (_: Exception) {
                    } finally {
                        refreshing = false
                    }
                }
            },
            modifier = Modifier.padding(padding),
        ) {
            // The app bar sees the scroll before pull to refresh does, so scrolling
            // back to the top expands it again instead of starting a refresh.
            LazyColumn(
                Modifier.fillMaxSize().nestedScroll(scroll.nestedScrollConnection),
                state = listState,
                contentPadding = ListBottomPadding,
                content = content,
            )
        }
    }
}

/** The + button: a menu with the three kinds of payment. */
@Composable
fun AddPaymentButton(session: GroupSession) {
    val model = LocalAppModel.current
    val nav = LocalNav.current
    val state by session.state.collectAsStateWithLifecycle()
    var open by remember { mutableStateOf(false) }
    Box {
        FloatingActionButton(onClick = { open = true }) {
            Icon(Icons.Outlined.Add, stringResource(R.string.add_payment))
        }
        DropdownMenu(open, onDismissRequest = { open = false }) {
            for ((kind, icon) in listOf(
                Payment.Kind.Income to Icons.Outlined.ArrowCircleDown,
                Payment.Kind.Expense to Icons.Outlined.ArrowCircleUp,
                Payment.Kind.Settlement to Icons.Outlined.SwapHoriz,
            )) {
                DropdownMenuItem(
                    text = { Text(stringResource(kind.label)) },
                    leadingIcon = { Icon(icon, null) },
                    onClick = {
                        open = false
                        model.handoff.draft = PaymentDraft.new(kind, state, session.me)
                        nav.navigate(Routes.PAYMENT_FORM)
                    },
                )
            }
        }
    }
}

/** Open the payment form with a prepared draft (edit, settle a transfer). */
fun openPaymentForm(model: io.github.hinkolas.openbalance.model.AppModel, nav: androidx.navigation.NavController, draft: PaymentDraft) {
    model.handoff.draft = draft
    nav.navigate(Routes.PAYMENT_FORM)
}

/** The Overview title: the group's name, tapping it switches group, joins or creates one. */
@Composable
fun GroupSwitcherTitle(ui: GroupUi) {
    val model = LocalAppModel.current
    val nav = LocalNav.current
    val sessions by model.sessions.collectAsStateWithLifecycle()
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.clickable(onClickLabel = stringResource(R.string.switch_group)) { open = true },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(ui.state.name, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            Icon(Icons.Filled.ArrowDropDown, null)
        }
        DropdownMenu(open, onDismissRequest = { open = false }) {
            for (s in sessions) {
                val name by s.state.collectAsStateWithLifecycle()
                DropdownMenuItem(
                    text = { Text(name.name) },
                    leadingIcon = { if (s.id == ui.session.id) Icon(Icons.Filled.Check, null) else Spacer(Modifier.width(24.dp)) },
                    onClick = {
                        open = false
                        model.activate(s.id)
                    },
                )
            }
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text(stringResource(R.string.join_with_invite)) },
                leadingIcon = { Icon(Icons.Outlined.QrCodeScanner, null) },
                onClick = {
                    open = false
                    nav.navigate(Routes.JOIN)
                },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.create_group)) },
                leadingIcon = { Icon(Icons.Outlined.Add, null) },
                onClick = {
                    open = false
                    nav.navigate(Routes.CREATE_GROUP)
                },
            )
        }
    }
}

/** Title with an optional second line (History's active filter). */
@Composable
fun TitleWithSubtitle(title: String, subtitle: String?) {
    Column {
        Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (subtitle != null) Text(subtitle, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
    }
}

/** Shared by tabs that only need the + button's session state. */
@Composable
fun rememberUi(session: GroupSession): GroupUi = rememberGroupUi(session)

internal val NoPadding = PaddingValues()
