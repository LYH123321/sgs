-- 压力测试：大批量种子跑完整对局，验证不会死锁 / 丢牌 / 抛异常
-- 与常规单测分开，因为耗时较长。
-- 运行: love . --soak
if not pcall(require, "love.filesystem") then
  package.path = "./?.lua;" .. package.path
end

local Engine = require "src.core.engine"
local Player = require "src.core.player"
local Standard = require "src.core.standard"
local Room = require "src.core.room"
local Driver = require "src.core.driver"
local Bot = require "src.core.bot"

local N = 25 -- 每种模式跑多少个种子

local failures, passes = 0, 0
local function check(cond, msg)
  if cond then passes = passes + 1 print("PASS  " .. msg)
  else failures = failures + 1 print("FAIL  " .. msg) end
end

local function totalCards(room)
  local n = #room.drawPile + #room.discardPile
  for _, p in ipairs(room.players) do n = n + p:allCardCount() end
  return n
end

local function runGame(build)
  local ok, err = pcall(function()
    local r = build()
    r:start()
    local d = Driver.create(r, Bot.make())
    local adv_ok, adv_err = pcall(function() d:advance() end)
    if not adv_ok then
      print("DBG " .. tostring(adv_err) .. " turns=" .. tostring(r.turn_count)
        .. "  " .. dumpState(r))
      local n = #r.loglines
      for i = math.max(1, n - 18), n do print("    | " .. r.loglines[i]) end
      error(adv_err, 0)
    end
    assert(r.game_over, "对局未结束")
    assert(r.turn_count <= Room.MAX_TURNS, "超过最大回合数")
    assert(totalCards(r) == Standard.deckSize(),
      "卡牌不守恒: " .. totalCards(r) .. " != " .. Standard.deckSize())
    if r.identity_mode and r.winner then
      assert(r.win_role ~= nil, "身份局未判定获胜阵营")
    end
    -- 平局（长时间拉锯）是合法收场，但要在压测里可见。
    -- 注意：反贼获胜时 winner 为 nil、只有 win_role 有值，不能算平局。
    if not r.winner and not r.win_role then
      draws = (draws or 0) + 1
    end
  end)
  return ok, err
end

local function makeDuel(seed)
  local engine = Engine.create()
  Standard.setup(engine)
  local p1 = Player.create("甲", engine:getGeneral("白板武将"), 1, false)
  local p2 = Player.create("乙", engine:getGeneral("剑阁武将"), 2, false)
  local r = Room.create(engine, { p1, p2 })
  r.drawPile = Standard.buildDrawPile(seed)
  r.rng = Standard.makeRng(seed)
  return r
end

local function makeIdentity(seed, n)
  local engine = Engine.create()
  Standard.setup(engine)
  local generals = { "张飞", "曹操", "司马懿", "华佗" }
  local ps = {}
  for i = 1, n do
    local g = engine:getGeneral(generals[((i - 1) % 4) + 1]) or engine:getGeneral("白板武将")
    table.insert(ps, Player.create("P" .. i, g, i, false))
  end
  local r = Room.create(engine, ps)
  r.drawPile = Standard.buildDrawPile(seed)
  r.rng = Standard.makeRng(seed)
  r:setupRoles(Standard.makeRng(seed + 1))
  return r
end

-- 全武将池随机局：武将技能真正的回归网。
-- 上面几组用的是固定武将，新加的武将不会被跑到，容易出现「技能写完但从没执行过」。
-- 指定武将坐 1 号位的身份局：保证每名武将都被真正跑过
local function makeGeneralGame(name, seed)
  local engine = Engine.create()
  Standard.setup(engine)
  local rng = Standard.makeRng(seed + 7)
  local ps = { Player.create("P1", engine:getGeneral(name), 1, false) }
  for i = 2, 4 do
    table.insert(ps, Player.create("P" .. i, Standard.randomGeneral(engine, rng), i, false))
  end
  local r = Room.create(engine, ps)
  r.drawPile = Standard.buildDrawPile(seed)
  r.rng = Standard.makeRng(seed)
  r:setupRoles(Standard.makeRng(seed + 1))
  return r
end

local function makeRandomIdentity(seed, n)
  local engine = Engine.create()
  Standard.setup(engine)
  local rng = Standard.makeRng(seed + 7)
  local ps = {}
  for i = 1, n do
    table.insert(ps, Player.create("P" .. i, Standard.randomGeneral(engine, rng), i, false))
  end
  local r = Room.create(engine, ps)
  r.drawPile = Standard.buildDrawPile(seed)
  r.rng = Standard.makeRng(seed)
  r:setupRoles(Standard.makeRng(seed + 1))
  return r
end

print(string.format("== 压力测试：每种模式 %d 个种子 ==", N))

local function soak(label, builder)
  local bad = {}
  for seed = 1, N do
    local ok, err = runGame(function() return builder(seed) end)
    if not ok then
      table.insert(bad, seed .. ":" .. tostring(err))
    end
  end
  check(#bad == 0, label .. " " .. N .. " 局全部通过"
    .. (#bad == 0 and "" or "（失败: " .. table.concat(bad, " | ") .. "）"))
end

soak("1v1 标准局", makeDuel)
-- 只测 5 人局与 8 人局：5 人为默认规模，8 人为官方标准局
soak("5 人身份局", function(seed) return makeIdentity(seed, 5) end)
soak("8 人身份局", function(seed) return makeIdentity(seed, 8) end)
soak("5 人随机武将身份局", function(seed) return makeRandomIdentity(seed, 5) end)
soak("8 人随机武将身份局", function(seed) return makeRandomIdentity(seed, 8) end)

-- Jev 决策引擎压测（mock 传输，不联网）：验证 questions 构造、
-- answers 映射（含两段式/复核/门控路径）在对局里产出的动作始终合法，
-- 且对局可完结、卡牌守恒。用确定性 responder 模拟 Jev 行为。
print("\n-- Jev 引擎（mock）：" .. N .. " 局 --")
local Agent = require "src.core.ai.agent"
local AiTransport = require "src.core.ai.transport"
local AiJson = require "src.core.json"
local Jev = require "src.core.ai.jev"
local AiActions = require "src.core.ai.actions"
do
  local bad = {}
  for seed = 1, N do
    local ok, err = pcall(function()
      local room = makeIdentity(seed, 5)
      -- 座位 1/3 交给 jev Agent（Driver 才会走 ai 分支）
      for _, seat in ipairs({ 1, 3 }) do
        room.players[seat]:setControl("ai")
      end
      room:start() -- makeIdentity 构造器不自启（runGame 才负责 start）
      -- 模拟 Jev：choice 给最高置信的首个候选；弃牌给中档 score；
      -- 技能给 noul 0.5 以下（保守）；复核恒通过
      local agent = Agent.create({
        engine = "jev",
        transport = AiTransport.mock { responder = function(prompt)
          local ctx = prompt.jev_ctx
          local answers = {}
          if ctx.single then
            local use_id
            for _, a in ipairs(prompt.actions or {}) do
              if a.kind == "use" then use_id = a.id break end
            end
            if not use_id then
              for _, a in ipairs(prompt.actions or {}) do
                if a.kind == "pass" then use_id = a.id break end
              end
            end
            if not use_id then use_id = (prompt.actions or {})[1].id end
            answers.action = { type = "choice", choice = "a" .. use_id,
              confidence = 0.9, probabilities = { ["a" .. use_id] = 0.9 } }
            answers.confirm = { type = "noul", noul = 0.9 }
            for _, a in ipairs(prompt.actions or {}) do
              if a.kind == "use" then
                answers["gain" .. a.id] = { type = "score",
                  probabilities = { ["1"] = 1.0 } }
              end
            end
          elseif ctx.discard then
            for _, id in ipairs(ctx.discard_order or {}) do
              answers["keep" .. id] = { type = "score",
                probabilities = { ["1"] = 1.0 } }
            end
            if prompt.questions["stop"] then
              answers["stop"] = { type = "noul", noul = 0.2 }
            end
          elseif ctx.invoke then
            answers.invoke = { type = "noul", noul = 0.4 }
          end
          return AiJson.encode({ answers = answers })
        end },
      })
      local driver = Driver.create(room, Bot.make(), agent)
      local guard = 0
      while not room.game_over and guard < 200000 do
        guard = guard + 1
        local state, req = driver:advance()
        if state == "over" then break end
        if state == "thinking" then
          local resp, st = agent:respond(req, room)
          local n = 0
          while st == "thinking" and n < 10 do
            resp, st = agent:respond(req, room)
            n = n + 1
          end
          if st == "ready" then room:step(resp) end
        elseif state == "human" then
          room:step(Bot.make()(req, room))
        end
      end
      assert(room.game_over, "对局未结束")
      assert(room.turn_count <= Room.MAX_TURNS, "超过最大回合数")
      assert(totalCards(room) == Standard.deckSize(),
        "卡牌不守恒 " .. totalCards(room) .. " != " .. Standard.deckSize())
      assert(agent.stats.mechanical < agent.stats.by_ai,
        "机械兜底不应超过 jev 决策数（" .. agent.stats.mechanical
        .. " vs " .. agent.stats.by_ai .. "）")
    end)
    if not ok then bad[#bad + 1] = seed .. ":" .. tostring(err) end
  end
  check(#bad == 0, "jev 引擎(mock) " .. N .. " 局全部通过"
    .. (#bad == 0 and "" or "（失败: " .. table.concat(bad, " | ") .. "）"))
end

print("\n-- 逐将覆盖：每名武将各跑 3 局 --")

local Generals = require "src.core.generals"
local roster = Generals.all()
local bad = {}
for _, g in ipairs(roster) do
  for seed = 1, 3 do
    local ok, err = runGame(function() return makeGeneralGame(g.name, seed) end)
    if not ok then table.insert(bad, g.name .. "#" .. seed .. ":" .. tostring(err)) end
  end
end
check(#bad == 0, string.format("%d 名武将各 3 局全部通过", #roster)
  .. (#bad == 0 and "" or "（失败: " .. table.concat(bad, " | ") .. "）"))

if (draws or 0) > 0 then
  print(string.format("注意：有 %d 局以平局收场（长时间拉锯，非死循环）", draws))
end
print(string.format("\n===== 压力测试: %d passed, %d failed =====", passes, failures))
if failures > 0 then error("压力测试失败", 0) end
