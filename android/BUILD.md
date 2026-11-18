# SGS Android 版

把 SGS（三国杀）包装成可安装的安卓 APK。壳基于
[love2d/love-android](https://github.com/love2d/love-android)（zlib 许可），
游戏本体打包成 `game.love` 内嵌。

## 目录结构

```
android/
├── app/
│   ├── build.gradle                       # 应用模块（含 SGS 的 OkHttp 依赖）
│   └── src/
│       ├── embed/assets/game.love         # 内嵌的游戏包（26 MB）
│       ├── main/java/org/love2d/android/
│       │   ├── GameActivity.java          # 上游壳 + SGS 初始化钩子
│       │   ├── HttpTransport.java         # 【新增】OkHttp HTTPS 传输层
│       │   └── IntentReceiverActivity.java
│       └── main/cpp/                      # CMake 入口（native 源码见下）
├── gradle.properties                      # 应用名 / 包名 / 横屏
└── gradlew
```

`app/src/main/cpp/love/` 和 `app/src/main/cpp/megasource/`（约 420 MB 的
LÖVE + SDL3 源码）**不入库**，由构建前拉取：

```bash
cd android/app/src/main/cpp
git clone --filter=blob:none https://github.com/love2d/love.git love
git -C love checkout ef388d4371f5932491fbdcdd65ac7240e11c31a8
git clone https://github.com/love2d/megasource.git megasource
git -C megasource checkout 14937cda16712142223af85301d261153a35719b
```

## 构建

CI（`.github/workflows/build-android.yml`）在每次推送 `android` 分支时自动
构建，产物在 Actions 页面的 `sgs-android-debug` artifact 里。

本地构建：

```bash
cd android
./gradlew assembleEmbedRecordDebug
# 产物：app/build/outputs/apk/embedRecord/debug/app-embed-record-debug.apk
```

首次构建需要 **NDK 30.0.16248370**、**CMake ≥ 3.25**、**JDK 17**，
并完整编译 SDL3 + LÖVE + LuaJIT，干净环境下 20~40 分钟。

## AI 功能怎么走 HTTPS

这是整个移植里唯一真正需要动代码的地方。

**问题**：LÖVE 的 LuaSocket 在安卓上不带 luasec，`ssl.https` 直接
require 失败；`io.popen("curl")` 也不可行——安卓没有系统 curl，且应用
数据目录是 noexec。

**方案**：把 HTTPS 交给 Java 层的 OkHttp，Lua 与 Java 通过存档目录做文件
队列通信。之所以不用 JNI，是因为 LÖVE for Android 没有通用的「Lua 调
Java」桥（只有 `love.system.vibrate` 这类几个手写包装）。

```
Lua  → love.filesystem.write("http_queue/<id>.json")   {"method","url","headers","timeout"}
     → love.filesystem.write("http_queue/<id>.body")   请求体
Java → HttpTransport 每 100ms 扫目录 → OkHttp 发请求
     → 写 "http_queue/<id>.res"  {"statusCode","body","error"}
Lua  → 每帧 getInfo 检查 .res → 读到即删 → 解析
```

代码位置：
- `android/.../HttpTransport.java` — 扫描队列、执行请求、写回结果
- `src/ui/transport_android.lua` — Lua 侧实现，接口与桌面版
  `ui/ai_transport.lua` 的 `Threaded` 完全一致（`submit` / `poll` /
  `cancel` / `isAlive`）
- `src/ui/ai_transport.lua` 的 `fromEnv` 在检测到 `love.system.getOS()
  == "Android"` 时自动切到它

### 配置

安卓上没有 `SGS_AI_*` 环境变量。首次启动会在存档目录生成
`ai_config.json`，填好后重启：

```json
{
  "base_url": "https://api.openai.com/v1",
  "api_key": "sk-...",
  "model": "gpt-4o",
  "protocol": "chat",
  "timeout": 90,
  "temperature": 0.2,
  "effort": "none",
  "thinking": "off"
}
```

存档目录：`/data/data/com.sgs.game/files/save/ai_config.json`
（`love.filesystem.getSaveDirectory()`）。用 adb 取出编辑：

```bash
adb shell run-as com.sgs.game cat files/save/ai_config.json
```

支持 `chat`（OpenAI/DeepSeek/Ollama 等）和 `responses`（o1/hy3）两种协议。

## 已经做好的适配

| 项 | 处理 |
|---|---|
| 横屏 | `gradle.properties` 里 `app.orientation=landscape` |
| 缩放 | 游戏自带 `scale.lua` 常量级缩放，1130×650 设计稿在手机横屏自适应 |
| 触摸 | SDL 把触摸自动映射成鼠标事件 |
| 刘海屏 | 上游 `getSafeArea()` 已实现 |
| 返回键 | 映射成 `escape`（LÖVE 默认行为） |
| 震动 | `love.system.vibrate` 走 Java |

## 已知限制

1. **未在 CI 上验证过完整构建**——首次跑通前可能需要微调 NDK/CMake 版本。
2. **AI 请求有约 100ms~200ms 的队列延迟**——相对 LLM 本身 1~3 秒可忽略。
3. **素材协议**：`assets/` 下的三国杀美术是 CC BY-NC-ND，禁止商用（含
   广告/内购）。自己装着玩没问题，上架商店必须先换掉素材。
4. **GPL-3.0**：游戏本体是 GPL-3.0，衍生的壳代码与 Lua 胶水同样需以
   GPL-3.0 发布。

## 测试

Lua 侧传输层有离线单测（mock 掉 love.filesystem）：

```bash
cd ..        # 回到 sgs 仓库根目录
lua5.1 tests/test_transport_android.lua
# ===== 40 passed, 0 failed =====
```
