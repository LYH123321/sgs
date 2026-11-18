-- transport_android.lua 的离线测试：mock love.filesystem / love.timer，
-- 用手写的「假 Java」处理队列，验证 submit → poll → 解析 全链路。
--
-- 运行：cd sgs && lua5.1 tests/test_transport_android.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- ── mock love ────────────────────────────────────────────────────────

local store = {}          -- 虚拟文件系统：path -> content

love = {
  filesystem = {
    write = function(path, data)
      store[path] = data
      return true
    end,
    read = function(path)
      return store[path]
    end,
    remove = function(path)
      store[path] = nil
      return true
    end,
    getInfo = function(path)
      if store[path] then return { type = "file", size = #store[path] } end
      return nil
    end,
    getSaveDirectory = function() return "/mock/save" end,
  },
  timer = {
    getTime = function() return os.clock() end,
  },
  system = {
    getOS = function() return "Android" end,
  },
}

-- ── 被测模块 ─────────────────────────────────────────────────────────

local Json = require "src.core.json"
local AndroidTransport = require "src.ui.transport_android"

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail and ("  → " .. tostring(detail)) or ""))
  end
end

-- 把队列里最老的 .json 找出来（模拟 Java 轮询）
local function oldestDescriptor()
  local found
  for path in pairs(store) do
    if path:match("^http_queue/.*%.json$") then
      if not found or path < found then found = path end
    end
  end
  return found
end

-- 模拟 Java：读描述 + body，写回一个假响应
local function fakeJavaRespond(statusCode, responseBody, errorText)
  local descPath = oldestDescriptor()
  if not descPath then return false, "没有待处理的 .json" end
  local id = descPath:match("^http_queue/(.*)%.json$")
  local bodyPath = "http_queue/" .. id .. ".body"
  store[descPath] = nil
  store[bodyPath] = nil
  store["http_queue/" .. id .. ".res"] = Json.encode({
    statusCode = statusCode,
    body = responseBody or "",
    error = errorText or "",
  })
  return true
end

-- ── 1. 首次运行生成模板 ─────────────────────────────────────────────

print("\n[1] 首次运行应生成 ai_config.json 模板")
local t, err = AndroidTransport.fromConfig()
check("返回 nil transport", t == nil, t)
check("给出提示", type(err) == "string" and err:find("ai_config") ~= nil, err)
check("模板已写入", store["ai_config.json"] ~= nil)
check("模板是合法 JSON", pcall(Json.decode, store["ai_config.json"] or ""))

-- ── 2. 配置校验 ─────────────────────────────────────────────────────

print("\n[2] 空 api_key / model 应被拒绝")
store["ai_config.json"] = Json.encode({
  base_url = "https://api.example.com/v1",
  api_key = "",
  model = "",
  protocol = "chat",
})
local t2, err2 = AndroidTransport.fromConfig()
check("空 api_key 被拒", t2 == nil and err2:find("api_key") ~= nil, err2)

store["ai_config.json"] = Json.encode({
  base_url = "https://api.example.com/v1",
  api_key = "test-key",
  model = "",
})
local t3, err3 = AndroidTransport.fromConfig()
check("空 model 被拒", t3 == nil and err3:find("model") ~= nil, err3)

-- ── 3. 正常构造 ─────────────────────────────────────────────────────

print("\n[3] 完整配置应构造出 transport")
store["ai_config.json"] = Json.encode({
  base_url = "https://api.example.com/v1",
  api_key = "test-key",
  model = "gpt-4o",
  protocol = "chat",
  timeout = 90,
  temperature = 0.2,
  effort = "none",
  thinking = "off",
})
local tr, cerr = AndroidTransport.fromConfig()
check("构造成功", tr ~= nil, cerr)
check("URL 拼接正确",
  tr and tr.url == "https://api.example.com/v1/chat/completions", tr and tr.url)
check("model 传递", tr and tr.model == "gpt-4o", tr and tr.model)
check("temperature 传递", tr and tr.temperature == 0.2, tr and tr.temperature)
check("isAlive 为 true", tr and tr:isAlive() == true)

-- ── 4. submit 写文件 ────────────────────────────────────────────────

print("\n[4] submit 应写出 .body 和 .json")
store = {}
local okSubmit, sErr = tr:submit({ system = "sys", user = "usr" })
check("submit 返回 true", okSubmit == true, sErr)

local descPath = oldestDescriptor()
check("有 .json 描述文件", descPath ~= nil)

local id = descPath and descPath:match("^http_queue/(.*)%.json$")
check("有对应 .body 文件", id ~= nil and store["http_queue/" .. id .. ".body"] ~= nil)

if id then
  local body = Json.decode(store["http_queue/" .. id .. ".body"])
  check("body 含 messages", body and body.messages ~= nil)
  check("body 是 chat 结构", body and body.messages and #body.messages == 2)
  check("system 消息正确", body and body.messages[1].content == "sys")
  check("user 消息正确", body and body.messages[2].content == "usr")
  check("thinking=off 时禁用思维链",
    body and body.thinking and body.thinking.type == "disabled",
    body and body.thinking and body.thinking.type)

  local desc = Json.decode(store[descPath])
  check("描述里有 url", desc and desc.url ~= nil, desc and desc.url)
  check("描述里有 Authorization",
    desc and desc.headers and desc.headers["Authorization"] ~= nil)
  check("Authorization 带 Bearer 前缀",
    desc and desc.headers and desc.headers["Authorization"] ~= nil
      and desc.headers["Authorization"]:find("^Bea") ~= nil,
    desc and desc.headers and desc.headers["Authorization"])
  check("timeout 转成毫秒", desc and desc.timeout == 90000, desc and desc.timeout)
end

-- ── 5. poll 未完成时返回 nil ────────────────────────────────────────

print("\n[5] 结果未就绪时 poll 应返回 nil")
check("poll → nil", tr:poll() == nil)

-- ── 6. 正常响应 ─────────────────────────────────────────────────────

print("\n[6] 200 + 合法 chat 响应应解析出文本")
local chatResp = Json.encode({
  choices = { { message = { role = "assistant", content = "出【杀】" } } },
})
local okJava = fakeJavaRespond(200, chatResp, "")
check("假 Java 已响应", okJava == true)

local res = tr:poll()
check("poll 返回结果", res ~= nil)
check("ok = true", res and res.ok == true, res and res.err)
check("text 正确", res and res.text == "出【杀】", res and res.text)
check("结果文件已清理", store["http_queue/" .. tostring(id) .. ".res"] == nil)

-- ── 7. HTTP 错误 ────────────────────────────────────────────────────

print("\n[7] 4xx 应报错")
tr:submit({ system = "s", user = "u" })
fakeJavaRespond(401, '{"error":{"message":"bad key"}}', "HTTP 401")
local res2 = tr:poll()
check("ok = false", res2 and res2.ok == false)
check("错误里含状态码", res2 and res2.err and res2.err:find("401") ~= nil, res2 and res2.err)

-- ── 8. 温度自愈 ─────────────────────────────────────────────────────

print("\n[8] temperature 被拒时应自动改用允许值重试")
tr.temperature = 0.2
tr:submit({ system = "s", user = "u" })
fakeJavaRespond(400,
  '{"error":{"message":"invalid temperature: only 0.6 is allowed for this model"}}',
  "HTTP 400")
local res3 = tr:poll()
check("首次返回 nil（触发重试）", res3 == nil, res3 and res3.err)
check("temperature 已调整为 0.6", tr.temperature == 0.6, tr.temperature)
check("重试已发出", oldestDescriptor() ~= nil)
if oldestDescriptor() then
  fakeJavaRespond(200, chatResp, "")
  local res4 = tr:poll()
  check("重试后成功", res4 and res4.ok == true, res4 and res4.err)
end

-- ── 9. cancel ───────────────────────────────────────────────────────

print("\n[9] cancel 应丢弃迟到的结果")
tr:submit({ system = "s", user = "u" })
local idBefore = tr._id
tr:cancel()
check("cancel 后 _waiting=false", tr._waiting == false)
check("队列文件已删", store["http_queue/" .. tostring(idBefore) .. ".json"] == nil)

-- ── 10. responses 协议 ──────────────────────────────────────────────

print("\n[10] responses 协议应拼 /responses 并解析 output_text")
store["ai_config.json"] = Json.encode({
  base_url = "https://api.example.com/v1",
  api_key = "k",
  model = "o1",
  protocol = "responses",
  timeout = 90,
})
local tr5 = AndroidTransport.fromConfig()
check("URL 用 /responses", tr5 and tr5.url == "https://api.example.com/v1/responses",
  tr5 and tr5.url)
tr5:submit({ system = "s", user = "u" })
fakeJavaRespond(200, Json.encode({ output_text = "闪" }), "")
local res5 = tr5:poll()
check("解析 output_text", res5 and res5.ok and res5.text == "闪",
  res5 and (res5.err or res5.text))

-- ── 11. base_url 已带完整路径时不重复拼 ─────────────────────────────

print("\n[11] base_url 已是完整端点时不应再拼")
store["ai_config.json"] = Json.encode({
  base_url = "https://gw.example.com/v1/chat/completions",
  api_key = "k",
  model = "m",
  protocol = "chat",
})
local tr6 = AndroidTransport.fromConfig()
check("URL 原样保留",
  tr6 and tr6.url == "https://gw.example.com/v1/chat/completions", tr6 and tr6.url)

-- ── 汇总 ────────────────────────────────────────────────────────────

print(string.format("\n===== %d passed, %d failed =====", pass, fail))
os.exit(fail == 0 and 0 or 1)
