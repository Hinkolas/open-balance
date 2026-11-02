package io.github.hinkolas.openbalance.ui.start

import android.Manifest
import android.content.ClipboardManager
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.hinkolas.openbalance.R
import io.github.hinkolas.openbalance.design.Brand
import io.github.hinkolas.openbalance.design.ListHorizontalPadding
import io.github.hinkolas.openbalance.design.SectionFooter
import io.github.hinkolas.openbalance.design.SectionHeader
import io.github.hinkolas.openbalance.design.scaled
import io.github.hinkolas.openbalance.model.errorText
import io.github.hinkolas.openbalance.sync.InviteLink
import io.github.hinkolas.openbalance.ui.LocalAppModel
import io.github.hinkolas.openbalance.ui.LocalNav
import io.github.hinkolas.openbalance.ui.Routes
import io.github.hinkolas.openbalance.ui.TaskAction
import io.github.hinkolas.openbalance.ui.TaskScaffold
import io.github.hinkolas.openbalance.ui.qr.QrScanner
import kotlinx.coroutines.launch
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.util.Locale

/**
 * First screen without any group: join with an invite, or create a group on
 * a server you own.
 */
@Composable
fun WelcomeScreen() {
    val nav = LocalNav.current
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
        Column(
            Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.weight(1f))
            Column(Modifier.widthIn(max = 420.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Image(painterResource(R.drawable.app_mark), null, Modifier.size(scaled(96.dp)))
                Text(stringResource(R.string.app_name), style = MaterialTheme.typography.headlineLarge)
                Text(
                    stringResource(R.string.welcome_text),
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
            }
            Spacer(Modifier.weight(1f))
            Column(Modifier.widthIn(max = 420.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = { nav.navigate(Routes.JOIN) }, modifier = Modifier.fillMaxWidth().height(56.dp)) {
                    Icon(Icons.Outlined.QrCodeScanner, null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.join_with_invite))
                }
                FilledTonalButton(onClick = { nav.navigate(Routes.CREATE_GROUP) }, modifier = Modifier.fillMaxWidth().height(56.dp)) {
                    Text(stringResource(R.string.create_group))
                }
                Text(
                    stringResource(R.string.welcome_join_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                )
            }
        }
    }
}

/** Join a group with an invite: scan the QR code or paste the link. */
@Composable
fun JoinScreen() {
    val model = LocalAppModel.current
    val nav = LocalNav.current
    val context = LocalContext.current
    val res = LocalResources.current
    val scope = rememberCoroutineScope()
    val pending by model.pendingInvite.collectAsStateWithLifecycle()
    var link by remember { mutableStateOf<InviteLink?>(null) }
    var pasted by rememberSaveable { mutableStateOf("") }
    var joining by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var cameraAllowed by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    val askCamera = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { cameraAllowed = it }
    val hasCamera = context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)

    // A link opened from outside the app fills in the invite.
    LaunchedEffect(pending) {
        pending?.let {
            link = it
            model.pendingInvite.value = null
        }
    }

    fun close() {
        model.pendingInvite.value = null
        nav.popBackStack()
    }

    fun join(l: InviteLink) {
        joining = true
        error = null
        scope.launch {
            try {
                model.join(l)
                nav.popBackStack(Routes.MAIN, inclusive = false)
            } catch (e: Exception) {
                error = res.errorText(e)
            } finally {
                joining = false
            }
        }
    }

    TaskScaffold(
        stringResource(R.string.join_group),
        onClose = ::close,
        action = TaskAction(stringResource(R.string.join), enabled = link != null, busy = joining) { link?.let(::join) },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            val l = link
            if (l != null) {
                SectionHeader(stringResource(R.string.server))
                Surface(
                    shape = RoundedCornerShape(20.dp),
                    color = MaterialTheme.colorScheme.surfaceContainerLow,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = ListHorizontalPadding),
                ) {
                    Text(l.server.toHttpUrlOrNull()?.host ?: l.server, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(16.dp))
                }
                SectionFooter(stringResource(R.string.join_footer))
            } else {
                if (hasCamera) {
                    SectionHeader(stringResource(R.string.scan_qr))
                    Box(
                        Modifier.fillMaxWidth().padding(horizontal = ListHorizontalPadding).aspectRatio(1f).clip(RoundedCornerShape(20.dp)),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (cameraAllowed) {
                            QrScanner(Modifier.fillMaxSize()) { scanned ->
                                val parsed = InviteLink.parse(scanned)
                                if (parsed != null) link = parsed else error = res.getString(R.string.not_an_invite_qr)
                            }
                        } else {
                            Surface(color = MaterialTheme.colorScheme.surfaceContainerLow, modifier = Modifier.fillMaxSize()) {
                                Column(Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                                    Icon(Icons.Outlined.QrCodeScanner, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Spacer(Modifier.height(12.dp))
                                    Text(stringResource(R.string.camera_permission_needed), textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Spacer(Modifier.height(12.dp))
                                    FilledTonalButton(onClick = { askCamera.launch(Manifest.permission.CAMERA) }) { Text(stringResource(R.string.allow_camera)) }
                                }
                            }
                        }
                    }
                }
                SectionHeader(stringResource(R.string.or_paste_link))
                Column(Modifier.padding(horizontal = ListHorizontalPadding), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = pasted,
                        onValueChange = {
                            pasted = it
                            InviteLink.parse(it)?.let { parsed ->
                                link = parsed
                                error = null
                            }
                        },
                        label = { Text(stringResource(R.string.invite_link)) },
                        placeholder = { Text("openbalance://join?…") },
                        textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
                        minLines = 2,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedButton(onClick = {
                        val text = context.getSystemService(ClipboardManager::class.java)?.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString()
                        if (text != null) {
                            pasted = text
                            InviteLink.parse(text)?.let { link = it } ?: run { error = res.getString(R.string.not_an_invite_link) }
                        }
                    }) {
                        Icon(Icons.Outlined.ContentPaste, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.paste))
                    }
                }
            }
            error?.let { SectionFooter(it, Brand.negative) }
        }
    }
}

private val currencies = listOf("EUR", "USD", "GBP", "CHF", "SEK", "NOK", "DKK", "PLN", "CZK", "JPY", "CAD", "AUD", "TRY")

/**
 * Create a group on a server this device owns. Without a server, add one
 * first (URL + the server's ADMIN_TOKEN).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CreateGroupScreen() {
    val model = LocalAppModel.current
    val nav = LocalNav.current
    val context = LocalContext.current
    val res = LocalResources.current
    val scope = rememberCoroutineScope()
    val servers by model.servers.collectAsStateWithLifecycle()
    var server by rememberSaveable { mutableStateOf<String?>(null) }
    var name by rememberSaveable { mutableStateOf("") }
    var myName by rememberSaveable { mutableStateOf("") }
    val local = remember { runCatching { java.util.Currency.getInstance(Locale.getDefault()).currencyCode }.getOrNull() ?: "EUR" }
    var currency by rememberSaveable { mutableStateOf(local) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var serverMenu by remember { mutableStateOf(false) }
    var currencyMenu by remember { mutableStateOf(false) }

    LaunchedEffect(servers) { if (server == null || servers.none { it.server == server }) server = servers.firstOrNull()?.server }
    val canCreate = server != null && name.isNotBlank() && myName.isNotBlank()

    fun create() {
        val s = servers.firstOrNull { it.server == server } ?: return
        working = true
        error = null
        scope.launch {
            try {
                model.create(s, name.trim().take(100), currency, myName.trim().take(100))
                nav.popBackStack(Routes.MAIN, inclusive = false)
            } catch (e: Exception) {
                error = res.errorText(e)
            } finally {
                working = false
            }
        }
    }

    TaskScaffold(
        stringResource(R.string.new_group),
        onClose = { nav.popBackStack() },
        action = TaskAction(stringResource(R.string.create), enabled = canCreate, busy = working) { create() },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            SectionHeader(stringResource(R.string.server))
            Column(Modifier.padding(horizontal = ListHorizontalPadding), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (servers.isNotEmpty()) {
                    ExposedDropdownMenuBox(expanded = serverMenu, onExpandedChange = { serverMenu = it }) {
                        OutlinedTextField(
                            value = servers.firstOrNull { it.server == server }?.name ?: "",
                            onValueChange = {},
                            readOnly = true,
                            label = { Text(stringResource(R.string.server)) },
                            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(serverMenu) },
                            modifier = Modifier.fillMaxWidth().menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable),
                        )
                        ExposedDropdownMenu(expanded = serverMenu, onDismissRequest = { serverMenu = false }) {
                            for (s in servers) DropdownMenuItem(
                                text = { Text(s.name) },
                                onClick = {
                                    server = s.server
                                    serverMenu = false
                                },
                            )
                        }
                    }
                }
                TextButton(onClick = { nav.navigate(Routes.ADD_SERVER) }) {
                    Icon(if (servers.isEmpty()) Icons.Outlined.Dns else Icons.Outlined.Add, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(if (servers.isEmpty()) R.string.add_server else R.string.add_another_server))
                }
            }
            if (servers.isEmpty()) SectionFooter(stringResource(R.string.server_footer_empty))

            Column(Modifier.padding(horizontal = ListHorizontalPadding, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = name, onValueChange = { name = it },
                    label = { Text(stringResource(R.string.group_name)) }, singleLine = true,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Next),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = myName, onValueChange = { myName = it },
                    label = { Text(stringResource(R.string.your_name_in_group)) }, singleLine = true,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
                    modifier = Modifier.fillMaxWidth(),
                )
                ExposedDropdownMenuBox(expanded = currencyMenu, onExpandedChange = { currencyMenu = it }) {
                    OutlinedTextField(
                        value = currency,
                        onValueChange = {},
                        readOnly = true,
                        label = { Text(stringResource(R.string.currency)) },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(currencyMenu) },
                        modifier = Modifier.fillMaxWidth().menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = currencyMenu, onDismissRequest = { currencyMenu = false }) {
                        for (c in (currencies + currency).toSortedSet()) DropdownMenuItem(
                            text = { Text(c) },
                            onClick = {
                                currency = c
                                currencyMenu = false
                            },
                        )
                    }
                }
            }
            SectionFooter(stringResource(R.string.currency_footer))
            error?.let { SectionFooter(it, Brand.negative) }
        }
    }
}

/** Add a server this device may create groups on: its URL and ADMIN_TOKEN. */
@Composable
fun AddServerScreen() {
    val model = LocalAppModel.current
    val nav = LocalNav.current
    val context = LocalContext.current
    val res = LocalResources.current
    val scope = rememberCoroutineScope()
    var url by rememberSaveable { mutableStateOf("") }
    var token by remember { mutableStateOf("") }
    var showToken by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    fun add() {
        var raw = url.trim()
        if (!raw.contains("://")) raw = "https://$raw"
        raw = raw.trimEnd('/')
        if (raw.toHttpUrlOrNull()?.host.isNullOrEmpty()) {
            error = res.getString(R.string.invalid_url)
            return
        }
        working = true
        error = null
        scope.launch {
            try {
                model.addServer(raw, token.trim())
                nav.popBackStack()
            } catch (e: Exception) {
                error = res.errorText(e)
            } finally {
                working = false
            }
        }
    }

    TaskScaffold(
        stringResource(R.string.add_server),
        onClose = { nav.popBackStack() },
        action = TaskAction(stringResource(R.string.add), enabled = url.isNotBlank() && token.isNotBlank(), busy = working) { add() },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())) {
            Column(Modifier.padding(horizontal = ListHorizontalPadding, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = url, onValueChange = { url = it },
                    label = { Text(stringResource(R.string.server_url)) },
                    placeholder = { Text(stringResource(R.string.server_url_hint)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false, imeAction = ImeAction.Next),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = token, onValueChange = { token = it },
                    label = { Text(stringResource(R.string.admin_token)) },
                    singleLine = true,
                    visualTransformation = if (showToken) VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = {
                        IconButton(onClick = { showToken = !showToken }) {
                            Icon(if (showToken) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, null)
                        }
                    },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false, imeAction = ImeAction.Done),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            SectionFooter(stringResource(R.string.admin_token_footer))
            error?.let { SectionFooter(it, Brand.negative) }
        }
    }
}
