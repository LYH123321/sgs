-- 入口：--test 无头跑测试；--soak 大批量压力测试；否则进入菜单 → 牌桌
local is_test, autostart, is_soak, is_net, is_serve, is_join, is_client = false, false, false, false, false, false, false
for _, a in ipairs(arg or {}) do
  if a == "--test" then is_test = true end
  if a == "--soak" then is_soak = true end
  if a == "--net" then is_net = true end
  if a == "--serve" then is_serve = true end
  if a == "--join" then is_join = true end
  if a == "--client" then is_client = true end
  if a == "--autostart" then autostart = true end
end

local current_scene = nil
local Scale = require "src.ui.scale"

local startGame, startNet, backToMenu, openSettings
local startNetScene

-- ai_mode: "off" / "others" / "all"，由菜单上的 AI 托管按钮决定；
-- draft: 是否开局选将（文档开局流程：主公 5 选 1、其余 3 选 1），
--   由菜单上的「开局选将」开关决定；
-- ai_reasoning: "none" / "low" / "high"，菜单「AI 思考」开关，覆盖 SGS_AI_REASONING
startGame = function(mode, size, ai_mode, draft, ai_reasoning, ai_persona)
  local RoomScene = require "src.ui.scene_room"
  current_scene = RoomScene.create(backToMenu, mode, size, ai_mode,
    { draft = draft ~= false, ai_reasoning = ai_reasoning,
      ai_persona = ai_persona })
end

backToMenu = function()
  local MenuScene = require "src.ui.scene_menu"
  current_scene = MenuScene.create(startGame, startNet, openSettings)
end

-- AI 设置页：安卓上没有 SGS_AI_* 环境变量，只能靠这个界面配
openSettings = function()
  local SettingsScene = require "src.ui.scene_settings"
  current_scene = SettingsScene.create(backToMenu)
end

-- 联机：连上服务端后进入联机牌桌
startNet = function()
  local Client = require "src.net.client"
  local NetScene = require "src.ui.scene_net"
  local host, port = Client.defaultHost()
  local c = Client.connectTo("我", host, port)
  if not c then
    print(string.format("[联机] 连接失败 %s:%s —— 先跑 ./tools/serve.sh", host, port))
    return
  end
  startNetScene(c, "我")
end

startNetScene = function(client, name)
  local NetScene = require "src.ui.scene_net"
  current_scene = NetScene.create(backToMenu, client, name)
end

function love.load()
  -- --serve：以服务端模式启动（阶段 D，见 src/net/server.lua）
  if is_serve then
    local ok, err = pcall(function()
      require("src.net.server").run(tonumber(arg and arg[3]) or 9527, tonumber(arg and arg[4]) or 5)
    end)
    if not ok then print("服务端异常: " .. tostring(err)) end
    love.event.quit()
    return
  end

  -- --client [名字] [host] [port]：图形联机客户端（UI 联调）
  if is_client then
    local ok, err = pcall(function()
      local name = (arg and arg[3]) or "我"
      local host = (arg and arg[4]) or "127.0.0.1"
      local port = tonumber((arg and arg[5]) or "9527") or 9527
      local Client = require "src.net.client"
      local NetScene = require "src.ui.scene_net"
      local c = Client.connectTo(name, host, port)
      if not c then
        print("[联机] 连接失败: " .. host .. ":" .. port)
        love.event.quit()
        return
      end
      startNetScene(c, name)
    end)
    if not ok then print("联机客户端异常: " .. tostring(err)) end
    return
  end

  -- --join <名字> [host] [port]：控制台客户端，连上服务端并自动应答
  if is_join then
    local ok, err = pcall(function()
      local name = (arg and arg[3]) or "玩家"
      local host = (arg and arg[4]) or "127.0.0.1"
      local port = tonumber((arg and arg[5]) or "9527") or 9527
      require("src.net.client").consoleMain(name, host, port)
    end)
    if not ok then print("客户端异常: " .. tostring(err)) end
    love.event.quit()
    return
  end

  local mods = is_test and { "tests.test_game", "tests.test_ui", "tests.test_ai" }
    or is_soak and { "tests.test_soak" }
    or is_net and { "tests.test_net" } or nil
  if mods then
    for _, mod in ipairs(mods) do
      local ok, err = pcall(require, mod)
      if not ok then
        print("TEST CRASH (" .. mod .. "): " .. tostring(err))
        love.event.quit(1)
        return
      end
    end
    love.event.quit()
    return
  end
  Scale.refresh() -- 窗口就绪后先定 UI 缩放，再建场景（场景初始化要用）
  if autostart then
    startGame() -- 无头/GUI 泛化验证：跳过菜单直达牌桌
  else
    backToMenu()
  end
end

function love.keypressed(key, scancode, isrepeat)
  -- 安卓返回键 = escape：优先给场景处理（关弹层/收起键盘），
  -- 主菜单不拦，让系统退回桌面。
  -- 全屏切换（desktop 模式不改分辨率，切换即时无黑屏）：
  --   F11 / Alt+Enter：Windows、Linux 惯用
  --   Cmd+Enter / Ctrl+Cmd+F：macOS 惯用（F11 默认被系统「显示桌面」拦截）
  local down = love.keyboard.isDown
  local alt = down("lalt") or down("ralt")
  local cmd = down("lgui") or down("rgui")
  local ctrl = down("lctrl") or down("rctrl")
  if key == "f11"
    or (key == "return" and (alt or cmd))
    or (key == "f" and cmd and ctrl) then
    local fs = love.window.getFullscreen()
    love.window.setFullscreen(not fs, "desktop")
    return
  end
  if current_scene and current_scene.keypressed then
    current_scene:keypressed(key)
  end
end

-- 软键盘输入：设置页、联机聊天等需要文本输入的场景实现 textinput。
-- 安卓上 love.keyboard.setTextInput(true) 会弹出系统输入法，
-- 字符通过这个回调回来（不是 keypressed）。
function love.textinput(t)
  if current_scene and current_scene.textinput then
    current_scene:textinput(t)
  end
end

-- 窗口尺寸变化（拖拽调窗 / 全屏切换 / 高分屏 DPI 变化）：
-- 刷新全局 UI 缩放，并让当前场景重建字体与布局。
function love.resize(w, h)
  Scale.refresh()
  if current_scene and current_scene.onResize then
    local ok, err = pcall(current_scene.onResize, current_scene, w, h)
    if not ok then print("[resize] 场景重建失败: " .. tostring(err)) end
  end
end

function love.update(dt)
  if current_scene and current_scene.update then current_scene:update(dt) end
end

function love.draw()
  if current_scene and current_scene.draw then current_scene:draw() end
end

function love.mousepressed(x, y, button)
  if current_scene and current_scene.mousepressed then
    current_scene:mousepressed(x, y, button)
  end
end

-- 触摸转发：SDL 会把触摸也合成鼠标事件，但只监听 mousepressed 的场景
-- 在部分安卓设备上收不到（触摸被 SDL 当作 touch 事件消费）。
-- 这里补一层，保证点按既能当触摸也能当鼠标用。
function love.touchpressed(id, x, y, dx, dy, pressure)
  if current_scene and current_scene.mousepressed then
    local w, h = love.graphics.getDimensions()
    current_scene:mousepressed(x * w, y * h, 1)
  end
end

function love.touchreleased(id, x, y, dx, dy, pressure)
  if current_scene and current_scene.mousereleased then
    local w, h = love.graphics.getDimensions()
    current_scene:mousereleased(x * w, y * h, 1)
  end
end

function love.mousereleased(x, y, button)
  if current_scene and current_scene.mousereleased then
    current_scene:mousereleased(x, y, button)
  end
end

function love.wheelmoved(x, y)
  if current_scene and current_scene.wheelmoved then
    current_scene:wheelmoved(x, y)
  end
end
