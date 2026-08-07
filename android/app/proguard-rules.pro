# ==============================================================================
# EchoWrite ProGuard / R8 Rules
# ==============================================================================

# 保留所有 JNI 綁定類別與原生方法，防止在 Release 混淆時被更名導致 UnsatisfiedLinkError 閃退
-keep class com.echowrite.app.EchoWriteCore { *; }
-keepclassmembers class com.echowrite.app.EchoWriteCore {
    public static <fields>;
    public static <methods>;
    native <methods>;
}

-keep class com.echowrite.app.EchoWriteIME { *; }
-keepclassmembers class com.echowrite.app.EchoWriteIME {
    native <methods>;
}

-keepclasseswithmembernames class * {
    native <methods>;
}

# 保留資料模型與列舉，防止 JSON 反序列化或反射時出錯
-keep class com.echowrite.app.EchoWriteStyle { *; }
-keep class com.echowrite.app.ModelProfile { *; }
-keep class com.echowrite.app.HistoryItem { *; }

# Material & AndroidX UI Components
-keep class com.google.android.material.** { *; }
-dontwarn com.google.android.material.**
