/*
 * SGS Android — AI transport: OkHttp HTTPS bridge (directory-poll based)
 * GPL-3.0
 *
 * Why this exists: LÖVE on Android ships without luasec, so socket.http /
 * ssl.https cannot talk to an HTTPS LLM endpoint. io.popen("curl") is also
 * impossible (no system curl, and app data dirs are mounted noexec).
 *
 * LÖVE for Android exposes no generic "call Java from Lua" bridge (only a
 * handful of hand-written JNI wrappers such as love.system.vibrate), so the
 * two sides communicate through the only thing they share for free:
 * love.filesystem's save directory.
 *
 *   Lua  : love.filesystem.write("http_queue/<id>.json", descriptor)
 *          love.filesystem.write("http_queue/<id>.body", requestBody)
 *   Java : this class polls that directory, runs the request with OkHttp and
 *          writes "http_queue/<id>.res"
 *   Lua  : polls love.filesystem.getInfo("<id>.res"), reads and removes it
 *
 * descriptor = {"method":"POST","url":"https://…","headers":{"K":"V"},"timeout":30000}
 * result     = {"statusCode":200,"body":"…","error":""}
 *
 * Everything runs off the SDL thread; the game never blocks on network I/O.
 */
package org.love2d.android;

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
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;

import okhttp3.Call;
import okhttp3.Callback;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.ResponseBody;

public final class HttpTransport {
    private static final String TAG = "SgsHttpTransport";

    /** Sub-directory of the LÖVE save dir used as the request/response queue. */
    public static final String QUEUE_DIR = "http_queue";

    private static final String EXT_DESC = ".json";
    private static final String EXT_BODY = ".body";
    private static final String EXT_RESULT = ".res";
    private static final String EXT_ERROR = ".err";

    private static final int DEFAULT_TIMEOUT_MS = 30000;
    private static final long POLL_INTERVAL_MS = 100;

    private static HandlerThread sWorkerThread;
    private static Handler sWorker;
    private static File sQueueDir;
    private static volatile boolean sPolling;

    private static final Map<String, Call> sPending = new ConcurrentHashMap<>();

    private static final OkHttpClient CLIENT = new OkHttpClient.Builder()
            .connectTimeout(DEFAULT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .readTimeout(DEFAULT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .writeTimeout(DEFAULT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .retryOnConnectionFailure(false)
            .build();

    private HttpTransport() {}

    // ── lifecycle ─────────────────────────────────────────────────────────

    /**
     * Start the queue poller.
     *
     * @param saveDir the LÖVE save directory, i.e. new File(getFilesDir(), "save")
     */
    @Keep
    public static synchronized void initialize(File saveDir) {
        if (sWorkerThread != null) return;

        sWorkerThread = new HandlerThread("SgsHttpTransport");
        sWorkerThread.start();
        sWorker = new Handler(sWorkerThread.getLooper());

        sQueueDir = new File(saveDir, QUEUE_DIR);
        if (!sQueueDir.exists() && !sQueueDir.mkdirs()) {
            Log.e(TAG, "cannot create queue dir: " + sQueueDir);
        }

        sPolling = true;
        sWorker.post(SCAN);

        Log.d(TAG, "ready, queue = " + sQueueDir.getAbsolutePath());
    }

    @Keep
    public static synchronized void shutdown() {
        sPolling = false;
        if (sWorker != null) sWorker.removeCallbacks(SCAN);
    }

    // ── directory scanner ─────────────────────────────────────────────────

    private static final Runnable SCAN = new Runnable() {
        @Override
        public void run() {
            if (!sPolling || sQueueDir == null) return;
            try {
                scanOnce();
            } catch (Throwable t) {
                Log.e(TAG, "scan failed", t);
            }
            if (sPolling) sWorker.postDelayed(this, POLL_INTERVAL_MS);
        }
    };

    private static void scanOnce() {
        File[] files = sQueueDir.listFiles();
        if (files == null) return;

        for (File f : files) {
            String name = f.getName();
            if (name.endsWith(EXT_DESC)) {
                String id = name.substring(0, name.length() - EXT_DESC.length());
                if (sPending.containsKey(id)) continue;          // already running
                if (new File(sQueueDir, id + EXT_RESULT).exists()) continue; // done
                handleDescriptor(id, f);
            }
        }
    }

    private static void handleDescriptor(String id, File descFile) {
        String desc;
        try {
            desc = readFile(descFile);
        } catch (IOException e) {
            Log.e(TAG, "cannot read " + descFile.getName(), e);
            //noinspection ResultOfMethodCallIgnored
            descFile.delete();
            writeResult(id, 0, "", "descriptor unreadable: " + describe(e));
            return;
        }
        //noinspection ResultOfMethodCallIgnored
        descFile.delete();

        String url = Json.str(desc, "url");
        String method = Json.str(desc, "method");
        if (url == null || url.isEmpty()) {
            writeResult(id, 0, "", "descriptor has no url");
            return;
        }
        int timeout = Json.integer(desc, "timeout", DEFAULT_TIMEOUT_MS);
        Map<String, String> headers = Json.flatObject(desc, "headers");

        String body = "";
        File bodyFile = new File(sQueueDir, id + EXT_BODY);
        if (bodyFile.exists()) {
            try {
                body = readFile(bodyFile);
            } catch (IOException e) {
                writeResult(id, 0, "", "body unreadable: " + describe(e));
                //noinspection ResultOfMethodCallIgnored
                bodyFile.delete();
                return;
            }
            //noinspection ResultOfMethodCallIgnored
            bodyFile.delete();
        }

        execute(id, method, url, headers, body, timeout);
    }

    // ── request execution (worker thread) ─────────────────────────────────

    private static void execute(String id, String method, String url,
                                Map<String, String> headers, String body, int timeout) {
        boolean get = "GET".equalsIgnoreCase(method);
        Request.Builder rb = new Request.Builder().url(url);

        if (get) {
            rb.get();
        } else {
            rb.post(RequestBody.create(body, MediaType.parse("application/json; charset=utf-8")));
        }

        for (Map.Entry<String, String> e : headers.entrySet()) {
            rb.header(e.getKey(), e.getValue());
        }
        if (!get && !headers.containsKey("Content-Type")) {
            rb.header("Content-Type", "application/json; charset=utf-8");
        }
        if (!headers.containsKey("Accept")) {
            rb.header("Accept", "application/json");
        }

        OkHttpClient client = CLIENT.newBuilder()
                .connectTimeout(timeout, TimeUnit.MILLISECONDS)
                .readTimeout(timeout, TimeUnit.MILLISECONDS)
                .writeTimeout(timeout, TimeUnit.MILLISECONDS)
                .build();

        Call call = client.newCall(rb.build());
        sPending.put(id, call);
        Log.d(TAG, "→ " + (get ? "GET" : "POST") + " " + url + "  [" + id + "]");

        call.enqueue(new Callback() {
            @Override
            public void onFailure(Call c, IOException e) {
                sPending.remove(id);
                Log.w(TAG, "← network error [" + id + "] " + describe(e));
                writeResult(id, 0, "", describe(e));
            }

            @Override
            public void onResponse(Call c, Response response) {
                sPending.remove(id);
                String text = "";
                try (ResponseBody rb2 = response.body()) {
                    if (rb2 != null) text = rb2.string();
                } catch (IOException e) {
                    writeResult(id, 0, "", describe(e));
                    return;
                }
                int code = response.code();
                Log.d(TAG, "← HTTP " + code + " [" + id + "] " + text.length() + " bytes");
                writeResult(id, code, text, response.isSuccessful() ? "" : "HTTP " + code);
            }
        });
    }

    /** Cancel an in-flight request and drop its queue files. */
    @Keep
    public static void cancel(String id) {
        if (id == null || sQueueDir == null) return;
        Call call = sPending.remove(id);
        if (call != null) call.cancel();
        for (String ext : new String[]{EXT_DESC, EXT_BODY, EXT_RESULT}) {
            //noinspection ResultOfMethodCallIgnored
            new File(sQueueDir, id + ext).delete();
        }
    }

    // ── result file ───────────────────────────────────────────────────────

    private static void writeResult(String id, int code, String body, String error) {
        Handler w = sWorker;
        if (w == null) return;
        w.post(() -> {
            String json = "{\"statusCode\":" + code
                    + ",\"body\":" + Json.quote(body == null ? "" : body)
                    + ",\"error\":" + Json.quote(error == null ? "" : error)
                    + "}";
            File res = new File(sQueueDir, id + EXT_RESULT);
            try {
                writeFile(res, json);
            } catch (IOException e) {
                Log.e(TAG, "cannot write result for " + id, e);
            }
        });
    }

    private static String describe(Exception e) {
        String msg = e.getMessage();
        return (msg == null || msg.isEmpty()) ? e.getClass().getSimpleName() : msg;
    }

    // ── file helpers ──────────────────────────────────────────────────────

    private static void writeFile(File f, String content) throws IOException {
        try (FileOutputStream fos = new FileOutputStream(f)) {
            fos.write(content.getBytes(StandardCharsets.UTF_8));
        }
    }

    private static String readFile(File f) throws IOException {
        byte[] buf = new byte[(int) f.length()];
        try (FileInputStream fis = new FileInputStream(f)) {
            int n = fis.read(buf);
            return new String(buf, 0, Math.max(n, 0), StandardCharsets.UTF_8);
        }
    }

    // ── minimal JSON reader (no third-party dependency) ───────────────────

    static final class Json {
        private Json() {}

        static String quote(String s) {
            if (s == null) return "\"\"";
            StringBuilder sb = new StringBuilder(s.length() + 16).append('"');
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                switch (c) {
                    case '"': sb.append("\\\""); break;
                    case '\\': sb.append("\\\\"); break;
                    case '\n': sb.append("\\n"); break;
                    case '\r': sb.append("\\r"); break;
                    case '\t': sb.append("\\t"); break;
                    default:
                        if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                        else sb.append(c);
                }
            }
            return sb.append('"').toString();
        }

        /** Reads a top-level string value: {"key":"value"} */
        static String str(String json, String key) {
            int v = valueStart(json, key);
            if (v < 0 || v >= json.length() || json.charAt(v) != '"') return null;
            return readString(json, v);
        }

        /** Reads a top-level number value. */
        static int integer(String json, String key, int fallback) {
            int v = valueStart(json, key);
            if (v < 0) return fallback;
            int p = v;
            while (p < json.length() && "-+.0123456789eE".indexOf(json.charAt(p)) >= 0) p++;
            try {
                return (int) Double.parseDouble(json.substring(v, p));
            } catch (RuntimeException e) {
                return fallback;
            }
        }

        /** Reads a flat {"K":"V", …} object value. */
        static Map<String, String> flatObject(String json, String key) {
            Map<String, String> out = new LinkedHashMap<>();
            int v = valueStart(json, key);
            if (v < 0 || v >= json.length() || json.charAt(v) != '{') return out;

            int p = v + 1;
            while (p < json.length()) {
                while (p < json.length() && json.charAt(p) != '"' && json.charAt(p) != '}') p++;
                if (p >= json.length() || json.charAt(p) == '}') break;

                String k = readString(json, p);
                if (k == null) break;
                p = skipString(json, p);
                while (p < json.length() && json.charAt(p) != ':') p++;
                p++;
                while (p < json.length() && Character.isWhitespace(json.charAt(p))) p++;
                if (p >= json.length()) break;

                String val;
                if (json.charAt(p) == '"') {
                    val = readString(json, p);
                    p = skipString(json, p);
                } else {
                    int s = p;
                    while (p < json.length() && json.charAt(p) != ',' && json.charAt(p) != '}') p++;
                    val = json.substring(s, p).trim();
                }
                if (val != null) out.put(k, val);
            }
            return out;
        }

        // ── internals ──

        private static int valueStart(String json, String key) {
            if (json == null) return -1;
            String needle = "\"" + key + "\"";
            int i = json.indexOf(needle);
            if (i < 0) return -1;
            int colon = json.indexOf(':', i + needle.length());
            if (colon < 0) return -1;
            int p = colon + 1;
            while (p < json.length() && Character.isWhitespace(json.charAt(p))) p++;
            return p < json.length() ? p : -1;
        }

        private static String readString(String json, int quotePos) {
            StringBuilder sb = new StringBuilder();
            int p = quotePos + 1;
            while (p < json.length()) {
                char c = json.charAt(p);
                if (c == '\\' && p + 1 < json.length()) {
                    char n = json.charAt(p + 1);
                    switch (n) {
                        case 'n': sb.append('\n'); break;
                        case 'r': sb.append('\r'); break;
                        case 't': sb.append('\t'); break;
                        case 'b': sb.append('\b'); break;
                        case 'f': sb.append('\f'); break;
                        case 'u':
                            if (p + 5 < json.length()) {
                                try {
                                    sb.append((char) Integer.parseInt(json.substring(p + 2, p + 6), 16));
                                    p += 4;
                                } catch (NumberFormatException ignored) { }
                            }
                            break;
                        default: sb.append(n);
                    }
                    p += 2;
                    continue;
                }
                if (c == '"') return sb.toString();
                sb.append(c);
                p++;
            }
            return sb.toString();
        }

        private static int skipString(String json, int quotePos) {
            int p = quotePos + 1;
            while (p < json.length()) {
                char c = json.charAt(p);
                if (c == '\\') { p += 2; continue; }
                if (c == '"') return p + 1;
                p++;
            }
            return p;
        }
    }
}
