package io.github.hinkolas.openbalance.design

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.core.view.WindowCompat

/*
 * Native Android with a light brand layer (docs/DESIGN.md): Material 3
 * components and type, one emerald tint matching the app icon, money set in
 * tabular figures, and the balance line. These are the only brand colors;
 * views take colors from MaterialTheme or [Brand].
 */

private val LightColors = lightColorScheme(
    primary = Color(0xFF087A4A),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFF9FF5C4),
    onPrimaryContainer = Color(0xFF002111),
    secondary = Color(0xFF4E6355),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFD0E8D6),
    onSecondaryContainer = Color(0xFF0B1F14),
    tertiary = Color(0xFF3B6470),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFBEEAF7),
    onTertiaryContainer = Color(0xFF001F27),
    error = Color(0xFFBA1A1A),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF410002),
    background = Color(0xFFF5FBF4),
    onBackground = Color(0xFF171D19),
    surface = Color(0xFFF5FBF4),
    onSurface = Color(0xFF171D19),
    surfaceVariant = Color(0xFFDCE5DC),
    onSurfaceVariant = Color(0xFF404942),
    outline = Color(0xFF707971),
    outlineVariant = Color(0xFFC0C9C0),
    surfaceTint = Color(0xFF087A4A),
    inverseSurface = Color(0xFF2C322E),
    inverseOnSurface = Color(0xFFEDF2EC),
    inversePrimary = Color(0xFF7ADAA3),
    surfaceDim = Color(0xFFD6DBD5),
    surfaceBright = Color(0xFFF5FBF4),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFEFF5EE),
    surfaceContainer = Color(0xFFE9EFE8),
    surfaceContainerHigh = Color(0xFFE4EAE3),
    surfaceContainerHighest = Color(0xFFDEE4DD),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFF3CCB82),
    onPrimary = Color(0xFF00391F),
    primaryContainer = Color(0xFF005231),
    onPrimaryContainer = Color(0xFF9FF5C4),
    secondary = Color(0xFFB5CCBA),
    onSecondary = Color(0xFF213528),
    secondaryContainer = Color(0xFF374B3E),
    onSecondaryContainer = Color(0xFFD0E8D6),
    tertiary = Color(0xFFA3CDDA),
    onTertiary = Color(0xFF033541),
    tertiaryContainer = Color(0xFF224C58),
    onTertiaryContainer = Color(0xFFBEEAF7),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    background = Color(0xFF0F1511),
    onBackground = Color(0xFFDEE4DD),
    surface = Color(0xFF0F1511),
    onSurface = Color(0xFFDEE4DD),
    surfaceVariant = Color(0xFF404942),
    onSurfaceVariant = Color(0xFFC0C9C0),
    outline = Color(0xFF8A938B),
    outlineVariant = Color(0xFF404942),
    surfaceTint = Color(0xFF3CCB82),
    inverseSurface = Color(0xFFDEE4DD),
    inverseOnSurface = Color(0xFF2C322E),
    inversePrimary = Color(0xFF087A4A),
    surfaceDim = Color(0xFF0F1511),
    surfaceBright = Color(0xFF353B36),
    surfaceContainerLowest = Color(0xFF0A0F0C),
    surfaceContainerLow = Color(0xFF171D19),
    surfaceContainer = Color(0xFF1B211D),
    surfaceContainerHigh = Color(0xFF252B27),
    surfaceContainerHighest = Color(0xFF303632),
)

@Composable
fun OpenBalanceTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val colors = if (dark) DarkColors else LightColors
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as? Activity)?.window ?: return@SideEffect
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !dark
            WindowCompat.getInsetsController(window, view).isAppearanceLightNavigationBars = !dark
        }
    }
    MaterialTheme(colorScheme = colors, content = content)
}

/** The brand roles of docs/DESIGN.md "Color". */
object Brand {
    /** Every interactive element and selection. */
    val tint: Color @Composable get() = MaterialTheme.colorScheme.primary

    /** Money owed to someone, arrived. The same green as the tint, so the app has one green. */
    val positive: Color @Composable get() = MaterialTheme.colorScheme.primary

    /** Money someone owes, too much. */
    val negative: Color @Composable get() = MaterialTheme.colorScheme.error

    /** Expected, not arrived yet. */
    val pending: Color @Composable get() = MaterialTheme.colorScheme.onSurfaceVariant

    val scheme: ColorScheme @Composable get() = MaterialTheme.colorScheme
}

/** Money is the one branded voice: tabular figures, so amounts line up. */
object AmountType {
    private fun TextStyle.money(weight: FontWeight) = copy(fontFeatureSettings = "tnum", fontWeight = weight)

    /** Your balance, a payment's amount. */
    val hero: TextStyle @Composable get() = MaterialTheme.typography.displaySmall.money(FontWeight.SemiBold)

    /** The amount being typed in a form. */
    val input: TextStyle @Composable get() = MaterialTheme.typography.displayMedium.money(FontWeight.SemiBold)

    /** Amounts in rows. */
    val row: TextStyle @Composable get() = MaterialTheme.typography.bodyLarge.money(FontWeight.Normal)

    val rowStrong: TextStyle @Composable get() = MaterialTheme.typography.bodyLarge.money(FontWeight.SemiBold)

    val caption: TextStyle @Composable get() = MaterialTheme.typography.bodySmall.money(FontWeight.Normal)
}
