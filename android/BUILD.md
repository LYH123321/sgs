# SGS Android 构建指南

## 环境要求

| 组件 | 版本 | 说明 |
|------|------|------|
| JDK | 17 或 21 | Android Gradle Plugin 8.x 需要 JDK 17+ |
| Android SDK | API 35 | compileSdk=35, targetSdk=35, minSdk=24 |
| Gradle | 9.6 | 通过 gradle-wrapper.properties 自动下载 |
| Android NDK | r26+ | 编译 SDL3 / LÖVE native 库 |

**不需要 Ubuntu/Linux。** Windows、macOS、Linux 均可构建，全链路 Java + Gradle 跨平台。

---

## 快速构建（有 Android Studio 的情况）

```bash
cd android/

# Debug 构建（直接安装测试用）
./gradlew assembleDebug

# Release 构建（需要签名，见下文）
./gradlew assembleRelease
```

APK 输出路径：
```
android/app/build/outputs/apk/debug/app-debug.apk
android/app/build/outputs/apk/release/app-release.apk
```

---

## 命令行构建（无 Android Studio）

### 1. 安装 Android SDK Command Line Tools

```bash
# 下载（约 150MB，Google 可能需要科学上网）
mkdir -p ~/android-sdk/cmdline-tools
cd ~/android-sdk/cmdline-tools
# 从 https://developer.android.com/studio#command-tools 下载最新 zip
unzip commandlinetools-*.zip
mv cmdline-tools latest

# 设置环境变量
export ANDROID_HOME=~/android-sdk
export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$PATH
```

### 2. 安装 SDK 组件

```bash
sdkmanager "platforms;android-35" \
           "build-tools;35.0.0" \
           "platform-tools" \
           "ndk;26.1.10909125"
```

### 3. 接受许可协议

```bash
sdkmanager --licenses
```

### 4. 配置 local.properties

```bash
echo "sdk.dir=$ANDROID_HOME" > android/local.properties
```

### 5. 构建

```bash
cd android
./gradlew assembleRelease
```

---

## 签名配置

### 生成 keystore（仅首次）

```bash
keytool -genkey -v \
  -keystore android/keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias sgs \
  -dname "CN=SGS, OU=Game, O=SGS, L=Beijing, ST=Beijing, C=CN" \
  -storepass android -keypass android
```

### 环境变量方式（推荐，密钥不进代码）

```bash
export KEYSTORE_PASSWORD=你的密码
export KEY_ALIAS=你的别名
export KEY_PASSWORD=你的密钥密码
./gradlew assembleRelease
```

> `keystore.jks` 已在 build.gradle.kts 中引用。如果不存在，构建时会生成 debug 签名。

---

## SGS 游戏代码接入

Android 壳通过 assets/game/ 目录加载 LÖVE 游戏。

### 方式 A：.love 文件（推荐，体积小）

```bash
# 1. 把 sgs/ 打包成 .love
cd sgs/
# 创建临时目录，拷贝游戏文件（排除 Android 相关文件）
mkdir -p ../build_love
rsync -a --exclude='android' --exclude='.git' ./ ../build_love/
cd ../build_love && zip -r ../android/app/src/main/assets/game.love . && cd ..

# 2. Android 壳在启动时自动检测 assets/game.love 并加载
```

### 方式 B：散文件（调试方便）

```bash
# 直接把 sgs 源码复制到 assets/game/
cp -r sgs/* android/app/src/main/assets/game/
# GameActivity 检测到 main.lua 存在时优先加载散文件
```

### 方式 C：外部 .love 文件（不内置）

```bash
# 构建时不打包任何游戏代码，运行时通过 Intent 打开外部 .love
# 在 AndroidManifest 中已声明 .love 文件的 intent-filter
./gradlew assembleRelease
# 然后手动 adb push 一个 .love 文件到手机，点击打开
```

---

## AI 传输层配置

首次启动时，Android 壳会自动在保存目录创建 `ai_config.json` 模板：

```json
{
  "provider": "openai",
  "base_url": "https://api.openai.com/v1",
  "api_key": "sk-...",
  "model": "gpt-4o",
  "protocol": "chat",
  "timeout": 30000,
  "temperature": 0.7,
  "effort": "none",
  "reasoning": true
}
```

编辑此文件填入有效的 API 密钥和模型名即可使用 AI 功能。

### 各平台配置示例

| 平台 | base_url | protocol | model |
|------|----------|----------|-------|
| OpenAI | `https://api.openai.com/v1` | `chat` | `gpt-4o` |
| Azure OpenAI | `https://你的资源.openai.azure.com/openai/deployments/部署名` | `chat` | `gpt-4o` |
| DeepSeek | `https://api.deepseek.com/v1` | `chat` | `deepseek-chat` |
| Ollama（本地） | `http://localhost:11434/v1` | `chat` | `llama3` |
| Responses API | `https://api.openai.com/v1` | `responses` | `o1` |

---

## 文件结构

```
android/
├── settings.gradle.kts         # Gradle 项目设置
├── build.gradle.kts            # 根级构建配置
├── gradle.properties           # Gradle 属性
├── gradlew                     # Gradle 启动脚本 (Linux/macOS)
├── gradlew.bat                 # Gradle 启动脚本 (Windows)
├── gradle/wrapper/
│   └── gradle-wrapper.properties
├── keystore.jks                # 签名密钥（自行生成）
├── local.properties            # SDK 路径（自行创建，不入 git）
├── app/
│   ├── build.gradle.kts        # 应用模块配置
│   ├── proguard-rules.pro      # ProGuard 混淆规则
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── assets/
│       │   ├── game.love       # 打包的 LÖVE 游戏（方式 A）
│       │   └── game/           # 或散文件（方式 B）
│       ├── java/org/love2d/android/
│       │   ├── GameActivity.java
│       │   ├── HttpTransport.java
│       │   └── IntentReceiverActivity.java
│       └── res/
│           └── values/
│               └── strings.xml
├── transport_android.lua       # Lua 侧 AI 传输层（放到 sgs/src/ui/ 或 sgs/src/core/ai/）
└── BUILD.md                    # 本文件
```

---

## 已知限制

1. **HttpTransport 使用文件队列**：Lua 线程通过轮询 `.res` 文件获取结果，轮询间隔 ~50ms。对于 1~3 秒的 LLM 请求，这个延迟可忽略。

2. **native `.so` 未修改**：SDL3/liblove 使用官方 love-android-sdl2 预编译版本。如果需要修改 native 行为（例如 JNI 回调），需要重新编译 SDL3 + LÖVE native 源码。

3. **AI 请求在 Java 线程执行**：OkHttp 在 `HttpTransport-Worker` HandlerThread 中异步执行，不阻塞 SDL 主线程。

4. **素材协议**：CC BY-NC-ND 素材不可用于任何商业用途（含广告/内购）。上架商店需替换美术资源。

5. **GPL-3.0 合规**：移植代码、Java 桥、Lua 胶水代码均需以 GPL-3.0 发布。

---

## 故障排查

### GFW 封锁 Google SDK

```bash
# 使用国内镜像
export SDK_TEST_BASE_URL=https://mirrors.cloud.tencent.com/AndroidSDK
sdkmanager "platforms;android-35" ...
```

或使用 Android Studio（内置下载器通常能自动切换镜像）。

### gradlew 权限问题

```bash
chmod +x android/gradlew
```

### NDK 版本不匹配

```bash
# 查看已安装版本
sdkmanager --list_installed

# 指定版本
sdkmanager "ndk;26.1.10909125"
# 然后在 build.gradle.kts 中指定 ndkVersion = "26.1.10909125"
```

### OkHttp 混淆问题

`proguard-rules.pro` 中已包含 OkHttp 保留规则。如果 release 构建后 AI 功能崩溃，检查：
1. `HttpTransport.java` 是否被 ProGuard 保留（`-keep class org.love2d.android.**`）
2. OkHttp 内部类是否完整保留

---

## 一键构建脚本

Linux/macOS：

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "=== SGS Android 一键构建 ==="

# 1. 打包 .love
echo "[1/4] 打包游戏代码..."
cd ../sgs
rm -f ../android/app/src/main/assets/game.love
zip -r ../android/app/src/main/assets/game.love \
  . -x "android/*" ".git/*" "tests/*" "docs/*"
cd ../android

# 2. 构建 Release APK
echo "[2/4] 构建 Release APK..."
./gradlew assembleRelease

# 3. 复制 APK 到根目录
echo "[3/4] 复制 APK..."
cp app/build/outputs/apk/release/app-release.apk ../SGS-Android.apk

echo "[4/4] 完成！"
echo "APK: android/app/build/outputs/apk/release/app-release.apk"
ls -lh ../SGS-Android.apk
```

Windows：

```bat
@echo off
echo === SGS Android 一键构建 ===

echo [1/4] 打包游戏代码...
cd ..\sgs
if exist ..\android\app\src\main\assets\game.love del ..\android\app\src\main\assets\game.love
powershell -Command "Compress-Archive -Path * -DestinationPath ..\android\app\src\main\assets\game.love -Force" 
cd ..\android

echo [2/4] 构建 Release APK...
call gradlew.bat assembleRelease

echo [3/4] 复制 APK...
copy app\build\outputs\apk\release\app-release.apk ..\SGS-Android.apk

echo [4/4] 完成！
dir ..\SGS-Android.apk
```
