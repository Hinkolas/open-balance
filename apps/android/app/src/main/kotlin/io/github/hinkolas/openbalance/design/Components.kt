package io.github.hinkolas.openbalance.design

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.abs
import kotlin.math.min

enum class AmountTone { Neutral, Positive, Negative, Pending }

@Composable
fun AmountTone.color(): Color = when (this) {
    AmountTone.Neutral -> MaterialTheme.colorScheme.onSurface
    AmountTone.Positive -> Brand.positive
    AmountTone.Negative -> Brand.negative
    AmountTone.Pending -> Brand.pending
}

/** Tone of a balance: green when owed, red when owing. */
fun toneOf(value: Long, zero: AmountTone = AmountTone.Neutral) = when {
    value > 0 -> AmountTone.Positive
    value < 0 -> AmountTone.Negative
    else -> zero
}

/** A formatted amount. Color follows tone; the text itself carries the sign. */
@Composable
fun Amount(text: String, modifier: Modifier = Modifier, tone: AmountTone = AmountTone.Neutral, style: TextStyle = AmountType.row) {
    Text(text, modifier = modifier, style = style, color = tone.color(), maxLines = 1, softWrap = false)
}

/** A size in dp that grows with the user's font size, like iOS's @ScaledMetric. */
@Composable
fun scaled(size: Dp): Dp = with(LocalDensity.current) { size.value.sp.toDp() }

/** A member's initial in a circle. Filled with the tint for you. */
@Composable
fun MemberAvatar(initial: String, isMe: Boolean = false, size: Dp = 36.dp) {
    val d = scaled(size)
    Box(
        Modifier
            .size(d)
            .clip(CircleShape)
            .background(if (isMe) Brand.tint else MaterialTheme.colorScheme.surfaceContainerHighest)
            .clearAndSetSemantics {},
        contentAlignment = Alignment.Center,
    ) {
        Text(
            initial,
            style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
            color = if (isMe) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface,
        )
    }
}

/**
 * The balance line: a bar diverging from a center axis, right and green for
 * money the group owes this member, left and red for money they owe. An
 * optional faint bar behind it marks where the member lands once expected
 * money has arrived.
 */
@Composable
fun BalanceBar(value: Long, expected: Long?, scale: Long, modifier: Modifier = Modifier) {
    val shown = expected?.takeIf { it != value }
    val max = maxOf(scale, 1L).toFloat()
    val track = MaterialTheme.colorScheme.surfaceContainerHighest
    val axis = MaterialTheme.colorScheme.outline
    val positive = Brand.positive
    val negative = Brand.negative
    Canvas(modifier.fillMaxWidth().height(14.dp).clearAndSetSemantics {}) {
        val half = size.width / 2
        val cy = size.height / 2
        drawRoundRect(track, Offset(0f, cy - 2.dp.toPx()), Size(size.width, 4.dp.toPx()), CornerRadius(2.dp.toPx()))
        fun bar(v: Long, alpha: Float) {
            val length = maxOf(3.dp.toPx(), half * min(1f, abs(v) / max))
            val h = 6.dp.toPx()
            val x = if (v > 0) half else half - length
            drawRoundRect((if (v > 0) positive else negative).copy(alpha = alpha), Offset(x, cy - h / 2), Size(length, h), CornerRadius(h / 2))
        }
        if (shown != null && shown != 0L) bar(shown, 0.3f)
        val w = 1.5.dp.toPx()
        drawRect(axis, Offset(half - w / 2, 0f), Size(w, size.height))
        if (value != 0L) bar(value, 1f)
    }
}

/** Small capsule for a state word: invited, expected, arrived, settled. */
@Composable
fun StatusBadge(text: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
    Text(
        text,
        style = MaterialTheme.typography.labelMedium,
        color = color,
        maxLines = 1,
        modifier = Modifier
            .clip(CircleShape)
            .background(color.copy(alpha = 0.14f))
            .padding(horizontal = 8.dp, vertical = 2.dp),
    )
}

sealed interface EventSubject {
    data class Symbol(val icon: ImageVector) : EventSubject
    data class Initial(val initial: String) : EventSubject
}

/**
 * The leading icon of a history row: what the entry is about (a payment
 * kind's icon or a member's initial, both grey) with a small badge for what
 * happened to it (added, edited, deleted, arrived …).
 */
@Composable
fun EventIcon(subject: EventSubject, badge: ImageVector? = null, badgeColor: Color = Brand.tint, muted: Boolean = false) {
    val size = scaled(40.dp)
    val ring = MaterialTheme.colorScheme.surfaceContainerLow
    Box(Modifier.size(size).clearAndSetSemantics {}) {
        Box(
            Modifier.size(size).clip(CircleShape).background(MaterialTheme.colorScheme.surfaceContainerHighest),
            contentAlignment = Alignment.Center,
        ) {
            val fg = MaterialTheme.colorScheme.onSurfaceVariant
            when (subject) {
                is EventSubject.Symbol -> Icon(subject.icon, null, tint = fg, modifier = Modifier.size(size * 0.55f).alpha(if (muted) 0.6f else 1f))
                is EventSubject.Initial -> Text(
                    subject.initial,
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                    color = if (muted) fg else MaterialTheme.colorScheme.onSurface,
                )
            }
        }
        if (badge != null) {
            val b = size * 0.48f
            Box(
                Modifier
                    .align(Alignment.BottomEnd)
                    .offset(size * 0.12f, size * 0.12f)
                    .size(b)
                    .border(2.dp, ring, CircleShape)
                    .padding(2.dp)
                    .clip(CircleShape)
                    .background(if (muted) MaterialTheme.colorScheme.outline else badgeColor),
                contentAlignment = Alignment.Center,
            ) {
                Icon(badge, null, tint = Color.White, modifier = Modifier.size(b * 0.62f))
            }
        }
    }
}

// MARK: - Grouped lists

/*
 * Lists are grouped sections like Android's Settings: a header in the tint,
 * rows in one rounded container, and an explanatory footer. Each row is its
 * own lazy item so long lists stay lazy.
 */

private val outer = 20.dp
private val inner = 4.dp

private fun shapeFor(index: Int, count: Int): Shape = when {
    count == 1 -> RoundedCornerShape(outer)
    index == 0 -> RoundedCornerShape(outer, outer, inner, inner)
    index == count - 1 -> RoundedCornerShape(inner, inner, outer, outer)
    else -> RoundedCornerShape(inner)
}

val ListHorizontalPadding = 16.dp

@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier, trailing: (@Composable () -> Unit)? = null) {
    Box(modifier.fillMaxWidth().padding(start = ListHorizontalPadding + 16.dp, end = ListHorizontalPadding + 16.dp, top = 20.dp, bottom = 8.dp)) {
        Text(text, style = MaterialTheme.typography.titleSmall, color = Brand.tint, modifier = Modifier.align(Alignment.CenterStart))
        if (trailing != null) Box(Modifier.align(Alignment.CenterEnd)) { trailing() }
    }
}

@Composable
fun SectionFooter(text: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = color,
        modifier = Modifier.fillMaxWidth().padding(start = ListHorizontalPadding + 16.dp, end = ListHorizontalPadding + 16.dp, top = 8.dp),
    )
}

/** One row of a grouped section: the container slice with the right corners. */
@Composable
fun GroupedRow(index: Int, count: Int, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Surface(
        shape = shapeFor(index, count),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = ListHorizontalPadding)
            .padding(top = if (index == 0) 0.dp else 2.dp),
    ) { content() }
}

/** A section of rows built from a list of row contents. */
fun LazyListScope.section(
    key: String,
    header: String? = null,
    footer: (@Composable () -> Unit)? = null,
    rows: List<@Composable () -> Unit>,
) {
    if (header != null) item(key = "$key-header") { SectionHeader(header) }
    rows.forEachIndexed { i, row -> item(key = "$key-$i") { GroupedRow(i, rows.size) { row() } } }
    if (footer != null) item(key = "$key-footer") { footer() }
}

/** A section with one row per item, keyed for stable animations. */
fun <T> LazyListScope.sectionItems(
    key: String,
    items: List<T>,
    itemKey: (T) -> Any,
    header: String? = null,
    footer: (@Composable () -> Unit)? = null,
    row: @Composable (T) -> Unit,
) {
    if (header != null) item(key = "$key-header") { SectionHeader(header) }
    items.forEachIndexed { i, t -> item(key = "$key-${itemKey(t)}") { GroupedRow(i, items.size) { row(t) } } }
    if (footer != null) item(key = "$key-footer") { footer() }
}

/** A card-free block above the sections (hero amounts, notices). */
@Composable
fun PlainBlock(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth().padding(horizontal = ListHorizontalPadding + 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp), content = content)
}

/** Space under the last section so the FAB never covers it. */
val ListBottomPadding = PaddingValues(bottom = 96.dp)

/** Single-line text that truncates instead of wrapping. */
@Composable
fun OneLine(text: String, modifier: Modifier = Modifier, style: TextStyle = MaterialTheme.typography.bodyLarge, color: Color = Color.Unspecified, maxLines: Int = 1) {
    Text(text, style = style, color = color, maxLines = maxLines, overflow = TextOverflow.Ellipsis, modifier = modifier)
}
