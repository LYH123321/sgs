-- 皮肤配置层：读取原版 QSanguosha 的 skins/*.json
--
-- 设计要点：
--   1) **资源根目录可配置，缺失时全部安全降级**。headless 测试、以及没有
--      QSanguosha 源码的机器上，所有查询返回 nil，调用方走内置默认值，绝不崩。
--   2) 原版 json 带注释，用 src/ui/json.lua 解析。
--   3) 图片/音频只给**路径**，加载由调用方（UI 层）按需做——core 与 skin
--      都不碰 love.graphics / love.audio。
local class = require "src.class"
local Json = require "src.core.json"

local Skin = class("Skin")

-- 资源根：**默认用项目自带的 assets/**，不再引用原 QSanguosha 源码目录。
-- 仅当显式设置 SGS_ASSET_ROOT 时才指向别处（便于调试或用完整原版资源）。
-- 资源根探测：必须在「目录」和「.love 打包」两种形态下都工作。
-- 目录用 io.open，打包后 assets/ 在 zip 里、io.open 读不到，只能走
-- love.filesystem（physfs）。两条都试，谁先命中用谁。
local function probe(path)
  -- 1) 物理文件（开发时从项目根启动、或 SGS_ASSET_ROOT 指向目录）
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  -- 2) zip 内（.love / fused 包 / Android 的 assets/game.love）
  if love and love.filesystem then
    local ok, info = pcall(love.filesystem.getInfo, path)
    if ok and info then return true end
  end
  return false
end

local LAYOUT_FILE = "skins/defaultSkin.layout.json"

local function hasLayout(root)
  if not root then return false end
  return probe(root .. "/" .. LAYOUT_FILE)
end

local function findRoot()
  local env = os.getenv("SGS_ASSET_ROOT")
  if env and env ~= "" and hasLayout(env) then return env end

  -- love.filesystem.getSource() 返回项目根目录，或（打包后）.
  -- love/.exe 文件本身的路径。
  --   • 目录形式：资源在 <src>/assets 下，也可能是 <src> 本身
  --   • 打包形式：src 是个文件，拼它没用，资源根就是包内的 "assets"
  -- 两种情况下面兜底的相对路径都能命中，所以打包时直接跳过前缀拼。
  if love and love.filesystem then
    local ok, src = pcall(love.filesystem.getSource)
    if ok and type(src) == "string" and src ~= "" then
      src = src:gsub("\\", "/")
      local looksPackaged = src:lower():match("%.love$") or src:lower():match("%.exe$")
      if not looksPackaged then
        if hasLayout(src .. "/assets") then return src .. "/assets" end
        if hasLayout(src) then return src end
      end
    end
  end

  -- 包内相对路径（打包场景）或 CWD 相对路径（开发场景）
  for _, r in ipairs({ "assets", "./assets" }) do
    if hasLayout(r) then return r end
  end
  return nil
end

local function readFile(path)
  -- 目录：直接读；打包：io.open 读不到 zip 内文件，退回 love.filesystem
  local f = io.open(path, "r")
  if f then
    local content = f:read("*a")
    f:close()
    return content
  end
  if love and love.filesystem then
    local ok, content = pcall(love.filesystem.read, path)
    if ok and type(content) == "string" then return content end
  end
  return nil
end

local function loadJson(root, name)
  if not root then return {} end
  local content = readFile(root .. "/" .. name)
  if not content then return {} end
  local ok, t = pcall(Json.decode, content)
  if not ok or type(t) ~= "table" then return {} end
  return t
end

local warned_no_root = false

function Skin:init(root)
  self.root = root or findRoot()
  -- 显式传入但不存在的根目录，等价于「没有资源」：置 nil 让所有查询降级。
  -- （测试用 Skin.create("/nonexistent") 验证降级路径，依赖这个语义。）
  if self.root and not hasLayout(self.root) then
    self.root = nil
  end
  if not self.root and not warned_no_root then
    warned_no_root = true
    print("[assets] 资源根目录未找到（assets/skins/*.json）：图片与音频全部"
      .. "降级为内置默认。请从项目根目录启动（run-game.bat / run-game.sh）。")
  end
  -- 资源根可能是绝对路径（findRoot 从 getSource 解析出，与 CWD 无关）。
  -- love.graphics.newImage / love.audio.newSource 走 physfs，只认**源内
  -- 相对路径**，因此 Skin:path 输出前要把源目录前缀剥掉（见下）。
  self._src_prefix = nil
  if self.root and love and love.filesystem then
    local ok, src = pcall(love.filesystem.getSource)
    if ok and type(src) == "string" then
      self._src_prefix = (src:gsub("\\", "/") .. "/")
    end
  end
  self.layout = loadJson(self.root, "skins/defaultSkin.layout.json")
  self.imageMap = loadJson(self.root, "skins/defaultSkin.image.json")
  self.audioMap = loadJson(self.root, "skins/defaultSkin.audio.json")
  self.animation = loadJson(self.root, "skins/defaultSkin.animation.json")
  self.cardSizes = (self.layout and self.layout.common) or {}
end

-- 按 "a.b.c" 路径取值
local function getPath(t, path)
  if type(t) ~= "table" then return nil end
  local cur = t
  for part in string.gmatch(path, "[^%.]+") do
    if type(cur) ~= "table" then return nil end
    cur = cur[part]
  end
  return cur
end

function Skin:number(path, default)
  local v = getPath(self.layout, path)
  if type(v) == "number" then return v end
  return default
end

-- 原版布局里的区域一律是 [x, y, w, h]
function Skin:rect(path)
  local v = getPath(self.layout, path)
  if type(v) == "table" and #v >= 4 then return v end
  return nil
end

-- 图片：值可能是 "path" 或 ["path", [x,y,w,h]]，也可能带 %1 占位符
function Skin:image(key, ...)
  local v = self.imageMap[key]
  if type(v) == "string" then
    return self:_fill(v, ...)
  elseif type(v) == "table" then
    if type(v[1]) == "string" then return self:_fill(v[1], ...) end
  end
  return nil
end

function Skin:_fill(str, ...)
  local args = { ... }
  local i = 0
  local out = string.gsub(str, "%%(%d)", function(d)
    return tostring(args[tonumber(d)] or ("%" .. d))
  end)
  return out
end

-- 资源根下的路径。优先给 physfs 适用的**源内相对路径**（剥源目录前缀）；
-- 取不到前缀时（io.open 场景 / headless）按原样拼接。
function Skin:path(relative)
  if not (self.root and relative) then return nil end
  local p = self.root .. "/" .. relative
  local prefix = self._src_prefix
  if prefix and p:sub(1, #prefix) == prefix then
    return p:sub(#prefix + 1)
  end
  return p
end

-- 卡牌图片：原版 image.json 没有逐张卡的映射，靠目录约定
--   基本牌/锦囊：image/card/slash.png（snake_case）
--   装备：      image/card/Crossbow.png（CamelCase）
local CARD_CAMEL = {
  crossbow = "Crossbow", axe = "Axe", blade = "Blade",
  ["double_sword"] = "DoubleSword", ["qinggang_sword"] = "QinggangSword",
  ["spear"] = "Spear", ["halberd"] = "Halberd", ["kylin_bow"] = "KylinBow",
  ["ice_sword"] = "IceSword", ["dodge"] = "Jink",
  ["eight_diagram"] = "EightDiagram", ["silver_lion"] = "SilverLion",
  ["vine"] = "Vine", ["renwang_shield"] = "RenWangShield",
  ["chitu"] = "ChiTu", ["dayuan"] = "DaYuan", ["dilu"] = "DiLu",
  ["jueying"] = "JueYing", ["zhuahuangfeidian"] = "ZhuaHuangFeiDian",
  ["zixing"] = "ZiXing",
  ["dilu_horse"] = "DiLu",
}

function Skin:cardImage(cardName)
  if not (self.root and cardName) then return nil end
  local candidates = {
    "image/card/" .. cardName .. ".png",
    "image/card/" .. cardName .. ".jpg",
  }
  local camel = CARD_CAMEL[cardName]
  if camel then
    table.insert(candidates, 1, "image/card/" .. camel .. ".png")
  else
    -- 没登记的也试一次首字母大写形式
    local upper = string.gsub(cardName, "^%l", string.upper)
    table.insert(candidates, 1, "image/card/" .. upper .. ".png")
  end
  for _, rel in ipairs(candidates) do
    local p = self.root .. "/" .. rel
    if readFile(p) then return rel end
  end
  return nil
end

-- 桌面背景：image.json 的 tableBg 指向 backdrop/default.jpg，
-- 但资源里实际是 backdrop/table.jpg，因此按多个候选依次尝试。
function Skin:tableBackground()
  if not self.root then return nil end
  local candidates = {}
  local v = self.imageMap and self.imageMap.tableBg
  if type(v) == "string" then
    table.insert(candidates, v)
    table.insert(candidates, "image/" .. v)
  end
  table.insert(candidates, "image/backdrop/table.jpg")
  table.insert(candidates, "image/backdrop/bg.jpg")
  table.insert(candidates, "image/backdrop/default.jpg")
  for _, rel in ipairs(candidates) do
    if readFile(self.root .. "/" .. rel) then return rel end
  end
  return nil
end

-- 仪表盘框体（原版 dashboardLeftFrame / dashboardRightBase 等）
function Skin:frame(key)
  return self:image(key)
end

-- 武将头像：原版按拼音命名（image/generals/avatar/caocao.png），
-- 正好对应本引擎 general.key。依次尝试 avatar / card / big 三种尺寸。
local GENERAL_DIRS = {
  "image/generals/avatar/%s.png",
  "image/generals/card/%s.jpg",
  "image/generals/big/%s.png",
}

function Skin:generalImage(key)
  if not (self.root and key) then return nil end
  for _, fmt in ipairs(GENERAL_DIRS) do
    local rel = string.format(fmt, key)
    if readFile(self.root .. "/" .. rel) then return rel end
  end
  return nil
end

-- 勾玉（体力）：image/system/magatamas/{0,1,2,3}.png，0 空 3 满
function Skin:magatamaImage(kind)
  if not self.root then return nil end
  local rel = "image/system/magatamas/" .. tostring(kind) .. ".png"
  if readFile(self.root .. "/" .. rel) then return rel end
  return nil
end

-- 势力图标：原版放在 image/kingdom/icon/ 下（不是 image/kingdom/ 根）
function Skin:kingdomImage(kingdom)
  if not (self.root and kingdom) then return nil end
  for _, rel in ipairs({
    "image/kingdom/icon/" .. kingdom .. ".png",
    "image/kingdom/corner/" .. kingdom .. ".png",
  }) do
    if readFile(self.root .. "/" .. rel) then return rel end
  end
  return nil
end

-- 音频：某事件的音效可能有多个，随机取一个。
--
-- 重要：`defaultSkin.audio.json` 在这个皮肤里**是空的**（与 animation.json 一样），
-- 只查配置会永远返回 nil —— 音频等于没接。因此这里按原版资源目录的约定兜底：
--   audio/card/<male|female>/<card_name>.ogg   出牌音效
--   audio/system/<key>.ogg                     系统音效（injure1 / hplost / lose ...）
--   audio/skill/<key>.ogg                      技能音效
--   audio/death/<general_key>.ogg              阵亡语音
local SYSTEM_SOUND = {
  injure = { "injure1", "injure2", "injure3" },
  hplost = { "hplost" },
  chained = { "chained" },
  lose = { "lose" },
  win = { "win" },
  choose_item = { "choose-item" },
}

local function pick(pool)
  if #pool == 0 then return nil end
  return pool[math.random(#pool)]
end

function Skin:sound(key, gender)
  -- 1) 配置优先
  local v = self.audioMap[key]
  if type(v) == "string" then return v end
  if type(v) == "table" then
    local pool = {}
    for _, item in ipairs(v) do
      if type(item) == "string" then
        table.insert(pool, item)
      elseif type(item) == "table" and type(item[1]) == "string" then
        table.insert(pool, item[1])
      end
    end
    local r = pick(pool)
    if r then return r end
  end
  if not self.root then return nil end

  -- 2) 系统音效
  if SYSTEM_SOUND[key] then
    local n = pick(SYSTEM_SOUND[key])
    local rel = "audio/system/" .. n .. ".ogg"
    if readFile(self.root .. "/" .. rel) then return rel end
  end

  -- 3) 卡牌音效（按性别分目录，回落 common）
  local dirs = { gender == "female" and "female" or "male", "common" }
  for _, d in ipairs(dirs) do
    local rel = string.format("audio/card/%s/%s.ogg", d, key)
    if readFile(self.root .. "/" .. rel) then return rel end
  end

  -- 4) 技能 / 阵亡（键为拼音）
  for _, fmt in ipairs({ "audio/skill/%s.ogg", "audio/death/%s.ogg" }) do
    local rel = string.format(fmt, key)
    if readFile(self.root .. "/" .. rel) then return rel end
  end
  return nil
end

local SKILL_KEYS = require "src.ui.skill_keys"

-- 技能台词：技能名是中文，原版音频文件是拼音，且同一技能常有 1/2 两个版本。
-- 子技能（名字带「·」，如「仁德·回血」）沿用主技能的键。
function Skin:skillSound(skillName)
  if not (self.root and skillName) then return nil end
  local base = string.match(skillName, "^(.-)·") or skillName
  local key = SKILL_KEYS[base]
  if not key then return nil end
  local found = {}
  for _, suffix in ipairs({ "1", "2", "" }) do
    local rel = string.format("audio/skill/%s%s.ogg", key, suffix)
    if readFile(self.root .. "/" .. rel) then table.insert(found, rel) end
  end
  if #found == 0 then return nil end
  return pick(found)
end

-- 是否真的接上了原版资源
function Skin:available()
  return self.root ~= nil and next(self.layout) ~= nil
end

return Skin
