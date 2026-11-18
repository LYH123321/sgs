-- AI 设置场景：在游戏里配置接口、模型与性格
--
-- 为什么需要：
--   桌面版靠 SGS_AI_* 环境变量，安卓上没有环境变量这回事，用户装完 APK
--   无从下手。这个页面把 ai_config.json 变成可点的界面。
--
-- 输入：用 love.keyboard.setTextInput + love.textinput 走系统输入法，
--   安卓上会弹出软键盘（这是唯一能输入中文/长密钥的可靠方式）。
--
-- 布局：竖向一列字段，点一下进入编辑，回车/点「完成」提交。
local class = require "src.class"
local Scale = require "src.ui.scale"
local S = Scale.px
local Config = require "src.ui.ai_config"
local Persona = require "src.core.ai.persona"

local FONT_PATH = "assets/font/DroidSansFallback.ttf"

local BG = { 0.055, 0.09, 0.07 }
local GOLD = { 0.94, 0.82, 0.45 }
local GOLD_DIM = { 0.78, 0.66, 0.35 }
local FIELD_BG = { 0.10, 0.16, 0.13 }
local FIELD_BG_ACTIVE = { 0.16, 0.26, 0.20 }
local BTN_SAVE = { 0.18, 0.42, 0.28 }
local BTN_BACK = { 0.20, 0.22, 0.26 }
local TEXT = { 0.97, 0.95, 0.88 }
local MUTED = { 0.62, 0.66, 0.60 }
local ERR = { 0.92, 0.42, 0.36 }

local SettingsScene = class("SettingsScene")

function SettingsScene:init(on_back)
  self.on_back = on_back
  self.cfg = Config.ensure() or Config.withDefaults({})
  self.cfg = Config.withDefaults(self.cfg)

  self:buildFonts()

  -- 可编辑字段
  self.fields = {}
  for _, f in ipairs(Config.FIELDS) do
    self.fields[#self.fields + 1] = {
      key = f.key, label = f.label, type = f.type, hint = f.hint,
      value = tostring(self.cfg[f.key] or f.default or ""),
    }
  end

  -- 性格选择（不是自由文本，点一下循环）
  self.persona_index = 1
  for i, p in ipairs(Persona.ALL) do
    if p.key == (self.cfg.persona or "none") then self.persona_index = i end
  end

  self.active = nil        -- 正在编辑的字段下标
  self.scroll = 0
  self.status = nil        -- {text=, ok=bool}
  self.t = 0

  self:relayout(love.graphics.getDimensions())
end

function SettingsScene:buildFonts()
  local f = function(size)
    return Scale.font(FONT_PATH, size) or love.graphics.newFont(FONT_PATH, size)
  end
  self.font_title = f(30)
  self.font = f(17)
  self.font_sm = f(13)
end

function SettingsScene:onResize()
  self:buildFonts()
  self:relayout(love.graphics.getDimensions())
end

function SettingsScene:relayout(w, h)
  self.w, self.h = w, h
  local margin = S(28)
  self.list_x = margin
  self.list_w = w - margin * 2
  self.row_h = S(52)
  self.row_gap = S(8)
  self.list_y = S(92)

  local y = self.list_y
  for i, f in ipairs(self.fields) do
    f.x, f.y = self.list_x, y
    f.w, f.h = self.list_w, self.row_h
    y = y + self.row_h + self.row_gap
  end
  -- 性格行
  self.persona_row = { x = self.list_x, y = y, w = self.list_w, h = self.row_h }
  y = y + self.row_h + self.row_gap

  -- 底部按钮
  local bw, gap = S(150), S(16)
  self.save_btn = { x = w - margin - bw, y = h - S(58), w = bw, h = S(42) }
  self.back_btn = { x = w - margin - bw * 2 - gap, y = h - S(58),
    w = bw, h = S(42) }
  self.content_bottom = y
end

function SettingsScene:update(dt)
  self.t = self.t + (dt or 0)
  if love.mouse and love.mouse.getPosition then
    local ok, mx, my = pcall(love.mouse.getPosition)
    if ok then self.mx, self.my = mx, my end
  end
end

local function pointIn(b, x, y)
  return b and x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h
end

-- ── 输入焦点 ────────────────────────────────────────────────────────

function SettingsScene:_focus(i)
  self.active = i
  if love.keyboard and love.keyboard.setTextInput then
    -- 弹软键盘（安卓）；桌面无副作用
    pcall(love.keyboard.setTextInput, true)
  end
end

function SettingsScene:_blur()
  self.active = nil
  if love.keyboard and love.keyboard.setTextInput then
    pcall(love.keyboard.setTextInput, false)
  end
end

-- 由 main.lua 的 love.textinput 转发
function SettingsScene:textinput(t)
  if not self.active then return end
  local f = self.fields[self.active]
  if not f then return end
  f.value = (f.value or "") .. t
end

function SettingsScene:keypressed(key)
  if key == "escape" then
    if self.active then
      self:_blur()
    else
      self:back()
    end
    return
  end
  if not self.active then return end
  local f = self.fields[self.active]
  if not f then return end

  if key == "backspace" then
    f.value = (f.value or ""):sub(1, -2)
  elseif key == "return" or key == "kpenter" then
    self:_blur()
  end
end

-- ── 保存 ────────────────────────────────────────────────────────────

function SettingsScene:collect()
  local out = {}
  for _, f in ipairs(self.fields) do
    out[f.key] = f.value
  end
  -- 数值字段转成数字
  out.temperature = tonumber(out.temperature) or 0.2
  out.timeout = tonumber(out.timeout) or 90
  out.persona = Persona.ALL[self.persona_index].key
  -- 保留已有但界面上不显示的字段
  for k, v in pairs(self.cfg) do
    if out[k] == nil then out[k] = v end
  end
  return out
end

function SettingsScene:save()
  local cfg = self:collect()
  local err = Config.validate(cfg)
  if err then
    self.status = { text = err, ok = false }
    return
  end
  local ok, werr = Config.save(cfg)
  if not ok then
    self.status = { text = "保存失败：" .. tostring(werr), ok = false }
    return
  end
  self.cfg = cfg
  self.status = { text = "已保存，返回菜单后生效", ok = true }
end

function SettingsScene:back()
  self:_blur()
  if self.on_back then self.on_back() end
end

-- ── 点击 ────────────────────────────────────────────────────────────

function SettingsScene:mousepressed(x, y, button)
  if button ~= 1 then return end

  if pointIn(self.save_btn, x, y) then self:save(); return end
  if pointIn(self.back_btn, x, y) then self:back(); return end

  if pointIn(self.persona_row, x, y) then
    self.persona_index = (self.persona_index % #Persona.ALL) + 1
    self:_blur()
    return
  end

  for i, f in ipairs(self.fields) do
    if pointIn(f, x, y) then
      if self.active == i then self:_blur() else self:_focus(i) end
      return
    end
  end

  -- 点空白处收起键盘
  self:_blur()
end

-- ── 绘制 ────────────────────────────────────────────────────────────

local function masked(s)
  if #s <= 8 then return string.rep("•", #s) end
  return s:sub(1, 4) .. string.rep("•", math.min(#s - 8, 16)) .. s:sub(-4)
end

function SettingsScene:draw()
  local w, h = self.w, self.h

  -- 背景
  love.graphics.setColor(BG)
  love.graphics.rectangle("fill", 0, 0, w, h)

  -- 标题
  love.graphics.setColor(GOLD)
  love.graphics.setFont(self.font_title)
  love.graphics.print("AI 设置", S(28), S(26))
  love.graphics.setColor(MUTED)
  love.graphics.setFont(self.font_sm)
  love.graphics.print(Config.savePath(), S(28), S(64))

  -- 字段
  for i, f in ipairs(self.fields) do
    local is_active = (self.active == i)
    local hover = self.mx and pointIn(f, self.mx, self.my)
    local bg = is_active and FIELD_BG_ACTIVE or FIELD_BG
    love.graphics.setColor(bg)
    love.graphics.rectangle("fill", f.x, f.y, f.w, f.h, 8, 8)
    love.graphics.setColor(GOLD_DIM[1], GOLD_DIM[2], GOLD_DIM[3],
      is_active and 0.95 or (hover and 0.6 or 0.28))
    if love.graphics.setLineWidth then love.graphics.setLineWidth(is_active and 2 or 1) end
    love.graphics.rectangle("line", f.x, f.y, f.w, f.h, 8, 8)
    if love.graphics.setLineWidth then love.graphics.setLineWidth(1) end

    love.graphics.setColor(MUTED)
    love.graphics.setFont(self.font_sm)
    love.graphics.print(f.label, f.x + S(14), f.y + S(7))

    love.graphics.setFont(self.font)
    local shown = f.value ~= "" and f.value or ("（" .. f.hint .. "）")
    love.graphics.setColor(f.value ~= "" and TEXT or { 0.45, 0.48, 0.45 })
    if f.type == "secret" and f.value ~= "" then shown = masked(f.value) end
    -- 编辑中显示光标
    if is_active and math.floor(self.t * 2) % 2 == 0 then shown = shown .. "|" end
    love.graphics.print(shown, f.x + S(14), f.y + S(24))
  end

  -- 性格行
  local pr = self.persona_row
  love.graphics.setColor(FIELD_BG)
  love.graphics.rectangle("fill", pr.x, pr.y, pr.w, pr.h, 8, 8)
  love.graphics.setColor(GOLD_DIM[1], GOLD_DIM[2], GOLD_DIM[3], 0.28)
  love.graphics.rectangle("line", pr.x, pr.y, pr.w, pr.h, 8, 8)
  love.graphics.setColor(MUTED)
  love.graphics.setFont(self.font_sm)
  love.graphics.print("AI 性格（点一下切换）", pr.x + S(14), pr.y + S(7))
  local p = Persona.ALL[self.persona_index]
  love.graphics.setColor(TEXT)
  love.graphics.setFont(self.font)
  love.graphics.print(p.label .. "  ▸", pr.x + S(14), pr.y + S(24))
  -- 当前性格的一句话说明
  if p.hint then
    love.graphics.setColor(MUTED)
    love.graphics.setFont(self.font_sm)
    love.graphics.printf(p.hint, pr.x + S(160), pr.y + S(24),
      pr.w - S(180), "left")
  end

  -- 状态提示
  if self.status then
    love.graphics.setColor(self.status.ok and GOLD or ERR)
    love.graphics.setFont(self.font_sm)
    love.graphics.printf(self.status.text, 0, self.back_btn.y - S(26), w, "center")
  end

  -- 底部按钮
  local function drawBtn(b, label, color)
    local hover = self.mx and pointIn(b, self.mx, self.my)
    love.graphics.setColor(color[1], color[2], color[3], hover and 1 or 0.9)
    love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, 8, 8)
    love.graphics.setColor(TEXT)
    love.graphics.setFont(self.font)
    love.graphics.printf(label, b.x, b.y + (b.h - S(18)) / 2, b.w, "center")
  end
  drawBtn(self.back_btn, "返回", BTN_BACK)
  drawBtn(self.save_btn, "保存", BTN_SAVE)

  love.graphics.setColor(1, 1, 1, 1)
end

return SettingsScene
