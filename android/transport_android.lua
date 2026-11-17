-- AI 传输层 Android 实现：Lua love.thread + Java OkHttp 文件队列
--
-- 工作原理：
--   1. 调用方（AI 引擎）通过 fromEnv() 获取本 Transport 实例
--   2. submit(prompt) → 序列化 JSON 请求 → 写文件 http_queue/<uuid>.req
--   3. love.android.callJava("GameActivity", "httpRequest", id, method, url, headersJson, body, timeoutMs)
--   4. Java 侧 OkHttp 处理，结果写 http_queue/<uuid>.res
--   5. Lua 每帧（或 love.thread 中）轮询 .res 文件 → 解析 JSON → 返回结果
--
-- 设计要点：
--   - 零 native 改动：不修改任何 .so，纯 Java + Lua 协作
--   - 主线程不阻塞：HTTP 在 Java 线程池异步执行，Lua 轮询文件系统
--   - 跨线程安全：文件 IO 是唯一通信通道，天然线程安全
--   - 配置走文件：不依赖 SGS_AI_* 环境变量（Android 不存在），改读 ai_config.json
--
-- 依赖：
--   love.filesystem.getSaveDirectory() 对应 Java 的 getFilesDir() + "/sgs_save/"
--   http_queue/ 子目录由 Java HttpTransport 自动创建
--   ai_config.json 在保存目录，格式见本文件 fromConfig()
--
-- 使用方法（替代原来的 fromEnv）：
--   local AndroidTransport = require("src.ui.transport_android")
--   local transport = AndroidTransport.fromConfig()  -- 读 ai_config.json
--   transport:submit(prompt)                        -- 提交请求
--   local result = transport:poll()                 -- 轮询结果（nil=未完成）
--   -- result = {ok=true, text="..."} 或 {ok=false, err="..."}

local class = require "src.class"
local Json = require "src.core.json"
local TransportLib = require "src.core.ai.transport"

-- ─── 配置读取（替代 SGS_AI_* 环境变量）─────────────────────────

local function loadConfig()
  local configPath = "ai_config.json"
  local configText = love.filesystem.read(configPath)
  if not configText then
    -- 首次启动：写入模板并返回 nil
    local template = Json.encode({
      provider     = "openai",          -- openai / azure / ollama / custom
      base_url     = "https://api.openai.com/v1",
      api_key      = "sk-...",
      model        = "gpt-4o",
      protocol     = "chat",            -- chat / responses / jev
      timeout      = 30000,             -- 毫秒
      temperature  = 0.7,
      effort       = "none",            -- none/low/medium/high（仅 responses 协议）
      reasoning    = true,              -- 是否启用思维链
    })
    love.filesystem.write(configPath, template)
    return nil, "首次使用：请编辑 ai_config.json 填入 API 密钥"
  end

  local ok, config = pcall(Json.decode, configText)
  if not ok or type(config) ~= "table" then
    return nil, "ai_config.json 格式错误：" .. tostring(config)
  end

  -- 验证必填字段
  if not config.api_key or config.api_key == "" or config.api_key == "sk-..." then
    return nil, "请编辑 ai_config.json 填入有效的 api_key"
  end
  if not config.base_url or config.base_url == "" then
    return nil, "请填写 base_url"
  end
  if not config.model or config.model == "" then
    return nil, "请填写 model"
  end

  return config
end

-- ─── 传输层实现 ────────────────────────────────────────────────

local AndroidTransport = {}
AndroidTransport.__index = AndroidTransport

class("AndroidTransport", AndroidTransport)

local THREAD_POLL_INTERVAL = 0.05   -- 主线程每 50ms 轮询一次 .res 文件

function AndroidTransport:create(opts)
  local t = setmetatable({}, self)
  t.url       = opts.url
  t.api_key   = opts.api_key
  t.model     = opts.model
  t.protocol  = opts.protocol or "chat"
  t.timeout   = opts.timeout or 30000
  t.temperature = opts.temperature or 0.7
  t.effort    = opts.effort or "none"
  t.reasoning = opts.reasoning

  -- 当前待处理请求
  t._pending_id  = nil
  t._result      = nil
  t._poll_timer  = 0

  -- 队列目录（love.filesystem.getSaveDirectory() + http_queue/）
  t._queue_dir  = "http_queue"

  return t
end

-- 提交请求（异步，立即返回）
function AndroidTransport:submit(prompt)
  if self._pending_id then
    -- 前一个请求还没处理完
    return false, "上一个请求未完成"
  end

  -- 序列化请求体（复用 core/ai/transport.lua 的 buildBody）
  local body = TransportLib.buildBody({
    protocol    = self.protocol,
    model       = self.model,
    system_msg  = prompt.system,
    user_msg    = prompt.user,
    temperature = self.temperature,
    effort      = self.effort,
    reasoning   = self.reasoning,
  })

  -- 构建 headers
  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"]       = "application/json",
    ["Authorization"] = "Bearer " .. self.api_key,
  }
  local headers_json = Json.encode(headers)

  -- 生成唯一 ID
  local req_id = string.format("sgs_%d_%x",
    love.timer.getTime() * 1000000,
    math.random(0, 0xFFFFFF))

  -- 写请求文件
  local req = Json.encode({
    callbackId = req_id,
    method     = "POST",
    url        = self.url,
    timeout    = self.timeout,
  })
  local ok, err = love.filesystem.write(self._queue_dir .. "/" .. req_id .. ".req", req)
  if not ok then
    return false, "写请求文件失败：" .. tostring(err)
  end

  -- 通知 Java 侧处理
  -- love.android.callJava("GameActivity", "httpRequest",
  --   req_id, "POST", self.url, headers_json, body, self.timeout)
  -- 注意：callJava 需要 Lua 线程调用，main thread 中安全
  local call_ok, call_err = pcall(function()
    love.android.callJava("GameActivity", "httpRequest",
      req_id, "POST", self.url, headers_json, body, self.timeout)
  end)
  if not call_ok then
    -- 回退：直接把请求写入 .req 文件，Java FileObserver 也会感知
    love.filesystem.write(self._queue_dir .. "/" .. req_id .. ".req",
      Json.encode({
        callbackId = req_id,
        method     = "POST",
        url        = self.url,
        headers    = headers,
        body       = body,
        timeout    = self.timeout,
      }))
  end

  self._pending_id = req_id
  return true
end

-- 轮询结果（不阻塞，返回 nil 表示未完成）
function AndroidTransport:poll()
  if not self._pending_id then
    return self._result  -- 返回上次结果
  end

  local res_path = self._queue_dir .. "/" .. self._pending_id .. ".res"
  if not love.filesystem.getInfo(res_path) then
    return nil  -- 还没写完
  end

  local res_text = love.filesystem.read(res_path)
  if not res_text or res_text == "" then
    return nil  -- 空文件，继续等
  end

  -- 删除已读结果文件
  love.filesystem.remove(res_path)

  local ok, res = pcall(Json.decode, res_text)
  self._pending_id = nil

  if not ok or type(res) ~= "table" then
    self._result = { ok = false, err = "结果解析失败：" .. tostring(res) }
    return self._result
  end

  local status = res.statusCode or 0
  if status >= 200 and status < 300 and res.body and res.body ~= "" then
    -- 用 core/ai/transport.lua 的 parseResponse 解析 LLM 输出
    local parsed = TransportLib.parseResponse(res.body, self.protocol)
    if parsed.ok then
      self._result = { ok = true, text = parsed.text }
    else
      self._result = { ok = false, err = parsed.err or "LLM 响应解析失败" }
    end
  else
    local err_msg = res.error or ""
    if err_msg == "" and res.body then
      err_msg = res.body:sub(1, 200)
    end
    self._result = { ok = false, err = string.format("HTTP %d: %s", status, err_msg) }
  end

  return self._result
end

function AndroidTransport:cancel()
  if self._pending_id then
    pcall(function()
      love.android.callJava("GameActivity", "cancel", self._pending_id)
    end)
    -- 也删本地文件
    love.filesystem.remove(self._queue_dir .. "/" .. self._pending_id .. ".req")
    love.filesystem.remove(self._queue_dir .. "/" .. self._pending_id .. ".res")
    self._pending_id = nil
  end
  self._result = nil
end

-- ─── 工厂方法：替代原 ai_transport.lua 的 fromEnv() ──────────

-- 从 ai_config.json 创建 AndroidTransport
-- @return transport, err
function AndroidTransport.fromConfig()
  local config, err = loadConfig()
  if not config then
    return nil, err
  end

  -- 构建完整 URL
  local base = config.base_url:gsub("/$", "")
  local url
  if base:find("/chat/completions", 1, true) or base:find("/responses", 1, true) then
    url = base
  elseif config.protocol == "responses" then
    url = base .. "/responses"
  else
    url = base .. "/chat/completions"
  end

  return AndroidTransport:create({
    url         = url,
    api_key     = config.api_key,
    model       = config.model,
    protocol    = config.protocol or "chat",
    timeout     = config.timeout or 30000,
    temperature = config.temperature or 0.7,
    effort      = config.effort or "none",
    reasoning   = config.reasoning,
  }), nil
end

-- 兼容原 ai_transport.lua 的 fromEnv() 接口
-- Android 上没有 SGS_AI_* 环境变量，统一走配置文件
function AndroidTransport.fromEnv()
  return AndroidTransport.fromConfig()
end

return AndroidTransport
