-- Jev 决策引擎：TypeSafe System One 模型的请求构造与答案映射
--
-- 与对话 LLM 的根本差异：Jev 不生成文本。输入是 state（程序状态文本）
-- + questions（choice/score/noul 三种类型化原语），输出是结构化决策
-- + 校准概率。因此本模块替代 Prompt+Parse 的职责，而动作枚举、观察层、
-- 记忆、机械兜底全部复用现有实现：
--
--   Actions.enumerate   候选 → choice 的 criteria / score 的问题
--   View.build + Memory state 文本（Jev 无 system 消息，规则前缀并入 state）
--   Parse 复用动作→响应的映射段（choiceKey→id→Parse.response 的正规路线）
--
-- 设计要点（见 docs/JEV接入方案.md）：
--   1. 单选请求用一个 choice（criteria = a<id> → 候选描述）；
--   2. 多选弃牌每张牌一个并行 score，代码按概率期望取 top-N；
--   3. askForSkillInvoke 用一个 noul（阈值 0.5）；
--   4. choice 置信度低于阈值时：高风险不再复核（一期简化，直接走
--      次高概率→机械兜底的降级链）；
--   5. 身份推测并行提问，但答案需矛盾调和（主公只有一个）。
local class = require "src.class"
local View = require "src.core.ai.view"
local Parse = require "src.core.ai.parse"
local Json = require "src.core.json"

local Jev = {}

-- state 头部的规则前缀：对话版的 Prompt.SYSTEM 浓缩版。
-- Jev 是无状态服务，每次调用都要带上规则语义。
Jev.RULES = [[你在玩三国杀标准身份局，根据当前局面做决策。
身份目标：主公与忠臣要消灭反贼和内奸；反贼要杀主公；内奸先清场再单挑主公。未亮明的身份只能靠行为推断。
规则要点：出牌阶段默认一张【杀】；攻击范围默认 1；体力 0 需要有人出【桃】救援；弃牌阶段手牌数不得超过体力值。]]

-- choice 的置信度门限：低于它就先试次高概率候选（同样要达标），
-- 都不行走机械兜底。Jev 的 confidence 是校准的（高置信=高准确），
-- 这是它比「让 LLM 自报置信度」可靠的原因。
Jev.DEFAULT_MIN_CONFIDENCE = 0.35

-- noul（是否发动技能）的决策阈值
Jev.INVOKE_THRESHOLD = 0.5

-- 出牌候选超过该值触发两段式（choice 基数官方上限 255，留余量）
Jev.MAX_CHOICES = 200

-- ============ state 组装 ============

-- 把 View.build 的结构化观察压成中文文本。与 prompt.lua 的 dumpState
-- 语义一致但独立实现：Jev 的 state 要短而密（按输入 token 计费，
-- 输出免费），不追求给「阅读者」排版，只给「决策者」信息。
local function dumpState(view)
  local me = view.me
  local lines = {}
  lines[#lines + 1] = string.format("第%d轮 %s阶段 存活%d人 牌堆%d张",
    view.turn, me.phase or "?", view.alive_count, view.draw_pile)
  lines[#lines + 1] = string.format("你=%s(%s) 身份:%s 体力%d/%d 攻击范围%d 技能:%s",
    me.name, me.general, me.role, me.hp, me.max_hp, me.attack_range,
    (#(me.skills or {}) > 0) and table.concat(me.skills, "、") or "无")
  if #me.hand > 0 then
    local parts = {}
    for i, c in ipairs(me.hand) do
      parts[#parts + 1] = string.format("%d)%s%d-%s", i, c.suit, c.number, c.zh)
    end
    lines[#lines + 1] = "手牌:" .. table.concat(parts, " ")
  else
    lines[#lines + 1] = "手牌:无"
  end
  for _, e in ipairs(me.equips or {}) do
    lines[#lines + 1] = string.format("装备[%s]:%s", e.slot_zh, e.card.zh)
  end
  for _, j in ipairs(me.judges or {}) do
    lines[#lines + 1] = "判定区:" .. j.zh
  end
  for _, o in ipairs(view.others) do
    local eq = {}
    for _, e in ipairs(o.equips or {}) do eq[#eq + 1] = e.card.zh end
    local jd = {}
    for _, j in ipairs(o.judges or {}) do jd[#jd + 1] = j.zh end
    lines[#lines + 1] = string.format("%d号位%s(%s)%s 体力%d/%d 手牌%d 距离%d%s%s%s",
      o.seat, o.name, o.general, o.role, o.hp, o.max_hp, o.hand_count, o.distance,
      o.alive and "" or "[阵亡]",
      (#eq > 0) and (" 装备:" .. table.concat(eq, "、")) or "",
      (#jd > 0) and (" 判定:" .. table.concat(jd, "、")) or "")
  end
  if #(view.log or {}) > 0 then
    lines[#lines + 1] = "最近战况:"
    for _, l in ipairs(view.log) do lines[#lines + 1] = "  " .. l end
  end
  return table.concat(lines, "\n")
end

-- ============ questions 构造 ============

local function choiceKey(id) return "a" .. id end

-- 单选类请求：一个 choice 问题，criteria = 动作编号 → 描述。
-- 高基数两段式：候选超过 MAX_CHOICES（choice 基数官方上限 255，留余量）
-- 时，choice 的 criteria 只保留**代表子集**——同牌名只留首个目标（首目标
-- 均为距离/体力最优的枚举序），pass 恒保留；同时给全部候选并行 score
-- 「进攻/使用收益」，映射阶段若 score 的 top 不在 choice 集里则改用
-- score 结果（等价于两段式：先打分后精选，且仍是一次 API 调用）。
local USE_GAIN_RUBRIC = {
  "负收益或无意义",
  "收益一般，可有可无",
  "收益明显，值得使用",
}
local function singleChoiceQuestion(req, actions)
  local criteria = {}
  local has_pass = false
  local seen_name = {}
  local pruned = false
  local n_crit = 0
  for _, a in ipairs(actions) do
    local keep = true
    if a.kind == "use" and #actions > Jev.MAX_CHOICES then
      -- 两段式裁剪：同 card.name（转化技按生成牌名）只留一个目标
      local key = a.card and a.card.name or ("id" .. a.id)
      if seen_name[key] then
        keep = false
        pruned = true
      else
        seen_name[key] = true
      end
    end
    if keep then
      criteria[choiceKey(a.id)] = a.desc
      n_crit = n_crit + 1
      if a.kind == "pass" then has_pass = true end
    end
  end
  local r = View.requestBrief(req)
  local q = {
    type = "choice",
    instructions = "当前需要决定：" .. (r and r.ask or "选择一个动作")
      .. "。从下列合法动作中选出对达成你的身份目标最优的一个。",
    criteria = criteria,
  }
  return q, has_pass, pruned, n_crit
end

-- 两段式的并行 score 问题：全部 use 候选的收益评估（choice 被裁剪时，
-- score 覆盖全集，映射时可以恢复被裁掉的候选）
local function gainQuestions(req, actions, questions)
  local order = {}
  for _, a in ipairs(actions) do
    if a.kind == "use" then
      questions["gain" .. a.id] = {
        type = "score",
        instructions = "评估动作「" .. a.desc .. "」在当前局面下的使用收益",
        criteria = USE_GAIN_RUBRIC,
      }
      order[#order + 1] = a.id
    end
  end
  return order
end

-- 技能发动：noul 直接问值不值得
local function invokeQuestion(req)
  return {
    type = "noul",
    instructions = string.format("当前局面下发动技能【%s】对你达成身份目标有利（含技能成本与风险的考量）",
      tostring(req.skill)),
  }
end

-- 弃牌：每张牌一个并行 score。rubric 从低到高 = 保留价值从低到高。
local DISCARD_RUBRIC = {
  "价值最低，优先弃置",
  "价值一般，可以弃置",
  "关键牌，尽量保留",
}
local function discardQuestions(req, actions)
  local questions = {}
  local order = {}
  for _, a in ipairs(actions) do
    if a.kind == "discard" then
      questions["keep" .. a.id] = {
        type = "score",
        instructions = "评估手牌「" .. a.desc .. "」在当前局面与你武将技能下的保留价值",
        criteria = DISCARD_RUBRIC,
      }
      order[#order + 1] = a.id
    end
  end
  if req.any then
    questions["stop"] = {
      type = "noul",
      instructions = "当前已无值得继续弃置的牌（继续弃会损失价值）",
    }
  end
  return questions, order
end

-- 身份推测：对每个身份未知的存活他人问一个 choice。
-- 返回 questions 与座位上下文（映射时做矛盾调和）。
-- 注意：choice 的 criteria 必须是**字典**（key→描述），传数组会被
-- API 422 拒绝（Input should be a valid dictionary）——实测踩过。
local BELIEF_OPTIONS = { "主公", "忠臣", "反贼", "内奸" }
local function beliefCriteria()
  local t = {}
  for i, label in ipairs(BELIEF_OPTIONS) do t["r" .. i] = label end
  return t
end
-- rN key → 中文身份。中文字面量原样放行（mock/旧响应兼容）。
local BELIEF_KEYS = {}
for i, label in ipairs(BELIEF_OPTIONS) do BELIEF_KEYS["r" .. i] = label end
for _, label in ipairs(BELIEF_OPTIONS) do BELIEF_KEYS[label] = label end
local function beliefLabelOf(key)
  return BELIEF_KEYS[tostring(key)]
end
local function beliefQuestions(view)
  local questions, targets = {}, {}
  for _, o in ipairs(view.others) do
    if o.alive and o.role == "未知" then
      questions["belief" .. o.seat] = {
        type = "choice",
        instructions = string.format(
          "根据行为推断%d号位%s(%s)最可能的隐藏身份（结合战况与你的决策史）",
          o.seat, o.name, o.general),
        criteria = beliefCriteria(),
      }
      targets[#targets + 1] = o
    end
  end
  return questions, targets
end

-- ============ 答案映射 ============

-- 单选：choice → 置信度门控 → 动作 id。
-- 返回 (id, nil) / (nil, err, "invalid"|"lowconf")。
--   invalid：答案根本不在候选集合内（API 违约），必须报错走机械兜底；
--   lowconf：答案合法但置信度不足，可走保守 pass 或次高概率。
local function pickChoice(answer, actions, min_conf)
  if type(answer) ~= "table" or answer.type ~= "choice" then
    return nil, "答案缺失或类型不对", "invalid"
  end
  local probs = answer.probabilities or {}
  local function idOf(key)
    local n = tostring(key):match("^a(%d+)$")
    return n and tonumber(n) or nil
  end
  -- 概率降序排列候选
  local ranked = {}
  for key, p in pairs(probs) do
    local id = idOf(key)
    if id and actions[id] and type(p) == "number" then
      ranked[#ranked + 1] = { id = id, p = p }
    end
  end
  table.sort(ranked, function(x, y) return x.p > y.p end)
  if #ranked == 0 then return nil, "答案不在候选集合内", "invalid" end
  if (answer.confidence or 0) >= min_conf then return ranked[1].id end
  for i = 2, #ranked do
    if ranked[i].p >= min_conf then
      return ranked[i].id, string.format("低置信%.2f取次高", answer.confidence or 0), "lowconf"
    end
  end
  return nil, string.format("置信度%.2f低于阈值%.2f", answer.confidence or 0, min_conf), "lowconf"
end

-- 弃牌：score 的 probabilities 算保留期望（等级越高越要留），
-- 升序取前 n 张弃。any 模式：stop noul ≥ 阈值 或 所有牌期望都高 → 空表。
local KEEP_WEIGHTS = { 0.0, 0.5, 1.0 }
local function pickDiscard(answers, order, req, actions, n)
  local scored = {}
  for _, id in ipairs(order) do
    local a = answers["keep" .. id]
    local probs = (a and a.probabilities) or {}
    local ev = 0
    for lv, w in pairs(KEEP_WEIGHTS) do
      ev = ev + (probs[tostring(lv - 1)] or 0) * w
    end
    scored[#scored + 1] = { id = id, ev = ev }
  end
  table.sort(scored, function(x, y) return x.ev < y.ev end)
  local out = {}
  if req.any then
    local stop = answers["stop"]
    local stop_val = stop and stop.noul or 0
    if stop_val >= Jev.INVOKE_THRESHOLD then return {} end
    -- 期望低于中档(0.5)的才弃；一张都不值得弃就选「不弃」
    for _, s in ipairs(scored) do
      if s.ev < 0.5 and #out < (n or 0) then out[#out + 1] = s.id end
    end
    return out
  end
  for i = 1, math.min(n or 0, #scored) do out[i] = scored[i].id end
  return out
end

-- 身份推测调和：同一身份多人时只保留概率最高者，其余降级为 nil
-- （映射时不写回，保持原判断）。主公必唯一是硬约束。
local function reconcileBeliefs(answers, targets)
  local picks = {}
  local best = {}   -- label -> {p, seat}
  for _, o in ipairs(targets) do
    local a = answers["belief" .. o.seat]
    if type(a) == "table" and a.probabilities then
      local top_label, top_p
      for key, p in pairs(a.probabilities) do
        -- criteria 是 rN→身份 的字典，probabilities 的 key 同为 rN
        local label = beliefLabelOf(key)
        if label and type(p) == "number" and (not top_p or p > top_p) then
          top_label, top_p = label, p
        end
      end
      if top_label then
        picks[o.seat] = { label = top_label, p = top_p }
        local b = best[top_label]
        if not b or top_p > b.p then
          if b then picks[b.seat] = nil end
          best[top_label] = { p = top_p, seat = o.seat }
        else
          picks[o.seat] = nil
        end
      end
    end
  end
  return picks
end

-- ============ 对外主接口 ============

-- 构造一次 Jev 请求。返回 {state=, questions=} 表（transport 的 jev
-- 分支会加上 model 字段后 JSON 化），附 build 上下文供映射阶段使用。
-- prompt 形态上与 LLM 路径一致（submit(prompt) 的参数），便于复用 Mock。
function Jev.build(room, req, actions, opts)
  opts = opts or {}
  local view = View.build(room, req, opts)
  local state_parts = { Jev.RULES, "", dumpState(view) }
  if opts.memory then
    state_parts[#state_parts + 1] = ""
    state_parts[#state_parts + 1] = opts.memory:render(opts.nameOf)
  end

  local questions = {}
  local ctx = { view = view, single = false, discard = false }

  if req.type == "askForDiscard" then
    ctx.discard = true
    local qs, order = discardQuestions(req, actions)
    for k, q in pairs(qs) do questions[k] = q end
    ctx.discard_order = order
  elseif req.type == "askForSkillInvoke" then
    ctx.invoke = true
    questions["invoke"] = invokeQuestion(req)
  else
    ctx.single = true
    local q, has_pass, pruned, n_crit = singleChoiceQuestion(req, actions)
    questions["action"] = q
    ctx.has_pass = has_pass
    ctx.pruned = pruned
    if pruned then
      ctx.gain_order = gainQuestions(req, actions, questions)
    end
    -- 高风险复核：choice 选了高风险动作时，用并行的 confirm noul
    -- 再确认一次（决斗/救桃给反贼/南蛮万箭这类可能引火烧身的决策）。
    -- 复核在同一调用里完成（Jev 并行求值），映射阶段按动作类别检查。
    questions["confirm"] = {
      type = "noul",
      instructions = "你选定的动作虽然是收益最大的，但其风险（被反杀、"
        .. "救活敌人、浪费关键牌、暴露身份引来集火）仍然可以接受",
    }
  end

  -- 身份推测（可选并行问题，不参与本次动作映射）
  ctx.beliefs_on = opts.beliefs ~= false
  local belief_qs, belief_targets = {}, {}
  if ctx.beliefs_on then
    belief_qs, belief_targets = beliefQuestions(view)
    for k, q in pairs(belief_qs) do questions[k] = q end
  end
  ctx.belief_targets = belief_targets

  return {
    state = table.concat(state_parts, "\n"),
    questions = questions,
    -- 供 Agent 侧 map 与测试断言使用（不发给服务端）
    jev_ctx = ctx,
    actions = actions,
    view = view,
  }
end

-- 把 Jev 响应 JSON 映射成引擎响应。answers = data.answers 表。
-- 返回与 Parse.response 相同的三元组 (resp, err, extra)；extra 额外带
-- probs（动作概率分布）与 belief_probs（各座位身份概率），供 UI 展示。
-- err 走 Agent 现有降级链（重试关闭时直接机械兜底）。
function Jev.map(answers, req, room, actions, build_ctx, min_conf)
  if type(answers) ~= "table" then return nil, "answers 缺失" end
  min_conf = min_conf or Jev.DEFAULT_MIN_CONFIDENCE
  local extra = {}

  -- 身份推测（先算，任何路径都要带上）
  local picks = reconcileBeliefs(answers, build_ctx.belief_targets or {})
  local beliefs = {}
  local belief_probs = {}
  local seat_to_name = {}
  for _, p in ipairs(room.players) do seat_to_name[p.seat] = p.name end
  for seat, pick in pairs(picks) do
    local name = seat_to_name[seat]
    if name then beliefs[name] = pick.label end
  end
  for _, o in ipairs(build_ctx.belief_targets or {}) do
    local a = answers["belief" .. o.seat]
    if type(a) == "table" and type(a.probabilities) == "table" then
      local name = seat_to_name[o.seat]
      if name then
        -- rN key 转回中文身份，UI 直接显示
        local by_label = {}
        for key, p in pairs(a.probabilities) do
          local label = beliefLabelOf(key)
          if label and type(p) == "number" then by_label[label] = p end
        end
        if next(by_label) then belief_probs[name] = by_label end
      end
    end
  end
  if next(beliefs) then extra.beliefs = beliefs end
  if next(belief_probs) then extra.belief_probs = belief_probs end

  if build_ctx.discard then
    local ids = pickDiscard(answers, build_ctx.discard_order, req, actions,
      req.n or 0)
    if not ids or #ids == 0 then
      if req.any then return {}, nil, extra end
      return nil, "弃牌映射未得到任何牌"
    end
    -- 复用 Parse 的 discard 映射（含重复/数量校验）：伪造 LLM 形态输出
    local raw = Json.encode({ actions = ids })
    local resp, derr = Parse.response(raw, req, room, actions)
    if derr then return nil, derr end
    return resp, nil, extra
  end

  if build_ctx.invoke then
    local a = answers["invoke"]
    local v = a and a.noul or 0
    local want = v >= Jev.INVOKE_THRESHOLD
    -- 发动/不发动在候选里固定为 value=true/false 的 invoke 动作
    for _, act in ipairs(actions) do
      if act.kind == "invoke" and act.value == want then
        local resp, perr = Parse.response(
          Json.encode({ action = act.id }), req, room, actions)
        if perr then return nil, perr end
        return resp, nil, extra
      end
    end
    return nil, nil, extra
  end

  -- 单选路径
  local a = answers["action"]
  local id, note, mode = pickChoice(a, actions, min_conf)

  -- 两段式恢复：choice 被 prune 后，score 的 top 若优于 choice 结果，
  -- 用 score 期望最高的候选（gain score 与 choice 在同一次调用里并行，
  -- score 覆盖未被裁剪的全集）
  if id and build_ctx.pruned and build_ctx.gain_order then
    local GAIN_W = { 0.0, 0.5, 1.0 }
    local best_ev, best_id = -1, nil
    for _, gid in ipairs(build_ctx.gain_order) do
      local g = answers["gain" .. gid]
      local gp = g and g.probabilities or {}
      local ev = 0
      for lv, w in pairs(GAIN_W) do
        ev = ev + (gp[tostring(lv - 1)] or 0) * w
      end
      if ev > best_ev then best_ev, best_id = ev, gid end
    end
    -- score 全票高收益（≥0.9）且与 choice 不同：score 更可信（未被裁剪）
    if best_id and best_id ~= id and best_ev >= 0.9 then
      extra.reason = string.format("两段式score改判（期望%.2f）", best_ev)
      id = best_id
    end
  end

  -- 高风险复核：confirm noul 否定且存在 pass → 保守放弃。
  -- 复核只拦「主动使用」（use）；pass 本身无风险，不需要复核。
  if id then
    local act = actions[id]
    if act and act.kind == "use" then
      local confirm = answers["confirm"]
      local ok = confirm and confirm.noul
      if ok ~= nil and ok < Jev.INVOKE_THRESHOLD and build_ctx.has_pass then
        extra.reason = string.format("复核未过（%.2f），保守放弃", ok)
        for _, pact in ipairs(actions) do
          if pact.kind == "pass" then
            id = pact.id
            break
          end
        end
      end
    end
  end

  if not id then
    if mode == "lowconf" then
      -- 低置信但答案合法：存在「pass/不打出」类候选时宁可保守，
      -- 也不交给机械兜底乱选（机械路径可能挑出动作而不是放弃）
      if build_ctx.has_pass then
        for _, act in ipairs(actions) do
          if act.kind == "pass" then
            local resp, perr = Parse.response(
              Json.encode({ action = act.id }), req, room, actions)
            if perr then return nil, perr end
            return resp, nil, extra
          end
        end
      end
    end
    -- invalid（API 违约）或低置信且无 pass：报错走机械兜底
    return nil, note or "单选映射失败", extra
  end
  if note then extra.reason = note end
  -- top 概率写进 reason（记忆里能看到为什么）
  local probs = a and a.probabilities or {}
  local top_p = probs[choiceKey(id)]
  if top_p then extra.reason = string.format("概率%.0f%%", top_p * 100) end
  -- 动作概率分布（UI 推测面板用）：top3 + 中文描述
  local ranked = {}
  for key, p in pairs(probs) do
    local n = tostring(key):match("^a(%d+)$")
    local aid = n and tonumber(n)
    if aid and actions[aid] and type(p) == "number" then
      ranked[#ranked + 1] = { id = aid, p = p, desc = actions[aid].desc }
    end
  end
  table.sort(ranked, function(x, y) return x.p > y.p end)
  extra.probs = {}
  for i = 1, math.min(3, #ranked) do extra.probs[i] = ranked[i] end
  if a.confidence then extra.confidence = a.confidence end
  local resp, serr = Parse.response(Json.encode({ action = id }), req, room, actions)
  if serr then return nil, serr end
  return resp, nil, extra
end

-- 从原始响应文本里取 answers 表（transport.parseResponse 的 jev 分支
-- 会把整个 JSON 文本放回 text；这里负责解出 answers）。
function Jev.answersFrom(text)
  local data = type(text) == "string" and Json.decode(text)
  if type(data) ~= "table" then return nil, "响应不是合法 JSON" end
  if data.error then
    local e = data.error
    return nil, "接口错误：" .. tostring(type(e) == "table" and (e.message or e.code) or e)
  end
  -- FastAPI 风格的 422 校验错误：{"detail":[{type,loc,msg},...]}。
  -- 不识别它会被误报成「响应缺少 answers」，真正的拒绝原因（如 criteria
  -- 类型不对）全被吞掉——实测踩过：belief 的 criteria 传了数组，所有请求
  -- 422，日志只见「缺少 answers」。
  if data.detail ~= nil then
    local d = data.detail
    if type(d) == "table" and d[1] and d[1].msg then
      local loc = d[1].loc and table.concat(d[1].loc, ".") or "?"
      return nil, string.format("请求被拒（422）：%s @ %s",
        tostring(d[1].msg), loc)
    end
    return nil, "接口错误：" .. tostring(d)
  end
  if type(data.answers) ~= "table" then return nil, "响应缺少 answers" end
  return data.answers
end

Jev.dumpState = dumpState
Jev.choiceKey = choiceKey
Jev.pickChoice = pickChoice
Jev.pickDiscard = pickDiscard
Jev.reconcileBeliefs = reconcileBeliefs

return Jev
