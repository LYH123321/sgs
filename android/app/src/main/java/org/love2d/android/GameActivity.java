/*
 * Copyright (c) 2006-2024 LOVE Development Team
 * Modifications for SGS Android port: GPL-3.0
 *
 * Licensed under the same license as the original LOVE Android project.
 */

package org.love2d.android;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.res.AssetManager;
import android.graphics.Rect;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.DisplayCutout;
import android.view.WindowManager;

import androidx.annotation.Keep;
import androidx.core.app.ActivityCompat;

import org.libsdl.app.SDLActivity;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;

/**
 * SGS Android port — based on love-android-sdl2 GameActivity.
 * Adds HttpTransport initialization for AI HTTPS via OkHttp file queue.
 */
public class GameActivity extends SDLActivity {
    private static final String TAG = "GameActivity";
    public static final int RECORD_AUDIO_REQUEST_CODE = 3;

    protected Vibrator vibrator;
    protected boolean shortEdgesMode;
    protected final int[] recordAudioRequestDummy = new int[1];
    private Uri delayedUri = null;
    private String[] args;
    private boolean isFused;

    private static native void nativeSetDefaultStreamValues(int sampleRate, int framesPerBurst);

    @Override
    protected String getMainSharedObject() {
        String[] libs = getLibraries();
        return "lib" + libs[libs.length - 1] + ".so";
    }

    @Override
    protected String[] getLibraries() {
        return new String[]{
            "c++_shared", "SDL3", "oboe", "openal",
            "luajit", "liblove", "love",
        };
    }

    @Override
    protected String[] getArguments() {
        return args;
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        Log.d(TAG, "SGS Android: onCreate");
        isFused = hasEmbeddedGame();
        args = new String[0];

        if (checkCallingOrSelfPermission(Manifest.permission.VIBRATE)
                == PackageManager.PERMISSION_GRANTED) {
            vibrator = (Vibrator) getSystemService(Context.VIBRATOR_SERVICE);
        }

        Intent intent = getIntent();
        handleIntent(intent, true);
        intent.setData(null);

        super.onCreate(savedInstanceState);

        if (mBrokenLibraries) return;

        nativeSetDefaultStreamValues(getAudioFreq(), getAudioSMP());

        if (android.os.Build.VERSION.SDK_INT >= 28) {
            WindowManager.LayoutParams attr = getWindow().getAttributes();
            attr.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_NEVER;
            shortEdgesMode = false;
        }

        // ── 初始化 SGS HttpTransport 文件队列 ──────────────────────
        // love.filesystem.getSaveDirectory() 在 Java 层对应:
        //   /data/data/com.sgs.game/files/
        File saveDir = new File(getFilesDir(), "sgs_save");
        if (!saveDir.exists()) saveDir.mkdirs();
        HttpTransport.initialize(saveDir);
        Log.d(TAG, "HttpTransport initialized: " + saveDir.getAbsolutePath());

        if (delayedUri != null) {
            sendUriAsDroppedFile(delayedUri);
            delayedUri = null;
        }
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        handleIntent(intent, false);
    }

    @Override
    protected void onDestroy() {
        if (vibrator != null) vibrator.cancel();
        super.onDestroy();
    }

    @Override
    protected void onPause() {
        if (vibrator != null) vibrator.cancel();
        super.onPause();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions,
                                            int[] grantResults) {
        if (grantResults.length > 0 && requestCode == RECORD_AUDIO_REQUEST_CODE) {
            synchronized (recordAudioRequestDummy) {
                recordAudioRequestDummy[0] = grantResults[0];
                recordAudioRequestDummy.notify();
            }
        } else {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        }
    }

    // ── LÖVE 原生方法接口（love.* 调用）────────────────────────────

    @Keep
    public boolean hasEmbeddedGame() {
        AssetManager am = getAssets();
        try {
            am.open("main.lua");
            return true;
        } catch (IOException e) {
            try {
                am.open("game.love");
                return true;
            } catch (IOException e2) {
                return false;
            }
        }
    }

    @Keep
    public void vibrate(double seconds) {
        if (vibrator != null) {
            long duration = (long) (seconds * 1000.0);
            if (android.os.Build.VERSION.SDK_INT >= 26) {
                vibrator.vibrate(VibrationEffect.createOneShot(
                    duration, VibrationEffect.DEFAULT_AMPLITUDE));
            } else {
                vibrator.vibrate(duration);
            }
        }
    }

    @Keep
    public boolean hasBackgroundMusic() {
        AudioManager am = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        return am != null && am.isMusicActive();
    }

    @Keep
    public float getDPIScale() {
        return getResources().getDisplayMetrics().density;
    }

    @Keep
    public Rect getSafeArea() {
        if (android.os.Build.VERSION.SDK_INT >= 28) {
            DisplayCutout cutout = getWindow().getDecorView()
                .getRootWindowInsets().getDisplayCutout();
            if (cutout != null) {
                Rect rect = new Rect();
                rect.set(cutout.getSafeInsetLeft(), cutout.getSafeInsetTop(),
                    cutout.getSafeInsetRight(), cutout.getSafeInsetBottom());
                return rect;
            }
        }
        return null;
    }

    @Keep
    public String getCRequirePath() {
        ApplicationInfo appInfo = getApplicationInfo();
        if (isNativeLibsExtracted()) {
            return appInfo.nativeLibraryDir + "/?.so";
        }
        String abi = android.os.Build.SUPPORTED_ABIS[0];
        return appInfo.sourceDir + "!/lib/" + abi + "/?.so";
    }

    @Keep
    public void setImmersiveMode(boolean enable) {
        if (android.os.Build.VERSION.SDK_INT >= 28) {
            WindowManager.LayoutParams attr = getWindow().getAttributes();
            attr.layoutInDisplayCutoutMode = enable
                ? WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                : WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_NEVER;
        }
        shortEdgesMode = enable;
    }

    @Keep
    public boolean getImmersiveMode() {
        return shortEdgesMode;
    }

    @Keep
    public boolean hasRecordAudioPermission() {
        return ActivityCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED;
    }

    @Keep
    public void requestRecordAudioPermission() {
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
                == PackageManager.PERMISSION_GRANTED) return;

        synchronized (recordAudioRequestDummy) {
            ActivityCompat.requestPermissions(this,
                new String[]{Manifest.permission.RECORD_AUDIO},
                RECORD_AUDIO_REQUEST_CODE);
            try { recordAudioRequestDummy.wait(); } catch (InterruptedException e) {}
        }
    }

    public int getAudioSMP() {
        AudioManager a = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        int b = a != null
            ? Integer.parseInt(a.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER))
            : 0;
        return b > 0 ? b : 256;
    }

    public int getAudioFreq() {
        AudioManager a = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        int b = a != null
            ? Integer.parseInt(a.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE))
            : 0;
        return b > 0 ? b : 44100;
    }

    public boolean isNativeLibsExtracted() {
        return (getApplicationInfo().flags & ApplicationInfo.FLAG_EXTRACT_NATIVE_LIBS) != 0;
    }

    public void sendUriAsDroppedFile(Uri uri) {
        SDLActivity.onNativeDropFile(uri.toString());
    }

    // ── SGS AI 传输层：Java → Lua 入口 ─────────────────────────────
    // Lua 通过 love.android.callJava("GameActivity", "httpRequest",
    //   callbackId, method, url, headersJson, body, timeoutMs)
    // 调用本方法，把请求写入文件队列。

    /**
     * 把 HTTP 请求加入文件队列。
     * Lua 线程轮询队列目录获取结果，完全异步不阻塞主线程。
     *
     * @param callbackId  Lua 侧 UUID（用于匹配请求和结果）
     * @param method      "POST" 或 "GET"
     * @param url         完整请求 URL
     * @param headersJson JSON 对象 {"Key":"Value"}
     * @param body        请求体字符串
     * @param timeoutMs   超时毫秒，≤0 使用默认 30000
     */
    @Keep
    public void httpRequest(
            String callbackId,
            String method,
            String url,
            String headersJson,
            String body,
            int timeoutMs
    ) {
        HttpTransport.enqueue(callbackId, method, url, headersJson, body, timeoutMs);
    }

    // ── Intent 处理 ───────────────────────────────────────────────

    private void handleIntent(Intent intent, boolean onCreate) {
        Uri game = intent.getData();
        if (game == null) return;

        if (onCreate) {
            if (isFused) {
                delayedUri = game;
            } else {
                processOpenGame(game);
            }
        } else {
            sendUriAsDroppedFile(game);
        }
    }

    private void processOpenGame(Uri game) {
        String scheme = game.getScheme();
        if ("content".equals(scheme)) {
            args = new String[]{game.toString()};
        } else if ("file".equals(scheme)) {
            args = new String[]{game.getPath()};
        }
    }
}
