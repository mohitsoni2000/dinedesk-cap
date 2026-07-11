package com.command.crew

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/** Home-screen "My floor" widget — fed by WidgetSyncService (home_widget). */
class CrewTablesWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        val ready = widgetData.getInt("w_ready", 0)
        appWidgetIds.forEach { id ->
            val views = RemoteViews(context.packageName, R.layout.widget_crew_tables).apply {
                setTextViewText(R.id.w_mine, widgetData.getInt("w_mine", 0).toString())
                setTextViewText(R.id.w_free, widgetData.getInt("w_free", 0).toString())
                setTextViewText(R.id.w_ready, ready.toString())
                setTextColor(
                    R.id.w_ready,
                    if (ready > 0) Color.parseColor("#4FD08A")
                    else Color.parseColor("#66F5EEE3")
                )
                setTextViewText(
                    R.id.w_revenue,
                    (widgetData.getString("w_revenue", "₹0") ?: "₹0") + " on tables"
                )
                setTextViewText(
                    R.id.w_updated,
                    widgetData.getString("w_updated", "--:--") ?: "--:--"
                )
                setOnClickPendingIntent(
                    R.id.w_root,
                    HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java)
                )
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
