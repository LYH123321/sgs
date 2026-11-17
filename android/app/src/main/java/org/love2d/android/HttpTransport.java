/*
 * SGS Android — AI 传输层：OkHttp HTTPS 桥（文件队列方案）
 * GPL-3.0
 *
 * 零 native 改动，纯 Java + Lua 协作：
 *
 *   Lua线程写请求 → 文件 http_queue/<uuid>.req
 *              ↓ FileObserver 感知
 *   Java Handler 读文件 → OkHttp 执行 → 写 http_queue/<uuid>.res
 *              ↓
 *   Lua线程轮询 .res 文件 → 解析 JSON → 触发回调
 *
 * 文件路径为 GameActivity 传入的 saveDir/http_queue/，
 * 与 love.filesystem.getSaveDirectory() 对齐。
 */
package org.love2d.android;

import android.os.FileObserver;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;

import androidx.annotation.Keep;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;

import okhttp3.Call;
import okhttp3.Callback;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.ResponseBody;

/**
 * 纯静态工具类，HandlerThread 处理文件 IO 和网络。
 * 所有请求走文件队列，与 LÖVE SDL 线程完全解耦。
 */
public final class HttpTransport {
    private static final String TAG = "HttpTransport";
    private static final String QUEUE_DIR = "http_queue";
    private static final int DEFAULT_TIMEOUT_MS = 30000;

    private static HandlerThread sWorkerThread;
    private static Handler sWorker;
    private static File sQueueDir;
    private static final Map<String, Call> sPending = new HashMap<>();

    private static final OkHttpClient CLIENT = new OkHttpClient.Builder()
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(30, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
            .build();

    private HttpTransport() {}

    // ─── 初始化（GameActivity.onCreate 调用）─────────────────────

    @Keep
    public static synchronized void initialize(File saveDir) {
        if (sWorkerThread != null) return;

        sWorkerThread = new HandlerThread("HttpTransport");
        sWorkerThread.start();
        sWorker = new Handler(sWorkerThread.getLooper());

        sQueueDir = new File(saveDir, QUEUE_DIR);
        if (!sQueueDir.exists()) sQueueDir.mkdirs();

        // 监听 .req 文件创建
        sWorker.post(() -> {
            FileObserver observer = new FileObserver(sQueueDir.getAbsolutePath(),
                    FileObserver.CREATE) {
                @Override
                public void onEvent(int event, String path) {
                    if (path != null && path.endsWith(".req")) {
                        sWorker.post(() -> processRequest(path));
                    }
                }
            };
            observer.startWatching();
            Log.d(TAG, "Watching: " + sQueueDir.getAbsolutePath());
        });
    }

    // ─── Lua 入口（love.android.callJava 调用）────────────────────

    @Keep
    public static void enqueue(
            String callbackId,
            String method,
            String url,
            String headersJson,
            String body,
            int timeoutMs
    ) {
        if (sWorker == null) {
            Log.e(TAG, "enqueue before initialize");
            return;
        }
        sWorker.post(() -> {
            String json = buildReq(callbackId, method, url, headersJson, body, timeoutMs);
            try {
                writeFile(new File(sQueueDir, callbackId + ".req"), json);
            } catch (IOException e) {
                Log.e(TAG, "write req failed", e);
            }
        });
    }

    @Keep
    public static void cancel(String callbackId) {
        Call call = sPending.remove(callbackId);
        if (call != null) call.cancel();
        // 删除待处理文件
        File req = new File(sQueueDir, callbackId + ".req");
        File res = new File(sQueueDir, callbackId + ".res");
        req.delete();
        res.delete();
    }

    // ─── 文件处理 ─────────────────────────────────────────────────

    private static void processRequest(String filename) {
        File reqFile = new File(sQueueDir, filename);
        if (!reqFile.exists()) return;

        String content;
        try {
            content = readFile(reqFile);
        } catch (IOException e) {
            Log.e(TAG, "read req failed", e);
            reqFile.delete();
            return;
        }
        reqFile.delete();

        ReqParams p = parseReq(content);
        if (p == null || p.url == null || p.url.isEmpty()) {
            Log.w(TAG, "bad req: " + content.substring(0, Math.min(80, content.length())));
            String id = extractString(content, "callbackId");
            if (id != null) writeResult(id, 0, "", "parse error");
            return;
        }

        // 构建 OkHttp 请求
        Request.Builder b = new Request.Builder().url(p.url);
        if ("GET".equalsIgnoreCase(p.method)) {
            b.get();
        } else {
            b.post(RequestBody.create(
                p.body != null ? p.body : "",
                MediaType.parse("application/json; charset=utf-8")));
        }

        if (p.headers != null) {
            for (Map.Entry<String, String> h : p.headers.entrySet()) {
                b.addHeader(h.getKey(), h.getValue());
            }
        }
        if (p.headers == null || !p.headers.containsKey("Content-Type")) {
            b.addHeader("Content-Type", "application/json; charset=utf-8");
        }
        if (p.headers == null || !p.headers.containsKey("Accept")) {
            b.addHeader("Accept", "application/json");
        }

        Request request = b.build();
        int timeout = p.timeout > 0 ? p.timeout : DEFAULT_TIMEOUT_MS;
        OkHttpClient client = CLIENT.newBuilder()
                .connectTimeout(timeout, TimeUnit.MILLISECONDS)
                .readTimeout(timeout, TimeUnit.MILLISECONDS)
                .writeTimeout(timeout, TimeUnit.MILLISECONDS)
                .build();

        Call call = client.newCall(request);
        sPending.put(p.callbackId, call);

        call.enqueue(new Callback() {
            @Override
            public void onFailure(Call c, IOException e) {
                sPending.remove(p.callbackId);
                Log.e(TAG, "HTTP fail " + p.callbackId + ": " + e.getMessage());
                writeResult(p.callbackId, 0, "", e.getMessage());
            }

            @Override
            public void onResponse(Call c, Response response) throws IOException {
                sPending.remove(p.callbackId);
                int code = response.code();
                String respBody;
                try (ResponseBody rb = response.body()) {
                    respBody = rb != null ? rb.string() : "";
                }
                String err = response.isSuccessful() ? "" : "HTTP " + code;
                writeResult(p.callbackId, code, respBody, err);
            }
        });
    }

    // ─── 结果文件写入 ─────────────────────────────────────────────

    private static void writeResult(String callbackId, int code,
                                     String body, String error) {
        sWorker.post(() -> {
            String json = String.format(
                "{\"callbackId\":\"%s\",\"statusCode\":%d,\"body\":%s,\"error\":\"%s\"}",
                callbackId, code,
                jsonStr(body != null ? body : ""),
                escapeStr(error != null ? error : "")
            );
            try {
                writeFile(new File(sQueueDir, callbackId + ".res"), json);
            } catch (IOException e) {
                Log.e(TAG, "write res failed", e);
            }
        });
    }

    // ─── 文件 IO ─────────────────────────────────────────────────

    private static void writeFile(File f, String content) throws IOException {
        try (FileOutputStream fos = new FileOutputStream(f)) {
            fos.write(content.getBytes(StandardCharsets.UTF_8));
        }
    }

    private static String readFile(File f) throws IOException {
        byte[] buf = new byte[(int) f.length()];
        try (FileInputStream fis = new FileInputStream(f)) {
            int n = fis.read(buf);
            return new String(buf, 0, n, StandardCharsets.UTF_8);
        }
    }

    // ─── JSON 解析（手写，无第三方库）────────────────────────────

    private static String buildReq(String id, String method, String url,
                                    String headersJson, String body, int timeout) {
        return "{\"callbackId\":\"" + escapeStr(id) + "\"" +
               ",\"method\":\"" + escapeStr(method != null ? method : "POST") + "\"" +
               ",\"url\":\"" + escapeStr(url) + "\"" +
               ",\"headers\":" + (headersJson != null && !headersJson.isEmpty()
                                   ? headersJson : "{}") +
               ",\"body\":\"" + escapeStr(body != null ? body : "") + "\"" +
               ",\"timeout\":" + timeout + "}";
    }

    private static final class ReqParams {
        String callbackId = "";
        String method = "POST";
        String url = "";
        Map<String, String> headers;
        String body = "";
        int timeout = 0;
    }

    private static ReqParams parseReq(String json) {
        ReqParams p = new ReqParams();
        String id = extractString(json, "callbackId");
        if (id != null) p.callbackId = id;
        String method = extractString(json, "method");
        if (method != null) p.method = method;
        String url = extractString(json, "url");
        if (url == null) return null;
        p.url = url;
        String body = extractString(json, "body");
        p.body = body != null ? body : "";

        // timeout
        int ti = json.indexOf("\"timeout\"");
        if (ti >= 0) {
            int colon = json.indexOf(":", ti);
            int end = json.indexOf(",", colon);
            if (end < 0) end = json.indexOf("}", colon);
            try {
                p.timeout = (int) Double.parseDouble(json.substring(colon + 1, end).trim());
            } catch (Exception ignored) {}
        }

        // headers
        int hi = json.indexOf("\"headers\"");
        if (hi >= 0) {
            int colon = json.indexOf(":", hi);
            int brace = colon;
            // skip whitespace
            while (brace < json.length() && json.charAt(brace) != '{') brace++;
            int close = findClose(json, brace);
            if (brace < close) {
                p.headers = new HashMap<>();
                String hdr = json.substring(brace + 1, close);
                int i = 0;
                while (i < hdr.length()) {
                    int ks = hdr.indexOf("\"", i);
                    if (ks < 0) break;
                    int ke = hdr.indexOf("\"", ks + 1);
                    if (ke < 0) break;
                    String key = hdr.substring(ks + 1, ke);
                    int vs = hdr.indexOf("\"", ke + 1);
                    if (vs < 0) break;
                    int ve = hdr.indexOf("\"", vs + 1);
                    if (ve < 0) break;
                    p.headers.put(key, hdr.substring(vs + 1, ve));
                    i = ve + 1;
                }
            }
        }
        return p;
    }

    private static int findClose(String s, int open) {
        int depth = 0;
        for (int i = open; i < s.length(); i++) {
            if (s.charAt(i) == '{') depth++;
            else if (s.charAt(i) == '}') { depth--; if (depth == 0) return i; }
        }
        return s.length() - 1;
    }

    private static String extractString(String json, String key) {
        String qk = "\"" + key + "\"";
        int i = json.indexOf(qk);
        if (i < 0) return null;
        int colon = json.indexOf(":", i + qk.length());
        int vs = json.indexOf("\"", colon);
        if (vs < 0) return null;
        int ve = json.indexOf("\"", vs + 1);
        if (ve < 0) return null;
        return unescapeStr(json.substring(vs + 1, ve));
    }

    private static String jsonStr(String s) {
        return "\"" + escapeStr(s) + "\"";
    }

    private static String escapeStr(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"")
                .replace("\n", "\\n").replace("\r", "\\r");
    }

    private static String unescapeStr(String s) {
        return s.replace("\\\"", "\"").replace("\\\\", "\\")
                .replace("\\n", "\n").replace("\\r", "\r");
    }
}
