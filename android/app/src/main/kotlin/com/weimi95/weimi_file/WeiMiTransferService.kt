package com.weimi95.weimi_file

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/// 微密飞传前台服务：App 退到后台时保持进程存活，UDP 广播与 HTTP 接收继续工作。
/// 接收开启时由 MainActivity 通过 MethodChannel startForeground/stopForeground 拉起/停止。
class WeiMiTransferService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(1, notification)
        }
        return START_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                "weimi_transfer",
                "微密飞传",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "微密飞传后台传输保活"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(this, "weimi_transfer")
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(this)
        }
        return builder
            .setContentTitle("微密飞传运行中")
            .setContentText("允许附近设备发现本机并传输文件")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
    }
}
