# ── JNA / Vosk 混淆保留规则 ──────────────────────────────────────────────
# 该文件被 Flutter Gradle 插件自动挂到 release 的 proguardFiles 上
# （见 flutter_tools/gradle/.../FlutterPlugin.kt：${projectDir}/proguard-rules.pro 存在即加载），
# 因此不需要改 app/build.gradle.kts。
#
# 不写这些规则的后果（release 包必现，debug 包不复现）：
#   进入开口题 → l4_step/say_widget 懒加载 Vosk 引擎 → org.vosk.LibVosk.<clinit>
#   → com.sun.jna.Native.initIDs  → 原生线程抛
#        java.lang.UnsatisfiedLinkError:
#        Can't obtain peer field ID for class com.sun.jna.Pointer
#   → FATAL EXCEPTION: pool-3-thread-1 → 进程直接死、退回桌面。
#
# 根因：JNA 的 Native.initIDs 走反射取 com.sun.jna.Pointer.peer 的 fieldID，
#       R8 在 release 下会把这个字段改名/裁掉。vosk_flutter 0.3.48 没有自带
#       consumer-rules.pro，只能由 App 侧兜住。
# 注意：这一崩发生在 Java 后台线程上，Dart 侧的 try/catch 拦不住，必须靠规则解决。

# JNA 本体：字段/方法全部保留
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { *; }

# 反射代理：Native.load 生成的接口/回调/结构体
-keep class * implements com.sun.jna.Library { *; }
-keep class * implements com.sun.jna.Callback { *; }
-keep class * extends com.sun.jna.Structure { *; }
-keep class * extends com.sun.jna.Pointer { *; }

# Vosk 的 JNI 封装类（含静态初始化块）
-keep class org.vosk.** { *; }
-keepclassmembers class org.vosk.** { *; }

# JNA 在未使用 AWT 时会有这些可选引用，避免 R8 报 missing class
-dontwarn com.sun.jna.**
-dontwarn java.awt.**
