-- AI 响应源：完全由 LLM 决策，规则 BOT 不再参与
--
-- 与上一版的关键差别（上一版是「关键决策问 AI，其余走 BOT」）：
--   1. **所有请求都问 AI**，包括出闪/出桃/无懈可击这类高频响应；
--   2. **兜底不再调用规则 BOT**：LLM 抽风时先重试（把错误反馈给它），
--      仍失败就机械地选第一个合法动作 —— 决策始终不是规则脚本做的；
--   3. **跨步骤记忆**：每个座位一份，记录它走过的每一步与做过的身份判断，
--      每次请求都完整回放，让 AI 能积累推理、修正判断。
--
-- 形态仍是异步状态机：首次被问到 → 组提示词 → 提交 → "thinking"；
-- 之后轮询 → 解析 → "ready"。上层（UI 每帧 advance）不需要改结构。
local class = require "src.class"
local Actions = require "src.core.ai.actions"
local Prompt = require "src.core.ai.prompt"
local Parse = require "src.core.ai.parse"
local Jev = require "src.core.ai.jev"
local Memory = require "src.core.ai.memory"
local Card = require "src.core.card"

local Agent = class("Agent")

-- 请求类型 → 给人看的短标签（记忆里用）
local STAGE_ZH = {
  askForUseCard = "出牌",
  askForCard = "响应",
  askForSkillInvoke = "技能",
  askForDiscard = "弃牌",
  askForChooseCard = "选牌",
  askForDiscardFrom = "拆牌",
  askForChoice = "选择",
  askForGuanxing = "观星",
}

-- 把 "2" / "P2" / "座位2" / "曹操" 统一解析成玩家名，供身份判断落库
local function makeNameOf(room)
  return function(key)
    local k = tostring(key)
    local n = k:match("^%d+$") or k:match("^[Pp](%d+)$") or k:match("座位(%d+)")
    if n then
      for _, p in ipairs(room.players) do
        if p.seat == tonumber(n) then return p.name end
      end
      return nil
    end
    for _, p in ipairs(room.players) do
      if p.name == k then return p.name end
    end
    return nil
  end
end

local function playerBySeat(room, seat)
  for _, p in ipairs(room.players) do
    if p.seat == seat then return p end
  end
  return nil
end

function Agent:init(opts)
  opts = opts or {}
  self.transport = opts.transport
  -- 决策引擎："llm"（对话模型，Prompt+Parse 文本路线，默认）
  --           "jev"（TypeSafe System One 决策模型，state+questions 路线）
  --           "mixed"（混合：高频短决策走 jev，出牌/观星等长推理走 llm）
  self.engine = (opts.engine == "jev" or opts.engine == "mixed")
    and opts.engine or "llm"
  -- mixed 模式的第二传输层（jev 用）；按请求类型路由到 engineFor
  self.transport_jev = opts.transport_jev
  -- jev 引擎的置信度门限（choice 低于它走次高概率/机械兜底）
  self.jev_min_confidence = opts.jev_min_confidence or Jev.DEFAULT_MIN_CONFIDENCE
  -- 全部请求都交给 LLM。设 false 可退回「只问决策类请求」的省流模式。
  self.ask_all = opts.ask_all ~= false
  -- 兜底策略，默认 "retry"（重试 + 机械选择），**不会调用规则 BOT**。
  -- 传 "bot" 才会启用旧行为，留给对比测试。
  self.fallback = opts.fallback or "retry"
  self.retries = opts.retries or 1
  self.timeout = opts.timeout or 30
  self.clock = opts.clock or os.time
  self.memory_on = opts.memory ~= false
  self.max_steps = opts.max_steps or 60
  self.on_decision = opts.on_decision
  self.on_error = opts.on_error
  -- on_beliefs(changes, ctx)：身份判断发生变化时回调（UI 展示猜测过程用）。
  --   changes = { {name=, from=, to=} }，ctx = {player=, reason=, turn=}
  -- on_reasoning(player_name, summary)：模型返回思维链摘要时回调（思考开启时才有）
  -- on_probs(player_name, dist)：jev 引擎的概率分布回调。
  --   dist = {probs={ {desc=,p=} top3 }, belief_probs={name→{身份→p}},
  --           confidence=choice 置信度}
  self.on_beliefs = opts.on_beliefs
  self.on_reasoning = opts.on_reasoning
  self.on_probs = opts.on_probs
  -- thinkingLabel 里玩家名的显示形式（UI 注入，如 "AI（张飞）"）；未注入用原名
  self.name_of = opts.name_of
  self.current = nil
  self.memories = {}   -- seat -> Memory
  self.stats = {
    asked = 0, by_ai = 0, retried = 0, mechanical = 0,
    timeouts = 0, errors = {}, rejections = {},
    low_confidence = 0,
  }
end

function Agent:memoryFor(player)
  if not self.memory_on then return nil end
  local key = player.seat or player.name
  if not self.memories[key] then
    self.memories[key] = Memory.create({ seat = player.seat, max_steps = self.max_steps })
  end
  return self.memories[key]
end

-- ===== 对外：回答一个请求 =====
-- 返回 (响应, "ready") 或 (nil, "thinking")
--
-- 整体包一层 pcall：只要 AI 这一层不往外抛异常，Driver 里那条
-- 「AI 出错就用规则 BOT」的保险就永远不会触发（见 driver.lua 的 _askAI）。
-- 这是「规则 BOT 退出决策路径」的最后一块拼图——异常路径上也没有 BOT。
function Agent:respond(req, room)
  local ok, resp, state = pcall(function()
    return self:_respond(req, room)
  end)
  if ok then return resp, state end
  return self:_mechanical(req, room, "内部异常：" .. tostring(resp)), "ready"
end

-- mixed 模式的路由表：这些请求类型走 jev（快、便宜、单次判定），
-- 其余（出牌 askForUseCard / 观星 askForGuanxing 这类长推理）走 llm。
-- 响应牌/技能征询/弃牌/选牌是「几秒内可判断」的原子决策，正是
-- System One 的设计场景；身份推测也只在 llm 路径的输出里产生。
local MIXED_JEV_TYPES = {
  askForCard = true,
  askForSkillInvoke = true,
  askForDiscard = true,
  askForChooseCard = true,
  askForDiscardFrom = true,
  askForChoice = true,
}

-- 本次请求实际使用的引擎（mixed 按类型路由，其他引擎恒定）
function Agent:_engineFor(req)
  if self.engine ~= "mixed" then return self.engine end
  if MIXED_JEV_TYPES[req.type] and self.transport_jev then
    return "jev"
  end
  return "llm"
end

-- 本次请求实际使用的传输层（与 _engineFor 对应）
function Agent:_transportFor(req)
  if self:_engineFor(req) == "jev" then
    return self.transport_jev or self.transport
  end
  return self.transport
end

function Agent:_respond(req, room)
  if not self.transport then
    return self:_mechanical(req, room, "未配置传输层"), "ready"
  end
  if not Actions.worthAsking(req, { all_requests = self.ask_all }) then
    return self:_mechanical(req, room, "该请求类型未开启 LLM"), "ready"
  end

  local cur = self.current
  if not (cur and cur.req == req) then
    return self:_start(req, room)
  end
  return self:_poll(req, room)
end

function Agent:_buildPrompt(req, room, actions, memory, hint, engine)
  if engine == "jev" then
    -- Jev 无文本生成，重试没有意义（同样的问题大概率同样的答案），
    -- hint 只进 state 供参考
    return Jev.build(room, req, actions, {
      memory = memory,
      nameOf = makeNameOf(room),
      beliefs = self.jev_beliefs_on,
      retry_hint = hint,
    })
  end
  return Prompt.build(room, req, actions, {
    memory = memory,
    nameOf = makeNameOf(room),
    retry_hint = hint,
  })
end

function Agent:_start(req, room, hint)
  local actions = Actions.enumerate(req, room)
  if #actions == 0 then
    -- 一个候选都没有：不是 LLM 的问题，直接机械应答（通常是「结束出牌」）
    return self:_mechanical(req, room, "没有可行动作"), "ready"
  end
  local memory = self:memoryFor(req.player)
  local engine = self:_engineFor(req)
  local transport = self:_transportFor(req)
  local prompt = self:_buildPrompt(req, room, actions, memory, hint, engine)
  self.stats.asked = self.stats.asked + 1
  if not transport:submit(prompt) then
    return self:_retryOrMechanical(req, room, "提交请求失败")
  end
  self.current = {
    req = req, actions = actions, prompt = prompt,
    memory = memory, attempt = 1, started = self.clock(),
    engine = engine, transport = transport,
  }
  return nil, "thinking"
end

function Agent:_poll(req, room)
  local cur = self.current
  if not cur then return self:_mechanical(req, room, "状态丢失"), "ready" end
  local transport = cur.transport or self.transport

  if self.clock() - cur.started > self.timeout then
    self.stats.timeouts = self.stats.timeouts + 1
    if transport.cancel then transport:cancel() end
    return self:_retryOrMechanical(req, room,
      string.format("超过 %d 秒未返回", self.timeout))
  end

  local res = transport:poll()
  if not res then return nil, "thinking" end
  if not res.ok then
    return self:_retryOrMechanical(req, room, res.err or "调用失败")
  end

  local resp, err, extra
  local used_engine = cur.engine or self.engine
  if used_engine == "jev" then
    local answers, aerr = Jev.answersFrom(res.text)
    if not answers then
      err = aerr
    else
      resp, err, extra = Jev.map(answers, req, room, cur.actions,
        cur.prompt.jev_ctx, self.jev_min_confidence)
      if err then
        self.stats.low_confidence = self.stats.low_confidence + 1
      end
    end
    if err then
      -- 附当时的候选分布（低置信时 map 在 extra.fallback_dist 里带回）：
      -- 「决策未通过」只有原因没有内容，排查时不知道 Jev 当时想选什么
      local dist = extra and extra.fallback_dist
      if dist and dist ~= "" then
        print(string.format("[AI/jev] 决策未通过（%s）｜当时候选：%s",
          tostring(err), dist))
      else
        print(string.format("[AI/jev] 决策未通过（%s）", tostring(err)))
      end
      self.stats.rejections[#self.stats.rejections + 1] = tostring(err)
      if #self.stats.rejections > 20 then table.remove(self.stats.rejections, 1) end
      -- Jev 是无状态决策器，重问同一问题没有意义：直接走机械兜底
      self.current = nil
      return self:_mechanical(req, room, "jev：" .. tostring(err)), "ready"
    end
  else
    resp, err, extra = Parse.response(res.text, req, room, cur.actions)
    if err then
      -- 解析失败时把原始输出打到终端：不同模型/网关的输出形态差异大
      -- （如推理模型把答案藏进 reasoning_content），没有原文无从排查
      print(string.format("[AI] 解析失败（%s），原始输出 %d 字节：\n%s",
        tostring(err), #tostring(res.text), tostring(res.text)))
      self.stats.rejections[#self.stats.rejections + 1] = err
      if #self.stats.rejections > 20 then table.remove(self.stats.rejections, 1) end
      return self:_retryOrMechanical(req, room, err)
    end
  end

  self.stats.by_ai = self.stats.by_ai + 1
  self:_remember(req, room, cur, resp, extra)
  if res.reasoning and self.on_reasoning then
    pcall(self.on_reasoning, req.player.name, res.reasoning)
  end
  -- jev 引擎：结构化概率分布 → UI 推测面板（替代 LLM 的思维链文本）
  if used_engine == "jev" and self.on_probs and extra then
    if extra.probs or extra.belief_probs then
      pcall(self.on_probs, req.player.name, {
        probs = extra.probs, belief_probs = extra.belief_probs,
        confidence = extra.confidence,
      })
    end
  end
  if self.on_decision then
    pcall(self.on_decision, {
      req = req, room = room, raw = res.text, resp = resp, extra = extra,
      prompt = cur.prompt, actions = cur.actions, memory = cur.memory,
      reasoning = res.reasoning,
    })
  end
  self.current = nil
  return resp, "ready"
end

-- 给上游报错补一句人话提示。模型不支持 Responses 协议时（TokenHub 的
-- glm-5 等），网关报错原文很长且是英文，玩家最需要的是「怎么改」。
function Agent.protocolHint(reason)
  if type(reason) ~= "string" then return reason end
  if reason:find("not support", 1, true) and reason:find("Responses", 1, true) then
    return reason
      .. " ← 该模型可能不支持 Responses 协议：直连把 SGS_AI_URL 换成"
      .. " …/v1/chat/completions；代理模式在**游戏**的终端"
      .. " export SGS_AI_PROTOCOL=chat（代理会自动跟随端点，无需改代理侧）"
  end
  -- chat 协议的 thinking 字段（GLM 系思维链开关）不被网关接受时，
  -- 指引逃生口：auto = 不发该字段
  if reason:find("thinking", 1, true) and (
      reason:find("nrecognized", 1, true) or reason:find("nknown", 1, true)
      or reason:find("nvalid", 1, true)) then
    return reason
      .. " ← 网关可能不认识 thinking 参数：export SGS_AI_THINKING=auto"
      .. " 可改为不发该字段（代价：chat 模型无法关思维链，会较慢）"
  end
  return reason
end

-- 重试：把上一次的失败原因回喂给模型，让它自己纠正。
function Agent:_retryOrMechanical(req, room, reason)
  local cur = self.current
  local attempt = cur and cur.attempt or 1
  reason = Agent.protocolHint(reason)
  self.stats.errors[#self.stats.errors + 1] = tostring(reason)
  if #self.stats.errors > 30 then table.remove(self.stats.errors, 1) end
  if self.on_error then pcall(self.on_error, reason, req) end
  if cur then cur.attempt = attempt + 1 end

  if cur and attempt <= self.retries then
    self.stats.retried = self.stats.retried + 1
    local prompt = self:_buildPrompt(req, room, cur.actions, cur.memory,
      string.format("你上一次的输出无法使用（%s）。请只输出符合格式的一行 JSON，"
        .. "action 必须是后面列出的编号之一。", tostring(reason)),
      cur.engine or self.engine)
    local transport = cur.transport or self.transport
    if transport:submit(prompt) then
      cur.prompt = prompt
      cur.started = self.clock()
      return nil, "thinking"
    end
  end

  self.current = nil
  return self:_mechanical(req, room, reason), "ready"
end

-- 机械兜底：**不调用规则 BOT**。
--
-- 为什么是「被动」而不是「选第一个合法动作」：模型失联时，
-- 「乱出一张牌」比「什么都不做」危险得多——前者可能把桃/无懈可击
-- 在错误时机打出去，后者最多就是这一手没动作。所以：
--   - 出牌/响应（askForUseCard / askForCard）→ 被动放弃（nil）
--   - 技能征询 → 不发动
--   - 必须给牌/选牌的（弃牌/五谷/拆牌/选项）→ 机械执行，否则会违规卡死
function Agent:_mechanical(req, room, reason)
  self.stats.mechanical = self.stats.mechanical + 1
  -- current 可能是上一个请求遗留的（比如 transport 失效时），
  -- 只在与当前请求匹配时才复用它的候选，否则重新枚举
  local actions
  if self.current and self.current.req == req then
    actions = self.current.actions
  else
    actions = Actions.enumerate(req, room)
  end

  if req.type == "askForSkillInvoke" then return false end
  if req.type == "askForGuanxing" then return nil end -- 观星：nil = 保持原序（引擎约定）
  if req.type == "askForDiscard" then
    -- any 模式（制衡类自选）：机械兑底选**不弃**（空表）——最安全
    if req.any then return {} end
    local out = {}
    for _, a in ipairs(actions) do
      if a.kind == "discard" and #out < (req.n or 0) then out[#out + 1] = a.card end
    end
    return out
  end
  if req.type == "askForChooseCard" or req.type == "askForDiscardFrom" then
    for _, a in ipairs(actions) do
      if a.kind == "choose" then return a.card end
    end
    return nil
  end
  if req.type == "askForChoice" then
    for _, a in ipairs(actions) do
      if a.kind == "choice" then return a.value end
    end
    return nil
  end
  return nil   -- askForUseCard / askForCard：被动放弃，不乱出牌
end

-- ===== 记忆 =====

local function describeChoice(req, resp)
  if req.type == "askForUseCard" then
    if resp == nil then return "结束出牌" end
    local t = resp.target
    if t == req.player then return string.format("使用【%s】", resp.card:zhName()) end
    return string.format("使用【%s】→%s", resp.card:zhName(), t and t.name or "?")
  elseif req.type == "askForCard" then
    if resp == nil then
      return string.format("不打出【%s】", Card.ZH[req.card_name] or req.card_name)
    end
    return string.format("打出【%s】", resp:zhName())
  elseif req.type == "askForSkillInvoke" then
    return resp and string.format("发动【%s】", tostring(req.skill))
      or string.format("不发动【%s】", tostring(req.skill))
  elseif req.type == "askForDiscard" then
    local names = {}
    for _, c in ipairs(resp or {}) do names[#names + 1] = c:zhName() end
    return "弃置 " .. (#names > 0 and table.concat(names, "") or "无")
  elseif req.type == "askForDiscardFrom" then
    return resp and ("弃掉 " .. resp:zhName()) or "未弃牌"
  elseif req.type == "askForChooseCard" then
    return resp and ("拿了 " .. resp:zhName()) or "没拿"
  elseif req.type == "askForChoice" then
    return tostring(resp)
  elseif req.type == "askForGuanxing" then
    if resp == nil then return "观星：保持原序" end
    local top = {}
    for i = #(resp.up or {}), 1, -1 do top[#top + 1] = resp.up[i]:zhName() end
    return "观星重排：顶=" .. (#top > 0 and table.concat(top, "") or "无")
      .. string.format("（%d 张沉底）", #(resp.down or {}))
  end
  return "（已响应）"
end

function Agent:_remember(req, room, cur, resp, extra)
  local mem = cur.memory
  if not mem then return end
  mem:record({
    turn = room.turn_count,
    stage = STAGE_ZH[req.type] or req.type,
    choice = describeChoice(req, resp),
    reason = (extra and extra.reason) or "",
  })
  if extra and extra.beliefs then
    local changes = mem:updateBeliefs(extra.beliefs, makeNameOf(room), {
      turn = room.turn_count, reason = extra.reason,
    })
    if #changes > 0 and self.on_beliefs then
      pcall(self.on_beliefs, changes, {
        player = req.player, reason = extra.reason, turn = room.turn_count,
      })
    end
  end
  if extra and extra.note then mem:setNotes(extra.note) end
end

-- ===== 给 UI 的状态查询 =====

function Agent:isThinking()
  return self.current ~= nil
end

function Agent:thinkingLabel()
  local cur = self.current
  if not cur then return nil end
  local r = cur.prompt and cur.prompt.view and cur.prompt.view.request
  -- 显示名可由 UI 注入（name_of）：牌桌上按控制模式显示 AI（武将）/BOT（武将），
  -- 与面板一致；未注入时退回 player.name
  local who = self.name_of and self.name_of(cur.req.player) or cur.req.player.name
  local base = string.format("%s 正在思考：%s", who, (r and r.ask) or cur.req.type)
  if cur.attempt and cur.attempt > 1 then
    return base .. string.format("（第 %d 次尝试）", cur.attempt)
  end
  return base
end

Agent.STAGE_ZH = STAGE_ZH

return Agent
