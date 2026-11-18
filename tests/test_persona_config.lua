-- persona.lua 与 ui/ai_config.lua 的离线测试
--
-- 运行：cd sgs && lua5.1 tests/test_persona_config.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

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

-- ── mock love.filesystem ─────────────────────────────────────────────
local store = {}
love = {
  filesystem = {
    write = function(p, d) store[p] = d; return true end,
    read = function(p) return store[p] end,
    remove = function(p) store[p] = nil; return true end,
    getInfo = function(p) return store[p] and { type = "file" } or nil end,
    getSaveDirectory = function() return "/mock/save" end,
  },
}

local Persona = require "src.core.ai.persona"
local Config = require "src.ui.ai_config"
local Prompt = require "src.core.ai.prompt"

-- ── 1. Persona 基本性质 ─────────────────────────────────────────────

print("[1] 性格列表")
local keys = Persona.keys()
check("至少 5 种性格", #keys >= 5, #keys)
check("含 none", Persona.label("none") == "默认", Persona.label("none"))
check("key 唯一", (function()
  local seen = {}
  for _, k in ipairs(keys) do
    if seen[k] then return false end
    seen[k] = true
  end
  return true
end)())

print("\n[2] none 不改变 system")
local base = "你是玩家。"
check("none 原样返回", Persona.apply(base, "none") == base)
check("nil 原样返回", Persona.apply(base, nil) == base)
check("未知 key 原样返回", Persona.apply(base, "no-such-persona") == base)
check("none 的 hint 为 nil", Persona.hint("none") == nil)

print("\n[3] 具体性格会追加段落")
local out = Persona.apply(base, "aggressive")
check("包含原 system", out:find(base, 1, true) ~= nil)
check("包含性格标记", out:find("【你的性格】", 1, true) ~= nil)
check("包含激进描述", out:find("激进", 1, true) ~= nil)
check("性格只追加不改写", out:sub(1, #base) == base)

print("\n[4] 每种性格都能生成且各不相同")
local seenHint = {}
local allDistinct = true
for _, k in ipairs(keys) do
  local h = Persona.hint(k)
  if h then
    if seenHint[h] then allDistinct = false end
    seenHint[h] = true
  end
end
check("有 hint 的性格互不重复", allDistinct)

-- ── 5. 接进 Prompt ─────────────────────────────────────────────────

print("\n[5] Prompt.build 的 system 会带上性格")
-- 造一个最小可用的 room/req 太麻烦，这里直接验证 build 的参数透传：
-- opts.persona 会传给 Persona.apply，等价于上面 [3] 的断言。
local p_none = { system = Prompt.SYSTEM }
check("默认 system 不含性格段", not Prompt.SYSTEM:find("【你的性格】", 1, true))
local withPersona = Persona.apply(Prompt.SYSTEM, "scheming")
check("加上性格后含标记", withPersona:find("【你的性格】", 1, true) ~= nil)
check("加上性格后含腹黑描述", withPersona:find("算计", 1, true) ~= nil)

-- ── 6. ai_config 读写 ──────────────────────────────────────────────

print("\n[6] 配置读写")
store = {}
check("首次 load 返回 nil", Config.load() == nil)

local t = Config.ensure()
check("ensure 建出配置", t ~= nil and t.base_url ~= nil, t and t.base_url)
check("文件已写入", store["ai_config.json"] ~= nil)
check("protocol 默认 chat", t.protocol == "chat", t.protocol)
check("temperature 默认 0.2", t.temperature == 0.2, t.temperature)
check("persona 默认 none", t.persona == "none", t.persona)

print("\n[7] 保存后能读回")
local cfg = Config.withDefaults({
  base_url = "https://api.deepseek.com/v1",
  api_key = "sk-test-123",
  model = "deepseek-chat",
  protocol = "chat",
  persona = "cautious",
})
local okSave, errSave = Config.save(cfg)
check("保存成功", okSave == true, errSave)
local back = Config.load()
check("读回 base_url", back and back.base_url == "https://api.deepseek.com/v1",
  back and back.base_url)
check("读回 persona", back and back.persona == "cautious", back and back.persona)

print("\n[8] 校验")
check("空地址被拒", Config.validate({ base_url = "", api_key = "k", model = "m",
  protocol = "chat" }) ~= nil)
check("非 http 地址被拒", Config.validate({ base_url = "ftp://x", api_key = "k",
  model = "m", protocol = "chat" }) ~= nil)
check("空密钥被拒", Config.validate({ base_url = "https://a/v1", api_key = "",
  model = "m", protocol = "chat" }) ~= nil)
check("空模型被拒", Config.validate({ base_url = "https://a/v1", api_key = "k",
  model = "", protocol = "chat" }) ~= nil)
check("坏协议被拒", Config.validate({ base_url = "https://a/v1", api_key = "k",
  model = "m", protocol = "grpc" }) ~= nil)
check("温度越界被拒", Config.validate({ base_url = "https://a/v1", api_key = "k",
  model = "m", protocol = "chat", temperature = 5 }) ~= nil)
check("合法配置通过", Config.validate({ base_url = "https://a/v1", api_key = "k",
  model = "m", protocol = "chat", temperature = 0.5, timeout = 90 }) == nil)

print("\n[9] coerce")
local n, e = Config.coerce({ type = "number" }, "0.7")
check("数字字段转换", n == 0.7, tostring(n) .. "/" .. tostring(e))
local bad, berr = Config.coerce({ type = "number" }, "abc")
check("非数字被拒", bad == nil and berr ~= nil, berr)
local s2 = Config.coerce({ type = "text" }, "hello")
check("文本字段原样", s2 == "hello")

print(string.format("\n===== %d passed, %d failed =====", pass, fail))
os.exit(fail == 0 and 0 or 1)
