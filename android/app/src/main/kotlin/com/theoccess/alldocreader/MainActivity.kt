package com.theoccess.alldocreader

import android.Manifest
import android.annotation.TargetApi
import android.appwidget.AppWidgetManager
import android.content.ClipData
import android.content.ComponentName
import android.content.ContentResolver
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "com.theoccess.alldocreader/platform"
    private var channel: MethodChannel? = null

    /** The file (or "To home screen" shortcut) that started the app, until Dart asks for it. */
    private var pendingIncoming: Map<String, Any>? = null
    private var pendingAction: String? = null

    /** Android 10 and older: the storage permission dialog answers this call. */
    private var accessResult: MethodChannel.Result? = null
    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { _ ->
            val pending = accessResult
            accessResult = null
            pending?.success(hasStorageAccess())
        }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var mediaObserver: ContentObserver? = null
    private val mediaChanged = Runnable { channel?.invokeMethod("onMediaChanged", null) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        com.tom_roush.pdfbox.android.PDFBoxResourceLoader.init(applicationContext)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePendingIncoming" -> {
                    result.success(pendingIncoming)
                    pendingIncoming = null
                }
                "takePendingUri" -> {
                    result.success(pendingIncoming?.get("uri"))
                    pendingIncoming = null
                }
                "takePendingAction" -> {
                    result.success(pendingAction)
                    pendingAction = null
                }
                "appVersion" -> result.success(appVersionName())
                "deviceInfo" -> result.success("Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT}) · ${Build.MANUFACTURER} ${Build.MODEL}")
                "pinShortcut" -> {
                    // "To home screen": a launcher shortcut that opens this file in the app
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name") ?: "Document"
                    val kind = call.argument<String>("kind") ?: "other"
                    if (path.isNullOrEmpty()) result.success(false) else result.success(pinShortcut(path, name, kind))
                }
                "pinWidget" -> {
                    val kind = call.argument<String>("kind") ?: "tools"
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                        result.success(false)
                    } else {
                        result.success(pinWidget(widgetProviderFor(kind)))
                    }
                }
                "copyUri" -> {
                    val uri = call.argument<String>("uri")
                    val dest = call.argument<String>("dest")
                    if (uri == null || dest == null) {
                        result.error("bad_args", "uri and dest required", null)
                    } else {
                        Thread {
                            try {
                                copyUri(Uri.parse(uri), File(dest))
                                runOnUiThread { result.success(dest) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("copy_failed", e.message, null) }
                            }
                        }.start()
                    }
                }
                "displayName" -> {
                    val uri = call.argument<String>("uri")
                    if (uri == null) result.success("document") else result.success(displayName(Uri.parse(uri)) ?: "document")
                }
                "resolveIncoming" -> {
                    val uri = call.argument<String>("uri")
                    if (uri.isNullOrEmpty()) {
                        result.success(null)
                    } else {
                        Thread {
                            val info = try { resolveIncoming(Uri.parse(uri)) } catch (e: Exception) { null }
                            runOnUiThread { result.success(info) }
                        }.start()
                    }
                }
                "storageStats" -> {
                    val stat = StatFs(Environment.getDataDirectory().path)
                    result.success(mapOf("total" to stat.totalBytes, "free" to stat.availableBytes))
                }
                "storageAccess" -> result.success(hasStorageAccess())
                "requestStorageAccess" -> requestStorageAccess(result)
                "publicDocumentsDir" -> result.success(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS).absolutePath
                )
                "scanDevice" -> {
                    val extensions = call.argument<List<String>>("extensions").orEmpty().map { it.lowercase() }.toHashSet()
                    Thread {
                        val files = try { scanDevice(extensions) } catch (e: Exception) { emptyList() }
                        runOnUiThread { result.success(files) }
                    }.start()
                }
                "scanPaths" -> {
                    val paths = call.argument<List<String>>("paths").orEmpty()
                    if (paths.isNotEmpty()) {
                        try {
                            MediaScannerConnection.scanFile(applicationContext, paths.toTypedArray(), null, null)
                        } catch (_: Exception) {
                        }
                    }
                    result.success(null)
                }
                "startWatching" -> {
                    startWatching()
                    result.success(null)
                }
                "openExternal" -> {
                    val path = call.argument<String>("path")
                    result.success(path != null && openExternal(path, call.argument<String>("mime")))
                }
                "saveToDrive" -> {
                    val path = call.argument<String>("path")
                    result.success(if (path == null) "failed" else saveToDrive(File(path)))
                }
                "openFileManager" -> result.success(openFileManager())
                "isXiaomi" -> result.success(Build.MANUFACTURER.lowercase() in setOf("xiaomi", "redmi", "poco"))
                "openAppDetails" -> {
                    openAppDetails()
                    result.success(null)
                }
                "updateWidget" -> {
                    val line = call.argument<String>("line") ?: ""
                    getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                        .edit()
                        .putString("flutter.widget_line", line)
                        .apply()
                    val manager = AppWidgetManager.getInstance(this)
                    val providers = listOf("tools", "reader", "editor2x2", "editor1x1").map { widgetProviderFor(it) }.distinct()
                    for (provider in providers) {
                        val ids = manager.getAppWidgetIds(ComponentName(this, provider))
                        if (ids.isNotEmpty()) {
                            val update = Intent(this, provider).apply {
                                action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                                putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                            }
                            sendBroadcast(update)
                        }
                    }
                    result.success(null)
                }
                "assemblePdf" -> {
                    // Merge / Split / Extract / Manage pages: copies the real PDF pages (text,
                    // fonts, pictures stay as they are) instead of turning them into pictures
                    val output = call.argument<String>("output")
                    val pages = call.argument<List<Map<String, Any?>>>("pages")
                    if (output == null || pages == null) {
                        result.error("bad_args", "output and pages required", null)
                    } else {
                        Thread {
                            try {
                                assemblePdf(output, pages)
                                runOnUiThread { result.success(output) }
                            } catch (e: Throwable) {
                                runOnUiThread { result.error("pdf_failed", e.message, null) }
                            }
                        }.start()
                    }
                }
                else -> result.notImplemented()
            }
        }
        pendingAction = readAction(intent)
        pendingIncoming = readIncoming(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val active = channel
        val action = readAction(intent)
        if (action != null) {
            if (active == null) pendingAction = action else active.invokeMethod("onWidgetAction", action)
            return
        }
        val incoming = readIncoming(intent) ?: return
        if (active == null) pendingIncoming = incoming else active.invokeMethod("onIncomingUri", incoming)
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(mediaChanged)
        mediaObserver?.let { observer ->
            try {
                contentResolver.unregisterContentObserver(observer)
            } catch (_: Exception) {
            }
        }
        mediaObserver = null
        super.onDestroy()
    }

    /** Home-screen widget button ("search", "recent", "bookmarks", "edit", "home"); read once. */
    private fun readAction(intent: Intent?): String? {
        if (intent == null) return null
        val action = intent.getStringExtra(EXTRA_WIDGET_ACTION) ?: return null
        intent.removeExtra(EXTRA_WIDGET_ACTION)
        return action.ifEmpty { null }
    }

    /**
     * A file from another app (VIEW / SEND: {"uri", "shortcut": false}) or a pinned "To home
     * screen" shortcut ({"uri": the file path, "shortcut": true}); read once.
     */
    private fun readIncoming(intent: Intent?): Map<String, Any>? {
        if (intent == null) return null
        intent.getStringExtra(EXTRA_OPEN_PATH)?.let { path ->
            intent.removeExtra(EXTRA_OPEN_PATH)
            if (path.isNotEmpty()) return mapOf("uri" to path, "shortcut" to true)
        }
        if (intent.action != Intent.ACTION_VIEW && intent.action != Intent.ACTION_SEND) return null
        val uri: Uri? = if (intent.action == Intent.ACTION_SEND) {
            if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            }
        } else {
            intent.data
        }
        if (uri == null) return null
        // handled once: a recreated activity must not open the file again
        intent.action = Intent.ACTION_MAIN
        return mapOf("uri" to uri.toString(), "shortcut" to false)
    }

    private fun appVersionName(): String {
        return try {
            packageInfoVersion() ?: ""
        } catch (_: Exception) {
            ""
        }
    }

    @Suppress("DEPRECATION")
    private fun packageInfoVersion(): String? {
        val info = if (Build.VERSION.SDK_INT >= 33) {
            packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            packageManager.getPackageInfo(packageName, 0)
        }
        return info.versionName
    }

    // ------------------------------------------------------------------ storage access

    /** Like the Android app's StorageAccess.has: "All files access" (11+) / READ permission. */
    private fun hasStorageAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }

    /** 11+: the "All files access" settings page (answers false at once); 10 and older: the system dialog. */
    private fun requestStorageAccess(result: MethodChannel.Result) {
        if (hasStorageAccess()) {
            result.success(true)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            openAllFilesSettings()
            result.success(false)
            return
        }
        accessResult?.success(false)
        accessResult = result
        try {
            permissionLauncher.launch(
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE)
            )
        } catch (_: Exception) {
            accessResult = null
            result.success(false)
        }
    }

    @TargetApi(Build.VERSION_CODES.R)
    private fun openAllFilesSettings() {
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).setData(Uri.parse("package:$packageName"))
            )
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            } catch (_: Exception) {
            }
        }
    }

    // ------------------------------------------------------------------ device scan

    /**
     * Every supported file on the phone, like the Android app's FileRepository: the media index
     * first (MediaStore.Files by extension; no size or count limit), then a folder walk for files
     * the index doesn't know yet (8 levels, no dot names, top-level Android/ skipped except
     * Android/media), which are handed to the media scanner once.
     */
    private fun scanDevice(extensions: Set<String>): List<Map<String, Any>> {
        val found = LinkedHashMap<String, Map<String, Any>>()
        try {
            queryMediaStore(extensions, found)
        } catch (_: Exception) {
        }
        val walked = LinkedHashMap<String, Map<String, Any>>()
        try {
            walk(Environment.getExternalStorageDirectory(), extensions, walked, 0)
        } catch (_: Exception) {
        }
        val missing = walked.keys.filter { it !in found }
        if (missing.isNotEmpty()) {
            val toScan = synchronized(handedToScanner) { missing.filter { handedToScanner.add(it) }.take(500) }
            if (toScan.isNotEmpty()) {
                try {
                    MediaScannerConnection.scanFile(applicationContext, toScan.toTypedArray(), null, null)
                } catch (_: Exception) {
                }
            }
            missing.forEach { found[it] = walked.getValue(it) }
        }
        return found.values.toList()
    }

    private fun queryMediaStore(extensions: Set<String>, out: MutableMap<String, Map<String, Any>>) {
        if (extensions.isEmpty()) return
        val uri = MediaStore.Files.getContentUri("external")
        @Suppress("DEPRECATION")
        val dataCol = MediaStore.Files.FileColumns.DATA
        val projection = arrayOf(dataCol, MediaStore.Files.FileColumns.SIZE, MediaStore.Files.FileColumns.DATE_MODIFIED)
        val list = extensions.toList()
        // LIKE ignores upper / lower case already
        val selection = list.joinToString(" OR ") { "$dataCol LIKE ?" }
        val args = list.map { "%.$it" }.toTypedArray()
        contentResolver.query(uri, projection, selection, args, null)?.use { c ->
            val iData = c.getColumnIndexOrThrow(dataCol)
            val iSize = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
            val iDate = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_MODIFIED)
            while (c.moveToNext()) {
                val path = c.getString(iData) ?: continue
                if (path.contains("/.")) continue // hidden folders / files
                val ext = path.substringAfterLast('/').substringAfterLast('.', "").lowercase()
                if (ext !in extensions) continue
                val f = File(path)
                if (!f.exists()) continue
                var size = c.getLong(iSize)
                var modified = c.getLong(iDate) * 1000L
                if (size <= 0L) size = f.length()
                if (modified <= 0L) modified = f.lastModified()
                if (size <= 0L) continue
                out[path] = mapOf("path" to path, "size" to size, "modified" to modified)
            }
        }
    }

    private fun walk(dir: File, extensions: Set<String>, out: MutableMap<String, Map<String, Any>>, depth: Int) {
        if (depth > 8) return
        val children = dir.listFiles() ?: return
        for (f in children) {
            if (f.name.startsWith(".")) continue
            if (f.isDirectory) {
                // Android/ holds app data, except Android/media (WhatsApp / Telegram documents)
                if (depth == 0 && f.name == "Android") {
                    File(f, "media").takeIf { it.isDirectory }?.let { walk(it, extensions, out, depth + 2) }
                    continue
                }
                walk(f, extensions, out, depth + 1)
            } else {
                val ext = f.name.substringAfterLast('.', "").lowercase()
                if (ext !in extensions) continue
                val size = f.length()
                if (size > 0) out[f.absolutePath] = mapOf("path" to f.absolutePath, "size" to size, "modified" to f.lastModified())
            }
        }
    }

    /** Files added / removed by other apps while ours is open: tells Dart (2.5 s debounce). */
    private fun startWatching() {
        if (mediaObserver != null) return
        val observer = object : ContentObserver(mainHandler) {
            override fun onChange(selfChange: Boolean) {
                mainHandler.removeCallbacks(mediaChanged)
                mainHandler.postDelayed(mediaChanged, 2_500L)
            }
        }
        try {
            contentResolver.registerContentObserver(MediaStore.Files.getContentUri("external"), true, observer)
            mediaObserver = observer
        } catch (_: Exception) {
        }
    }

    // ------------------------------------------------------------------ incoming files

    private fun copyUri(uri: Uri, dest: File) {
        dest.parentFile?.mkdirs()
        val input = contentResolver.openInputStream(uri) ?: error("empty stream")
        input.use { source -> dest.outputStream().use { source.copyTo(it) } }
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme == ContentResolver.SCHEME_FILE) return uri.path?.let { File(it).name }
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) cursor.getString(index)?.let { return it }
                }
            }
        } catch (_: Exception) {
        }
        return uri.lastPathSegment?.substringAfterLast('/')
    }

    private fun querySize(uri: Uri): Long {
        if (uri.scheme == ContentResolver.SCHEME_FILE) return uri.path?.let { File(it).length() } ?: -1L
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else -1L
            } ?: -1L
        } catch (_: Exception) {
            -1L
        }
    }

    /** Name, MIME type, size and the real file when it can be read in place (OpenDocumentActivity.resolve). */
    private fun resolveIncoming(uri: Uri): Map<String, Any?> {
        val real = realFile(uri)?.takeIf { it.isFile && it.canRead() }
        val name = real?.name ?: displayName(uri) ?: ""
        val reported: String? = try {
            contentResolver.getType(uri)
        } catch (_: Exception) {
            null
        }
        val mime = reported
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
            ?: ""
        val size = real?.length() ?: querySize(uri)
        return mapOf("path" to real?.absolutePath, "name" to name, "mime" to mime, "size" to size)
    }

    /** Maps file://, ExternalStorageProvider, DownloadsProvider "raw:" and MediaStore uris to paths. */
    private fun realFile(uri: Uri): File? {
        if (uri.scheme == ContentResolver.SCHEME_FILE) return uri.path?.let { File(it) }
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) return null
        try {
            if (DocumentsContract.isDocumentUri(this, uri)) {
                val id = DocumentsContract.getDocumentId(uri)
                when (uri.authority) {
                    "com.android.externalstorage.documents" -> {
                        val type = id.substringBefore(':')
                        val rel = id.substringAfter(':', "")
                        val root = if (type.equals("primary", true)) Environment.getExternalStorageDirectory().path
                        else "/storage/$type"
                        return File(root, rel)
                    }
                    "com.android.providers.downloads.documents" -> {
                        if (id.startsWith("raw:")) return File(id.removePrefix("raw:"))
                    }
                }
            }
            // MediaStore / file managers that expose a _data column
            contentResolver.query(uri, arrayOf("_data"), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex("_data")
                    if (idx >= 0) c.getString(idx)?.let { return File(it) }
                }
            }
        } catch (_: Exception) {
        }
        // some file managers use content://authority/root/storage/... or /external_files/...
        uri.path?.let { p ->
            val candidates = listOf(
                p.substringAfter("/root", ""),
                p.substringAfter("/storage", "").let { if (it.isEmpty()) "" else "/storage$it" },
            )
            candidates.filter { it.startsWith("/") }.map { File(it) }.firstOrNull { it.isFile }?.let { return it }
        }
        return null
    }

    // ------------------------------------------------------------------ other apps

    private fun uriFor(file: File): Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)

    private fun mimeOf(file: File): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "*/*"

    /** ACTION_VIEW chooser for a type the app does not open itself (FileActions.open). */
    private fun openExternal(path: String, mime: String?): Boolean {
        val file = File(path)
        if (!file.exists()) return false
        val uri = try { uriFor(file) } catch (_: Exception) { return false }
        val type = mime?.takeIf { it.isNotEmpty() && it != "*/*" } ?: mimeOf(file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, type)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        @Suppress("DEPRECATION")
        val targets = try { packageManager.queryIntentActivities(intent, 0) } catch (_: Exception) { emptyList() }
        if (targets.isEmpty() && intent.resolveActivity(packageManager) == null) return false
        return try {
            startActivity(Intent.createChooser(intent, file.name))
            true
        } catch (_: Exception) {
            false
        }
    }

    /** "Save to Drive": the Google Drive app's own upload screen (DriveSaveActivity.openDriveApp). */
    private fun saveToDrive(file: File): String {
        if (!file.exists()) return "failed"
        val uri = try { uriFor(file) } catch (_: Exception) { return "failed" }
        val send = Intent(Intent.ACTION_SEND)
            .setType(mimeOf(file).takeIf { it != "*/*" } ?: "application/octet-stream")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .putExtra(Intent.EXTRA_TITLE, file.name)
            .putExtra(Intent.EXTRA_SUBJECT, file.name)
            .setPackage(DRIVE_PACKAGE)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        send.clipData = ClipData.newRawUri(file.name, uri)
        @Suppress("DEPRECATION")
        val targets = try { packageManager.queryIntentActivities(send, 0) } catch (_: Exception) { emptyList() }
        if (targets.isEmpty()) return "missing"
        // Drive offers "Save to Drive" (upload) and "Copy to clipboard": take the upload one
        val upload = targets.firstOrNull { it.activityInfo.name.contains("Upload", ignoreCase = true) }
            ?: targets.firstOrNull { !it.activityInfo.name.contains("Clipboard", ignoreCase = true) }
            ?: return "missing"
        send.setClassName(upload.activityInfo.packageName, upload.activityInfo.name)
        return try {
            startActivity(send)
            "ok"
        } catch (_: Exception) {
            "failed"
        }
    }

    /** Android's own Files app (Links.fileManager). */
    private fun openFileManager(): Boolean {
        val tries = ArrayList<Intent>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tries += Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_APP_FILES)
        }
        tries += Intent(Intent.ACTION_VIEW).setDataAndType(
            DocumentsContract.buildRootUri("com.android.externalstorage.documents", "primary"),
            "vnd.android.document/root"
        )
        tries += Intent(Intent.ACTION_VIEW).setDataAndType(
            Uri.parse("content://com.android.externalstorage.documents/root/primary"),
            DocumentsContract.Document.MIME_TYPE_DIR
        )
        for (i in tries) {
            try {
                startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: Exception) {
            }
        }
        return false
    }

    /** The app's permission screen: MIUI's permission editor when there is one, else App info. */
    private fun openAppDetails() {
        val miui = Intent("miui.intent.action.APP_PERM_EDITOR")
            .setClassName("com.miui.securitycenter", "com.miui.permcenter.permissions.PermissionsEditorActivity")
            .putExtra("extra_pkgname", packageName)
        try {
            startActivity(miui)
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
            } catch (_: Exception) {
            }
        }
    }

    // ------------------------------------------------------------------ shortcuts / widgets

    /** "To home screen" (Shortcuts.pin): the file type's icon; opens the file straight in the reader. */
    private fun pinShortcut(path: String, name: String, kind: String): Boolean {
        return try {
            if (!ShortcutManagerCompat.isRequestPinShortcutSupported(this)) return false
            val open = Intent(this, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .putExtra(EXTRA_OPEN_PATH, path)
            val label = name.ifEmpty { "Document" }
            val info = ShortcutInfoCompat.Builder(this, "file_" + path.hashCode())
                .setShortLabel(label.take(24))
                .setLongLabel(label)
                .setIcon(shortcutIcon(kind))
                .setIntent(open)
                .build()
            ShortcutManagerCompat.requestPinShortcut(this, info, null)
        } catch (_: Exception) {
            false
        }
    }

    /** Launchers handle bitmap icons more reliably than vector resources. */
    private fun shortcutIcon(kind: String): IconCompat {
        val res = when (kind) {
            "pdf" -> R.drawable.ic_cat_pdf
            "word" -> R.drawable.ic_cat_word
            "excel" -> R.drawable.ic_cat_excel
            "ppt" -> R.drawable.ic_cat_ppt
            "txt" -> R.drawable.ic_cat_txt
            "image" -> R.drawable.ic_cat_image
            else -> R.drawable.ic_file_unknown
        }
        val drawable = ContextCompat.getDrawable(this, res)
            ?: return IconCompat.createWithResource(this, R.mipmap.ic_launcher)
        val size = (48 * resources.displayMetrics.density).toInt()
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        canvas.drawColor(Color.WHITE)
        val pad = size / 5
        drawable.setBounds(pad, pad, size - pad, size - pad)
        drawable.draw(canvas)
        return IconCompat.createWithBitmap(bmp)
    }

    @TargetApi(Build.VERSION_CODES.O)
    private fun pinWidget(provider: Class<*>): Boolean {
        return try {
            val manager = getSystemService(AppWidgetManager::class.java) ?: return false
            if (!manager.isRequestPinAppWidgetSupported) return false
            manager.requestPinAppWidget(ComponentName(this, provider), null, null)
        } catch (_: Exception) {
            false
        }
    }

    companion object {
        /** Extra of the home-screen widget buttons (see [ToolsWidgetProvider]). */
        const val EXTRA_WIDGET_ACTION = "widget_action"

        /** Extra of the pinned "To home screen" file shortcuts. */
        const val EXTRA_OPEN_PATH = "open_path"

        private const val DRIVE_PACKAGE = "com.google.android.apps.docs"

        /** Files the folder walk handed to the media scanner (once each per app run). */
        private val handedToScanner = HashSet<String>()
    }
}

/**
 * Builds a new PDF at [output] from [pages]: each entry is {"src": path, "index": 0-based page,
 * "rotate": degrees added (0/90/180/270)}. Pages are copied as they are (pdfbox importPage), so
 * text stays text. Sources stay open until the new file is written.
 */
private fun assemblePdf(output: String, pages: List<Map<String, Any?>>) {
    val sources = HashMap<String, com.tom_roush.pdfbox.pdmodel.PDDocument>()
    val tmp = File("$output.part")
    try {
        com.tom_roush.pdfbox.pdmodel.PDDocument().use { dst ->
            for (entry in pages) {
                val src = entry["src"] as? String ?: continue
                val doc = sources.getOrPut(src) {
                    com.tom_roush.pdfbox.pdmodel.PDDocument.load(File(src)).also { it.isAllSecurityToBeRemoved = true }
                }
                val index = (entry["index"] as? Number)?.toInt() ?: 0
                if (index < 0 || index >= doc.numberOfPages) continue
                val page = dst.importPage(doc.getPage(index))
                val rotate = (entry["rotate"] as? Number)?.toInt() ?: 0
                if (rotate % 360 != 0) page.rotation = ((page.rotation + rotate) % 360 + 360) % 360
            }
            if (dst.numberOfPages == 0) throw IllegalStateException("no pages")
            dst.save(tmp)
        }
    } catch (e: Throwable) {
        tmp.delete()
        throw e
    } finally {
        sources.values.forEach { try { it.close() } catch (ignored: Exception) {} }
    }
    val out = File(output)
    out.delete()
    if (!tmp.renameTo(out)) { tmp.copyTo(out, overwrite = true); tmp.delete() }
}
