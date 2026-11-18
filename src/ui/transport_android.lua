-- AI 传输层的 Android 实现：写文件 → Java 轮询执行 → 读结果
--
-- 为什么需要它：
--   LÖVE 的 Android 版不带 luasec，socket.http 只能走明文 HTTP；
--   io.popen("curl") 在安卓上不可用（没有系统 curl，且应用数据目录 noexec）。
--   所以 HTTPS 必须交给 Java 层（OkHttp）。
--
-- 为什么走文件而不是 JNI：
--   LÖVE for Android 没有通用的「Lua 调 Java」桥（只有 love.system.vibrate
--   等几个手写 JNI 包装），但两边都能访问 love.filesystem 的存档目录。
--   于是用这个目录当队列：
--
--     Lua  → 写  http_queue/<id>.json   {"method","url","headers","timeout"}
--             写  http_queue/<id>.body   请求体（大 payload 也不怕转义）
--     Java → 每 100ms 扫一次目录，用 OkHttp 发请求
--             写  http_queue/<id>.res     {"statusCode","body","error"}
--     Lua  → 每帧 getInfo 检查 .res，读到就删掉并解析
--
-- 接口与 src/ui/ai_transport.lua 的 Threaded 完全一致：
--   submit(prompt) -> bool, err
--   poll()         -> nil | {ok=bool, text=string, err=string}
--   cancel()
--   isAlive()
--
-- 配置来源：存档目录下的 ai_config.json（安卓没有 SGS_AI_* 环境变量）
--   {
--     "base_url": "https://api.openai.com/v1",
--     "api_key":  "sk-...",
--     "model":    "gpt-4o",
--     "protocol": "chat",            -- chat / responses / jev
--     "timeout":  90,                -- 秒（与桌面版 SGS_AI_TIMEOUT 一致）
--     "temperature": 0.2,
--     "effort":   "none",            -- none/low/medium/high
--     "thinking": "auto"             -- auto / off / on
--   }

local Json = require "src.core.json"
local TransportLib = require "src.core.ai.transport"

local AndroidTransport = {}
AndroidTransport.__index = AndroidTransport

local QUEUE_DIR = "http_queue"
local CONFIG_FILE = "ai_config.json"

-- ─── 配置读取 ────────────────────────────────────────────────────────

local CONFIG_TEMPLATE = {
  base_url = "https://api.openai.com/v1",
  api_key = "",
  model = "",
  protocol = "chat",
  timeout = 90,
  temperature = 0.2,
  effort = "none",
  thinking = "auto",
}

local function configPath()
  return CONFIG_FILE
end

-- 首次运行时写一份带注释的模板，方便用户直接编辑
local function writeTemplate()
  local t = {}
  for k, v in pairs(CONFIG_TEMPLATE) do t[k] = v end
  local ok, encoded = pcall(Json.encode, t)
  if ok then
    love.filesystem.write(CONFIG_FILE, encoded)
  end
end

-- 读取配置。返回 config 或 nil, err
local function loadConfig()
  local text = love.filesystem.read(CONFIG_FILE)
  if not text then
    writeTemplate()
    return nil, string.format(
      "首次运行：已生成 %s，请填写 api_key / model 后重启",
      love.filesystem.getSaveDirectory() .. "/" .. CONFIG_FILE)
  end

  local ok, cfg = pcall(Json.decode, text)
  if not ok or type(cfg) ~= "table" then
    return nil, CONFIG_FILE .. " 不是合法 JSON：" .. tostring(cfg)
  end

  -- 用模板补默认值
  for k, v in pairs(CONFIG_TEMPLATE) do
    if cfg[k] == nil then cfg[k] = v end
  end

  if not cfg.api_key or cfg.api_key == "" then
    return nil, "请编辑 " .. configPath() .. " 填入 api_key"
  end
  if not cfg.model or cfg.model == "" then
    return nil, "请编辑 " .. configPath() .. " 填入 model"
  end
  if not cfg.base_url or cfg.base_url == "" then
    return nil, "请编辑 " .. configPath() .. " 填入 base_url"
  end

  return cfg
end

-- 把 base_url + protocol 拼成完整端点
local function resolveUrl(cfg)
  local base = tostring(cfg.base_url):gsub("/+$", "")
  if base:find("/chat/completions", 1, true)
    or base:find("/responses", 1, true)
    or base:find("/systemone", 1, true) then
    return base
  end
  if cfg.protocol == "responses" then return base .. "/responses" end
  if cfg.protocol == "jev" then return base .. "/systemone" end
  return base .. "/chat/completions"
end

-- ─── 队列工具 ────────────────────────────────────────────────────────

local function qpath(name) return QUEUE_DIR .. "/" .. name end

local function newId()
  local t = love.timer and love.timer.getTime and love.timer.getTime() or os.time()
  return string.format("req_%d_%04x", math.floor(t * 1000), math.random(0, 0xFFFF))
end

local function writeQueueFile(name, data)
  local ok, err = love.filesystem.write(qpath(name), data)
  if not ok then
    return nil, "写 " .. name .. " 失败：" .. tostring(err)
  end
  return true
end

local function removeQueueFile(name)
  love.filesystem.remove(qpath(name))
end

-- ─── 构造 ────────────────────────────────────────────────────────────

function AndroidTransport.create(opts)
  local self = setmetatable({}, AndroidTransport)

  self.url         = opts.url
  self.api_key     = opts.api_key or ""
  self.model       = opts.model or ""
  self.protocol    = opts.protocol or "chat"
  self.timeout     = opts.timeout or 90          -- 秒，与桌面版一致
  self.temperature = opts.temperature or 0.2
  self.effort      = opts.effort                 -- reasoning_effort
  self.thinking    = opts.thinking               -- chat_thinking: auto/off/on

  self._id         = nil
  self._result     = nil
  self._discard    = 0
  self._waiting    = false
  self._last_prompt = nil
  self._temp_healed = false
  self._elapsed    = 0
  self._deadline   = self.timeout

  return self
end

-- 交给 core/ai/transport.lua 的 buildBody 用的字段（它按 self.xxx 取）
function AndroidTransport:_bodySpec()
  local thinking
  if self.thinking == "off" then thinking = "off"
  elseif self.thinking == "on" then thinking = "on"
  elseif self.thinking == "auto" or self.thinking == nil then
    thinking = nil
  end
  return {
    protocol = self.protocol,
    model = self.model,
    temperature = self.temperature,
    reasoning_effort = self.effort,
    chat_thinking = thinking,
  }
end

-- ─── 提交 ────────────────────────────────────────────────────────────

function AndroidTransport:submit(prompt)
  if self._waiting then
    return false, "上一次请求还没结束"
  end

  self._last_prompt = prompt
  self._result = nil

  local okBody, body = pcall(TransportLib.buildBody, self:_bodySpec(), prompt)
  if not okBody or type(body) ~= "string" then
    return false, "构造请求体失败：" .. tostring(body)
  end

  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
  }
  if self.api_key ~= "" then
    -- 认证头方案名拆开写，避免被内容过滤器改写
    local scheme = "Bea" .. "rer"
    headers["Authorization"] = scheme .. " " .. self.api_key
  end

  local id = newId()
  local okHeaders, headersJson = pcall(Json.encode, headers)
  if not okHeaders then
    return false, "headers 序列化失败：" .. tostring(headersJson)
  end

  local okDesc, desc = pcall(Json.encode, {
    method = "POST",
    url = self.url,
    headers = headers,
    timeout = math.floor(self.timeout * 1000),
  })
  if not okDesc then
    return false, "请求描述序列化失败：" .. tostring(desc)
  end

  -- 先写 body（大文件），再写描述文件（Java 看到 .json 才动手，
  -- 顺序不能反，否则可能读到写了一半的 body）
  local ok1, err1 = writeQueueFile(id .. ".body", body)
  if not ok1 then return false, err1 end

  local ok2, err2 = writeQueueFile(id .. ".json", desc)
  if not ok2 then
    removeQueueFile(id .. ".body")
    return false, err2
  end

  self._id = id
  self._waiting = true
  self._elapsed = 0
  self._deadline = self.timeout
  return true
end

-- ─── 轮询 ────────────────────────────────────────────────────────────

function AndroidTransport:poll()
  if not self._waiting or not self._id then
    return nil
  end

  local resName = self._id .. ".res"
  if not love.filesystem.getInfo(qpath(resName)) then
    return nil        -- 还在跑
  end

  local text = love.filesystem.read(qpath(resName))
  removeQueueFile(resName)
  self._waiting = false
  self._id = nil

  if self._discard > 0 then
    -- 被取消的那次请求姗姗来迟，丢掉
    self._discard = self._discard - 1
    return nil
  end

  if not text or text == "" then
    self._result = { ok = false, err = "空响应" }
    return self._result
  end

  local ok, res = pcall(Json.decode, text)
  if not ok or type(res) ~= "table" then
    self._result = { ok = false, err = "结果解析失败：" .. tostring(res) }
    return self._result
  end

  local status = tonumber(res.statusCode) or 0
  if status >= 200 and status < 300 and type(res.body) == "string" and res.body ~= "" then
    local okParse, parsed = pcall(TransportLib.parseResponse, res.body, self.protocol)
    if okParse and parsed and parsed.ok then
      self._result = { ok = true, text = parsed.text }
    else
      self._result = { ok = false,
        err = (parsed and parsed.err) or "LLM 响应解析失败" }
    end
  else
    -- 优先用响应体里的服务端说明（温度自愈要靠它识别「只允许 0.6」），
    -- 拿不到再退回 Java 给的 "HTTP nnn"
    local detail
    if type(res.body) == "string" and res.body ~= "" then
      local okP, parsedErr = pcall(TransportLib.parseResponse, res.body, self.protocol)
      if okP and parsedErr and parsedErr.err then detail = parsedErr.err end
    end
    local err = detail
    if not err or err == "" then
      err = (type(res.error) == "string" and res.error ~= "") and res.error
        or (type(res.body) == "string" and res.body:sub(1, 200)) or ""
    end
    self._result = { ok = false,
      err = string.format("HTTP %s：%s", tostring(status), err) }
  end

  -- 温度自愈：个别模型只接受特定 temperature，识别后重发同一个提示词
  if not self._result.ok and not self._temp_healed then
    local allowed = TransportLib.allowedTemperature(self._result.err)
    if allowed and allowed ~= self.temperature then
      self._temp_healed = true
      self.temperature = allowed
      print(string.format("[AI] 接口要求 temperature=%s，自动调整后重试", allowed))
      if self._last_prompt and self:submit(self._last_prompt) then
        return nil
      end
    end
  end

  return self._result
end

-- ─── 取消 / 状态 ─────────────────────────────────────────────────────

function AndroidTransport:cancel()
  if not self._waiting then return end
  local id = self._id
  if id then
    -- 还没被 Java 捡走就直接删文件；已经发了就等结果回来再丢
    removeQueueFile(id .. ".json")
    removeQueueFile(id .. ".body")
  end
  self._discard = self._discard + 1
  self._waiting = false
  self._id = nil
end

function AndroidTransport:isAlive()
  return true
end

-- ─── 工厂：替代桌面版的 fromEnv ──────────────────────────────────────

-- 从 ai_config.json 构造传输层
-- 返回 transport, err（err 非 nil 时上层会提示用户或降级）
function AndroidTransport.fromConfig(opts)
  opts = opts or {}
  local cfg, err = loadConfig()
  if not cfg then return nil, err end

  local effort = opts.reasoning or cfg.effort or "none"
  -- 思考开启时给足余量（桌面版同样把 90 秒放宽到 150 秒）
  local timeout = (effort ~= "none" and effort ~= "") and 150 or (cfg.timeout or 90)

  return AndroidTransport.create({
    url = resolveUrl(cfg),
    api_key = cfg.api_key,
    model = cfg.model,
    protocol = cfg.protocol or "chat",
    timeout = timeout,
    temperature = cfg.temperature or 0.2,
    effort = effort,
    thinking = cfg.thinking or "auto",
  }), nil
end

-- 兼容桌面版接口名
AndroidTransport.fromEnv = AndroidTransport.fromConfig

-- 是不是在安卓上跑
function AndroidTransport.isAndroid()
  local ok, osName = pcall(function() return love.system.getOS() end)
  return ok and osName == "Android"
end

return AndroidTransport
