package io.github.hinkolas.openbalance.ui

import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavGraphBuilder
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.model.AppModel
import io.github.hinkolas.openbalance.sync.GroupSession
import io.github.hinkolas.openbalance.sync.AppLink
import io.github.hinkolas.openbalance.ui.group.AddMemberScreen
import io.github.hinkolas.openbalance.ui.group.CreationLinkScreen
import io.github.hinkolas.openbalance.ui.group.DeviceInviteScreen
import io.github.hinkolas.openbalance.ui.group.DevicesScreen
import io.github.hinkolas.openbalance.ui.group.InviteScreen
import io.github.hinkolas.openbalance.ui.group.RecoveryKitScreen
import io.github.hinkolas.openbalance.ui.payments.PaymentDetailScreen
import io.github.hinkolas.openbalance.ui.payments.PaymentFlowScreen
import io.github.hinkolas.openbalance.ui.shell.AppShell
import io.github.hinkolas.openbalance.ui.start.AddServerScreen
import io.github.hinkolas.openbalance.ui.start.CreateGroupScreen
import io.github.hinkolas.openbalance.ui.start.JoinScreen
import io.github.hinkolas.openbalance.ui.start.WelcomeScreen

val LocalAppModel = staticCompositionLocalOf<AppModel> { error("no AppModel") }
val LocalNav = staticCompositionLocalOf<NavHostController> { error("no NavController") }

object Routes {
    const val MAIN = "main"
    const val PAYMENT = "payment/{id}"
    const val PAYMENT_FORM = "paymentForm"
    const val JOIN = "join"
    const val CREATE_GROUP = "createGroup"
    const val ADD_SERVER = "addServer"
    const val ADD_MEMBER = "addMember"
    const val INVITE = "invite"
    const val DEVICE_INVITE = "deviceInvite"
    const val DEVICES = "devices"
    const val RECOVERY_KIT = "recoveryKit"
    const val CREATION_LINK = "creationLink"

    fun payment(id: String) = "payment/$id"
}

/**
 * Sections are tabs inside [Routes.MAIN]; a payment's detail is pushed;
 * self-contained tasks (new payment, join, create group, invites) are
 * full-screen routes that slide up, the Android counterpart of iOS sheets.
 */
@Composable
fun Root(model: AppModel) {
    val loaded by model.loaded.collectAsStateWithLifecycle()
    val active by model.active.collectAsStateWithLifecycle()
    val pendingLink by model.pendingLink.collectAsStateWithLifecycle()
    val toast by model.toast.collectAsStateWithLifecycle()
    val nav = rememberNavController()

    if (!loaded) {
        Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface))
        return
    }

    // Invites and recovery kits go to Join, creation links to Create; that screen takes the link.
    LaunchedEffect(pendingLink) {
        when (pendingLink) {
            is AppLink.Invite, is AppLink.Recovery -> nav.navigate(Routes.JOIN) { launchSingleTop = true }
            is AppLink.Creation -> nav.navigate(Routes.CREATE_GROUP) {
                popUpTo(Routes.MAIN)
                launchSingleTop = true
            }
            null -> {}
        }
    }

    CompositionLocalProvider(LocalAppModel provides model, LocalNav provides nav) {
        NavHost(nav, startDestination = Routes.MAIN) {
            composable(Routes.MAIN) {
                val session = active
                if (session != null) {
                    key(session.id) { AppShell(session) }
                } else {
                    WelcomeScreen()
                }
            }
            composable(Routes.PAYMENT) { entry ->
                WithSession(active, nav) { PaymentDetailScreen(it, entry.arguments?.getString("id") ?: "") }
            }
            modal(Routes.PAYMENT_FORM) { WithSession(active, nav) { PaymentFlowScreen(it) } }
            modal(Routes.JOIN) { JoinScreen() }
            modal(Routes.CREATE_GROUP) { CreateGroupScreen() }
            modal(Routes.ADD_SERVER) { AddServerScreen() }
            modal(Routes.ADD_MEMBER) { WithSession(active, nav) { AddMemberScreen(it) } }
            modal(Routes.INVITE) { WithSession(active, nav) { InviteScreen(it) } }
            modal(Routes.DEVICE_INVITE) { WithSession(active, nav) { DeviceInviteScreen(it) } }
            composable(Routes.DEVICES) { WithSession(active, nav) { DevicesScreen(it) } }
            modal(Routes.RECOVERY_KIT) { RecoveryKitScreen() }
            modal(Routes.CREATION_LINK) { CreationLinkScreen() }
        }
    }

    toast?.let { message ->
        AlertDialog(
            onDismissRequest = { model.toast.value = null },
            confirmButton = { TextButton({ model.toast.value = null }) { Text(stringResource(R.string.ok)) } },
            text = { Text(message) },
        )
    }
}

/** A task screen: slides up from the bottom and back down. */
private fun NavGraphBuilder.modal(route: String, content: @Composable (NavBackStackEntry) -> Unit) {
    val enter: AnimatedContentTransitionScope<NavBackStackEntry>.() -> EnterTransition = {
        slideInVertically(tween(300)) { it / 4 } + fadeIn(tween(300))
    }
    val exit: AnimatedContentTransitionScope<NavBackStackEntry>.() -> ExitTransition = {
        slideOutVertically(tween(250)) { it / 4 } + fadeOut(tween(250))
    }
    composable(route, enterTransition = enter, popExitTransition = exit, exitTransition = { fadeOut(tween(200)) }, popEnterTransition = { fadeIn(tween(200)) }) {
        content(it)
    }
}

/** Screens about the active group leave when there is none (e.g. it was removed). */
@Composable
private fun WithSession(session: GroupSession?, nav: NavHostController, content: @Composable (GroupSession) -> Unit) {
    if (session == null) {
        LaunchedEffect(Unit) { nav.popBackStack(Routes.MAIN, inclusive = false) }
        return
    }
    content(session)
}
