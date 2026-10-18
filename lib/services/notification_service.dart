import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// 留存通知：每日练习提醒（本地通知，不依赖网络 / 后端）。
///
/// 设计约束（与主流程对齐）：
///  - 通知是「锦上添花」，任何失败都不允许影响启动或练习主链路 → 全程 try/catch。
///  - 用设备当前时区偏移把本地时间换算成 UTC 锚点，避免额外引入 flutter_timezone；
///    非 DST 地区（如中国）每日重复准确，DST 地区仅在跨夏令时当天偏移一小时。
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const int _dailyId = 1001;
  static const String _channelId = 'daily_reminder';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _inited = false;

  bool get isReady => _inited;

  Future<void> init() async {
    try {
      tzdata.initializeTimeZones();
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const settings = InitializationSettings(android: android);
      await _plugin.initialize(settings);
      _inited = true;
    } catch (_) {
      _inited = false;
    }
  }

  /// Android 13+ 运行时通知权限；未授权返回 false（调用方据此提示 / 降级）。
  Future<bool> requestPermission() async {
    if (!_inited) await init();
    try {
      final granted = await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      return granted ?? true;
    } catch (_) {
      return false;
    }
  }

  /// 挂/重挂每日提醒。若系统清理过闹钟（或进程重启），开机重调本方法即可复挂。
  Future<void> scheduleDaily(int hour, int minute) async {
    if (!_inited) await init();
    if (!_inited) return;
    try {
      await _plugin.zonedSchedule(
        _dailyId,
        '该练口语啦',
        '每天 5 分钟，保持节奏。',
        _nextInstance(hour, minute),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            '每日练习提醒',
            channelDescription: '每天定时提醒开口练习',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        // iOS 遗留必填参数（本工程仅 Android，实际被忽略）。
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (_) {
      // 调度失败静默，不阻塞主流程。
    }
  }

  Future<void> cancelDaily() async {
    try {
      await _plugin.cancel(_dailyId);
    } catch (_) {}
  }

  /// 下一次 (hour:minute)。把本地墙上时间按设备偏移换算为 UTC 锚点。
  tz.TZDateTime _nextInstance(int hour, int minute) {
    final now = DateTime.now();
    var local = DateTime(now.year, now.month, now.day, hour, minute);
    if (!local.isAfter(now)) {
      local = local.add(const Duration(days: 1));
    }
    final utc = local.subtract(now.timeZoneOffset);
    return tz.TZDateTime.from(utc, tz.UTC);
  }
}
