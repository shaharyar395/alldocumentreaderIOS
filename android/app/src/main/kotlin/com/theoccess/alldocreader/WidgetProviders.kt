package com.theoccess.alldocreader

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/*
 * The four home-screen widgets of the Android reference app (widget/Widgets.kt):
 *  - "Quick tools"      (ToolsWidgetProvider):  Search, Home, Recent, Bookmarks, Edit PDF
 *  - "Document reader"  (ReaderWidgetProvider): Search, Edit PDF pill, PDF / Word / Excel / PPT
 *  - "PDF editor" 2x2   (PdfEditorWidgetProvider)
 *  - "PDF editor" 1x1   (PdfEditorSmallWidgetProvider)
 * Every button starts MainActivity with the extra "widget_action" (see MainActivity.readAction);
 * the Flutter side handles the action (lib/features/shell/widget_actions.dart).
 */

/** Same name as MainActivity.EXTRA_WIDGET_ACTION. */
private const val EXTRA_WIDGET_ACTION = "widget_action"

/** The provider class for a kind of PlatformBridge.pinWidget ("tools", "reader", "editor2x2", "editor1x1"). */
fun widgetProviderFor(kind: String): Class<out AppWidgetProvider> = when (kind) {
    "reader" -> ReaderWidgetProvider::class.java
    "editor2x2" -> PdfEditorWidgetProvider::class.java
    "editor1x1" -> PdfEditorSmallWidgetProvider::class.java
    else -> ToolsWidgetProvider::class.java
}

internal object WidgetIntents {
    /** Opens the app with [action]; each action gets its own Intent action so the system keeps the PendingIntents apart. */
    fun open(context: Context, action: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .setAction("com.theoccess.alldocreader.widget.$action")
            .putExtra(EXTRA_WIDGET_ACTION, action)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    fun update(context: Context, manager: AppWidgetManager, ids: IntArray, layout: Int, bind: (RemoteViews) -> Unit) {
        for (id in ids) {
            val views = RemoteViews(context.packageName, layout)
            bind(views)
            manager.updateAppWidget(id, views)
        }
    }
}

/** "Quick tools": Search, Home, Recent (Recently added list), Bookmarks, Edit PDF. */
class ToolsWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetIntents.update(context, manager, ids, R.layout.tools_widget) { views ->
            views.setOnClickPendingIntent(R.id.wSearch, WidgetIntents.open(context, "search", 10))
            views.setOnClickPendingIntent(R.id.wHome, WidgetIntents.open(context, "home", 11))
            views.setOnClickPendingIntent(R.id.wRecent, WidgetIntents.open(context, "recent", 12))
            views.setOnClickPendingIntent(R.id.wBookmarks, WidgetIntents.open(context, "bookmarks", 13))
            views.setOnClickPendingIntent(R.id.wEdit, WidgetIntents.open(context, "edit", 14))
        }
}

/** "Document reader": Search, Edit PDF, and the PDF / Word / Excel / PPT lists. */
class ReaderWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetIntents.update(context, manager, ids, R.layout.reader_widget) { views ->
            views.setOnClickPendingIntent(R.id.wSearch, WidgetIntents.open(context, "search", 20))
            views.setOnClickPendingIntent(R.id.wEditPill, WidgetIntents.open(context, "edit", 21))
            views.setOnClickPendingIntent(R.id.wPdf, WidgetIntents.open(context, "pdf", 22))
            views.setOnClickPendingIntent(R.id.wWord, WidgetIntents.open(context, "word", 23))
            views.setOnClickPendingIntent(R.id.wExcel, WidgetIntents.open(context, "excel", 24))
            views.setOnClickPendingIntent(R.id.wPpt, WidgetIntents.open(context, "ppt", 25))
        }
}

/** "PDF editor" 2x2 picture tile: Edit PDF. */
class PdfEditorWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetIntents.update(context, manager, ids, R.layout.pdf_editor_widget) { views ->
            views.setOnClickPendingIntent(R.id.wRoot, WidgetIntents.open(context, "edit", 30))
        }
}

/** "PDF editor" 1x1 icon: Edit PDF. */
class PdfEditorSmallWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) =
        WidgetIntents.update(context, manager, ids, R.layout.pdf_editor_small_widget) { views ->
            views.setOnClickPendingIntent(R.id.wRoot, WidgetIntents.open(context, "edit", 31))
        }
}
