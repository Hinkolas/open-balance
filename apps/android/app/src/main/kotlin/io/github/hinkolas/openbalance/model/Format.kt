package io.github.hinkolas.openbalance.model

import android.content.Context
import android.content.res.Resources
import android.icu.text.ListFormatter
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.core.Balances
import io.github.hinkolas.openbalance.core.Inconsistency
import io.github.hinkolas.openbalance.core.LedgerState
import io.github.hinkolas.openbalance.core.MemberId
import io.github.hinkolas.openbalance.core.Money
import io.github.hinkolas.openbalance.core.Payment
import io.github.hinkolas.openbalance.core.PaymentRecord
import io.github.hinkolas.openbalance.core.Rejection
import io.github.hinkolas.openbalance.core.summary
import io.github.hinkolas.openbalance.sync.FlowError
import io.github.hinkolas.openbalance.sync.GroupSession
import io.github.hinkolas.openbalance.sync.ServerError
import java.io.IOException
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/**
 * One composition's view of a group: its state, who "you" are, and the
 * wording helpers every screen needs. Rebuilt whenever the state changes.
 */
class GroupUi(val session: GroupSession, val state: LedgerState, private val context: Context) {
    val me: MemberId = session.me
    val isAdmin: Boolean = state.adminId == me && !session.isRemoved(state, session.accessLost.value)
    val summary: Balances.Summary by lazy { state.summary() }

    fun money(minor: Long, signed: Boolean = false): String = Money.format(minor, state.currency, signed)

    fun bare(minor: Long): String = Money.bare(minor, state.currency)

    /** "You" for yourself, the member's name otherwise. */
    fun name(id: MemberId?): String = when {
        id == null -> context.getString(R.string.someone_cap)
        id == me -> context.getString(R.string.you_cap)
        else -> state.members[id]?.name ?: context.getString(R.string.unknown_member)
    }

    /** After "by", "from" or "at": "you" for yourself. */
    fun objectName(id: MemberId?): String = when {
        id == null -> context.getString(R.string.someone_object)
        id == me -> context.getString(R.string.you_object)
        else -> state.members[id]?.name ?: context.getString(R.string.someone_object)
    }

    fun memberName(id: MemberId): String = state.members[id]?.name ?: context.getString(R.string.unknown_member)

    fun initial(id: MemberId): String = state.members[id]?.initial ?: "?"

    fun canEdit(r: PaymentRecord): Boolean = r.creator == me || isAdmin

    /** §7.5: the receiver, the admin, or anyone for a seat nobody claimed yet. */
    fun canRecordArrival(member: MemberId): Boolean = member == me || isAdmin || state.members[member]?.isClaimed == false

    /** "Anna, Ben and you" in the user's language, after "by" or "at" (German "dir", not "Du"). */
    fun names(side: Payment.Side): String =
        ListFormatter.getInstance(Locale.getDefault()).format(side.lines.filter { it.amount > 0 }.map { objectName(it.member) })

    /** A settle up is about who paid whom; its title is "From → To". */
    fun title(p: Payment): String {
        if (p.displayKind != Payment.Kind.Settlement) return p.title
        val from = p.outSide.lines.firstOrNull { it.amount > 0 }?.member
        val to = p.inSide.lines.firstOrNull { it.amount > 0 }?.member
        return "${name(from)} → ${name(to)}"
    }

    val currencySymbol: String get() = Money.symbol(state.currency)

    fun string(id: Int, vararg args: Any): String = context.getString(id, *args)
}

@Composable
fun rememberGroupUi(session: GroupSession): GroupUi {
    val state by session.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val config = LocalConfiguration.current
    return remember(session, state, context, config) { GroupUi(session, state, context) }
}

/** Calendar dates ("2026-10-30") and event timestamps (RFC 3339). */
object Dates {
    fun parse(s: String): LocalDate? = runCatching { LocalDate.parse(s) }.getOrNull()

    fun string(d: LocalDate): String = d.toString()

    fun display(s: String): String = parse(s)?.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(Locale.getDefault())) ?: s

    fun timestamp(s: String?): Instant? = s?.let { runCatching { Instant.parse(it) }.getOrNull() }

    fun localDay(i: Instant): LocalDate = i.atZone(ZoneId.systemDefault()).toLocalDate()

    fun time(i: Instant): String = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(Locale.getDefault()).format(i.atZone(ZoneId.systemDefault()))

    fun dateTime(i: Instant): String =
        DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withLocale(Locale.getDefault()).format(i.atZone(ZoneId.systemDefault()))
}

/** What went wrong, in the user's language. Server messages come from the server. */
fun Resources.errorText(e: Throwable): String = when (e) {
    is FlowError -> getString(
        when (e.kind) {
            FlowError.Kind.NotAdmin -> R.string.error_not_admin
            FlowError.Kind.InviteUsed -> R.string.error_invite_used
            FlowError.Kind.SeatMissing -> R.string.error_seat_missing
            FlowError.Kind.SeatTaken -> R.string.error_seat_taken
            FlowError.Kind.UnsupportedServer -> R.string.error_unsupported_server
            FlowError.Kind.CreationCodeUsed -> R.string.error_creation_code_used
            FlowError.Kind.RecoveryReplaced -> R.string.error_recovery_replaced
            FlowError.Kind.NotRecoverable -> R.string.error_not_recoverable
        },
    )
    is ServerError -> getString(R.string.error_server, e.message, e.status)
    is IOException -> getString(R.string.error_network)
    else -> e.localizedMessage ?: e.toString()
}

fun Resources.inconsistencyText(i: Inconsistency): String = when (i) {
    is Inconsistency.Gap -> getString(R.string.inconsistency_gap, i.expected, i.got)
    is Inconsistency.Fork -> getString(R.string.inconsistency_fork, i.memberName ?: getString(R.string.a_member), i.seq)
    Inconsistency.BadGenesis -> getString(R.string.inconsistency_genesis)
}

fun Resources.reasonText(r: Rejection): String = getString(
    when (r) {
        Rejection.Decrypt -> R.string.reason_decrypt
        Rejection.Malformed -> R.string.reason_malformed
        Rejection.UnknownAuthor -> R.string.reason_unknown_author
        Rejection.BadSignature -> R.string.reason_bad_signature
        Rejection.Forbidden -> R.string.reason_forbidden
        Rejection.InvalidData -> R.string.reason_invalid_data
        Rejection.UnknownTarget -> R.string.reason_unknown_target
        Rejection.DuplicateId -> R.string.reason_duplicate
        Rejection.Misplaced -> R.string.reason_misplaced
        Rejection.AlreadyClaimed -> R.string.reason_already_claimed
        Rejection.BadInviteSig -> R.string.reason_bad_invite_sig
        Rejection.BadRecoverySig -> R.string.reason_bad_recovery_sig
    },
)

val Payment.Kind.label: Int
    get() = when (this) {
        Payment.Kind.Income -> R.string.kind_income
        Payment.Kind.Expense -> R.string.kind_expense
        Payment.Kind.Settlement -> R.string.kind_settle
    }
