-- skin.lua 的双形态测试：目录形态（io.open）与 .love 打包形态
-- （io.open 读不到 zip，只能靠 love.filesystem）。
--
-- 打包形态就是安卓上的实际情形：游戏在 assets/game.love 里。
--
-- 运行：cd sgs && lua5.1 tests/test_skin_packaged.lua

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

-- ── 假 zip：只有 love.filesystem 能看见的文件 ─────────────────────
local zipFs = {
  ["assets/skins/defaultSkin.layout.json"] =
    '{"common": {"cardWidth": 93, "cardHeight": 130}}',
  ["assets/skins/defaultSkin.image.json"] =
    '{"photoChain": "image/system/chain.png", "card": "image/card/%1.png"}',
  ["assets/skins/defaultSkin.audio.json"] =
    '{"playerAudioEffect-common-weapon": "audio/card/common/weapon.ogg"}',
  ["assets/skins/defaultSkin.animation.json"] = '{}',
}

love = {
  filesystem = {
    getInfo = function(p)
      if zipFs[p] then return { type = "file", size = #zipFs[p] } end
      return nil
    end,
    read = function(p) return zipFs[p] end,
    -- 打包形态：getSource 返回 .love 文件本身
    getSource = function() return "/data/user/0/com.sgs.game/files/game.love" end,
  },
}

-- io.open 一律失败：模拟 zip 内文件对标准库不可见
local realOpen = io.open
io.open = function(path, mode)
  if path and path:match("^assets/") then return nil end
  return realOpen(path, mode)
end

local Skin = require "src.ui.skin"

print("[1] 打包形态下应能找到资源根")
local s = Skin.create()
check("root 已找到", s.root ~= nil, s.root)
check("root 是包内相对路径 assets", s.root == "assets", s.root)

print("\n[2] 布局/图片/音频映射应真的读出来")
check("layout 读到了", s:number("common.cardWidth") == 93, s:number("common.cardWidth"))
check("image 映射读到了", s:image("photoChain") == "image/system/chain.png",
  s:image("photoChain"))
check("image 占位符填充", s:image("card", "slash") == "image/card/slash.png",
  s:image("card", "slash"))
check("audio 映射读到了",
  s:sound("playerAudioEffect-common-weapon") == "audio/card/common/weapon.ogg",
  s:sound("playerAudioEffect-common-weapon"))

print("\n[3] path() 应给出 physfs 可用的相对路径")
local p = s:path("image/card/slash.png")
check("path 不为 nil", p ~= nil)
check("path 以 assets/ 开头", p and p:match("^assets/") ~= nil, p)
check("path 不夹带 .love 绝对路径", p and p:find("game.love", 1, true) == nil, p)
check("path 与 love.filesystem 里存在的文件一致", p and zipFs[p] ~= nil or p == "assets/image/card/slash.png", p)

print("\n[4] 目录形态仍然可用（不能被改动破坏）")
io.open = realOpen
os.execute("mkdir -p /tmp/sgs_skin_test/assets/skins 2>/dev/null")
local f = io.open("/tmp/sgs_skin_test/assets/skins/defaultSkin.layout.json", "w")
if f then
  f:write('{"common": {"cardWidth": 77}}')
  f:close()
  local s2 = Skin.create("/tmp/sgs_skin_test/assets")
  check("显式根目录生效", s2.root == "/tmp/sgs_skin_test/assets", s2.root)
  check("从目录读到 layout", s2:number("common.cardWidth") == 77,
    s2:number("common.cardWidth"))
  os.execute("rm -rf /tmp/sgs_skin_test")
else
  print("  (跳过：/tmp 不可写)")
end

print("\n[5] 根目录不存在时应安全降级，不抛错")
local okCall = pcall(function() return Skin.create("/nonexistent/sgs-assets") end)
check("不抛错", okCall)
local s3 = Skin.create("/nonexistent/sgs-assets")
check("root 为 nil", s3.root == nil, s3.root)
check("查询返回 nil 而非报错", s3:image("photoChain") == nil)
check("number 用默认值", s3:number("common.cardWidth", 42) == 42)

print(string.format("\n===== %d passed, %d failed =====", pass, fail))
os.exit(fail == 0 and 0 or 1)
