-- AI 设置：读写存档目录下的 ai_config.json，并给设置页提供字段定义
--
-- 为什么需要它：
--   桌面版靠 SGS_AI_URL / SGS_AI_KEY / SGS_AI_MODEL 等环境变量配置，
--   安卓上根本没有「环境变量」这个东西——用户装完 APK 无从下手。
--   所以统一改成存档目录里的一个 JSON，并在游戏里给个能编辑的界面。
--
-- 存哪：love.filesystem.getSaveDirectory()/ai_config.json
--   Android: /data/data/<pkg>/files/save/ai_config.json
--   Desktop: 用户目录下的 LÖVE 存档目录
--
-- 与 ui/transport_android.lua 的关系：那边读同一份文件，字段名一致。
local Json = require "src.core.json"

local Config = {}

Config.FILE = "ai_config.json"

-- 字段定义：设置页按这个顺序画，校验也用它
--   type: "text"（单行）/ "secret"（显示为圆点）/ "number"
Config.FIELDS = {
  { key = "base_url", label = "接口地址", type = "text",
    hint = "例：https://api.openai.com/v1",
    default = "https://api.openai.com/v1" },
  { key = "api_key", label = "API 密钥", type = "secret",
    hint = "只存在本机存档目录，不会上传", default = "" },
  { key = "model", label = "模型名", type = "text",
    hint = "例：gpt-4o / deepseek-chat / llama3", default = "" },
  { key = "protocol", label = "协议", type = "text",
    hint = "chat（多数）或 responses（o1/hy3）", default = "chat" },
  { key = "temperature", label = "采样温度", type = "number",
    hint = "0~2，越小越稳。默认 0.2", default = 0.2 },
  { key = "timeout", label = "超时（秒）", type = "number",
    hint = "默认 90；开启思考时自动放宽到 150", default = 90 },
}

local DEFAULTS = {
  protocol = "chat",
  temperature = 0.2,
  timeout = 90,
  effort = "none",
  thinking = "auto",
  persona = "none",
}

local function fieldDefault(key)
  for _, f in ipairs(Config.FIELDS) do
    if f.key == key then return f.default end
  end
  return DEFAULTS[key]
end

-- 读配置。文件不存在时返回 nil（调用方决定是否创建模板）
function Config.load()
  local text = love.filesystem.read(Config.FILE)
  if not text or text == "" then return nil end
  local ok, t = pcall(Json.decode, text)
  if not ok or type(t) ~= "table" then return nil end
  return t
end

-- 补齐默认值（不改动传入的表）
function Config.withDefaults(cfg)
  local out = {}
  for k, v in pairs(DEFAULTS) do out[k] = v end
  if cfg then
    for k, v in pairs(cfg) do out[k] = v end
  end
  return out
end

-- 首次运行时写模板
function Config.ensure()
  local cfg = Config.load()
  if cfg then return cfg end
  local t = Config.withDefaults({})
  t.base_url = fieldDefault("base_url")
  Config.save(t)
  return t
end

-- 原子写入：先写临时文件再改名，避免写一半掉电留下坏 JSON
function Config.save(cfg)
  local okEnc, text = pcall(Json.encode, cfg)
  if not okEnc or type(text) ~= "string" then
    return false, "配置序列化失败"
  end
  local tmp = Config.FILE .. ".tmp"
  local okW, err = love.filesystem.write(tmp, text)
  if not okW then return false, "写入失败：" .. tostring(err) end
  -- LÖVE 的 filesystem 没有 rename，只能读回再写正式文件
  local back = love.filesystem.read(tmp)
  love.filesystem.remove(tmp)
  if back ~= text then return false, "写入校验失败" end
  local okW2, err2 = love.filesystem.write(Config.FILE, text)
  if not okW2 then return false, "写入失败：" .. tostring(err2) end
  return true
end

-- 校验：返回 nil 表示没问题，否则返回人话错误
function Config.validate(cfg)
  if not cfg then return "配置为空" end
  if type(cfg.base_url) ~= "string" or cfg.base_url == "" then
    return "接口地址不能为空"
  end
  if not cfg.base_url:match("^https?://") then
    return "接口地址要以 http:// 或 https:// 开头"
  end
  if type(cfg.api_key) ~= "string" or cfg.api_key == "" then
    return "API 密钥不能为空"
  end
  if type(cfg.model) ~= "string" or cfg.model == "" then
    return "模型名不能为空"
  end
  if cfg.protocol ~= "chat" and cfg.protocol ~= "responses" then
    return "协议只能是 chat 或 responses"
  end
  local temp = tonumber(cfg.temperature)
  if temp and (temp < 0 or temp > 2) then
    return "采样温度要在 0~2 之间"
  end
  local to = tonumber(cfg.timeout)
  if to and to <= 0 then return "超时要大于 0 秒" end
  return nil
end

-- 把一段用户输入按字段类型转换
function Config.coerce(field, raw)
  if field.type == "number" then
    local n = tonumber(raw)
    if not n then return nil, "请输入数字" end
    return n
  end
  return raw
end

-- 保存目录（给设置页显示「配置在哪」用）
function Config.savePath()
  local ok, dir = pcall(love.filesystem.getSaveDirectory)
  if ok and dir then return dir .. "/" .. Config.FILE end
  return Config.FILE
end

return Config
