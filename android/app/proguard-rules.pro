# SGS Android Port ProGuard Rules

# Keep custom Java classes (called from Lua via love.android)
-keep class org.love2d.android.** { *; }

# OkHttp
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }
-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# LÖVE / SDL native libs
-keep class org.libsdl.app.** { *; }

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# AndroidX
-keep class androidx.** { *; }
-dontwarn androidx.**
