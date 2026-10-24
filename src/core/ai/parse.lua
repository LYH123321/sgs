-- AI 响应解析与校验：把 LLM 的输出翻译成引擎能吃的响应
--
-- 这里的态度是「默认 LLM 会犯错」：
--   - 它可能裹 markdown 代码块、前后加废话、给字符串编号、越界、给错数量；
--   - 它给的动作在解析时也可能已经失效（理论上协程停在 yield 不会变，
--     但 view_as 生成的虚拟牌、转化技的可用性都有边界情况）。
-- 因此每一步都返回 (响应, 错误原因)，任何一个环节不对就交给上层回落 BOT。
-- 宁可让 AI 这一手打得平庸，也不能让它把游戏卡死或搞出非法状态。
local Json = require "src.core.json"

local Parse = {}

-- 从 LLM 的原始输出里抠出第一个 JSON 对象。
-- 实测最常见的三种污染：```json 代码块、前后寒暄、JSON 后面跟解释。
local function extractJson(raw)
  if type(raw) ~= "string" then return nil end
  local s = raw:gsub("```%w*", "")
  local i = s:find("{", 1, true)
  if not i then return nil end
  local depth, j, in_str, esc = 0, i, false, false
  while j <= #s do
    local c = s:sub(j, j)
    if in_str then
      if esc then esc = false
      elseif c == "\\" then esc = true
      elseif c == '"' then in_str = false end
    elseif c == '"' then in_str = true
    elseif c == "{" then depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then break end
    end
    j = j + 1
  end
  if depth ~= 0 then return nil end
  return Json.decode(s:sub(i, j))
end
Parse.extractJson = extractJson

-- 从右往左找**最后一个**平衡的 JSON 对象。推理模型（glm-5 等走 chat
-- 协议）的推理文本里常出现中间草稿 JSON，最终答案在末尾——
-- extractJson 取第一个会拿错，这里从最后一个 } 往前反向配平尝试。
local function extractLastJson(raw)
  if type(raw) ~= "string" then return nil end
  local s = raw:gsub("```%w*", "")
  -- 收集全部 "}" 的位置，从最右边的开始反向配平
  local closes = {}
  local k = 1
  while true do
    local f = s:find("}", k, true)
    if not f then break end
    closes[#closes + 1] = f
    k = f + 1
  end
  for ci = #closes, 1, -1 do
    local endp = closes[ci]
    local depth, i = 1, endp - 1
    local in_str, esc = false, false
    while i >= 1 do
      local c = s:sub(i, i)
      if in_str then
        if esc then esc = false
        elseif c == "\\" then esc = true
        elseif c == '"' then in_str = false end
      elseif c == '"' then in_str = true
      elseif c == "}" then depth = depth + 1
      elseif c == "{" then
        depth = depth - 1
        if depth == 0 then break end
      end
      i = i - 1
    end
    if i >= 1 and depth == 0 then
      local obj = Json.decode(s:sub(i, endp))
      if type(obj) == "table" then return obj end
    end
  end
  return nil
end
Parse.extractLastJson = extractLastJson

-- 自动修复模型的高频笔误：字符串少写闭合引号（实测 glm-5-turbo：
-- "reason": "拆自己…保留无懈可击} ——引号丢了，平衡扫描永远失败）。
-- 思路：取首 { 到末 } 的片段，统计未转义引号数；奇数说明有字符串
-- 没闭合，在末位 } 前补一个引号再解码。修不好就返回 nil 走重试。
local function repairJson(raw)
  if type(raw) ~= "string" then return nil end
  local s = raw:gsub("```%w*", "")
  local i = s:find("{", 1, true)
  local j = s:match(".*()}") -- 最后一个 }
  if not i or not j or j <= i then return nil end
  local frag = s:sub(i, j)
  local quotes = 0
  local k = 1
  while k <= #frag do
    local c = frag:sub(k, k)
    if c == "\\" then k = k + 2 -- 跳过转义对
    elseif c == '"' then quotes = quotes + 1 k = k + 1
    else k = k + 1 end
  end
  if quotes % 2 == 1 then
    frag = frag:sub(1, #frag - 1) .. '"' .. "}"
  end
  local obj = Json.decode(frag)
  if type(obj) == "table" then return obj end
  return nil
end
Parse.repairJson = repairJson

local function playerBySeat(room, seat)
  if not seat then return nil end
  for _, p in ipairs(room.players) do
    if p.seat == seat then return p end
  end
  return nil
end

-- 归一化成编号数组：支持 {"action":3} 与 {"actions":[1,2]} 两种写法，
-- 编号是字符串（"3"）也要认——LLM 偶尔会加引号。
local function normalizeIds(data)
  local raw = data.actions
  if raw == nil and data.action ~= nil then raw = { data.action } end
  if type(raw) ~= "table" then
    if type(raw) == "number" or type(raw) == "string" then raw = { raw } else return nil end
  end
  if #raw == 0 then return nil end
  local out = {}
  for _, v in ipairs(raw) do
    local n = tonumber(v)
    if not n then return nil end
    out[#out + 1] = n
  end
  return out
end

-- ===== 文本动作的模糊匹配 =====
-- 弱模型（实测 hy-mt2-lite）常无视「只回编号」的格式要求，把候选标签
-- 抄进 action 字段：{"action": "出C2-杀"}。标签里的 C2-杀 正是候选列表
-- 的 cardLabel（花色字母+点数+牌名），因此可以按「牌面身份」可靠地对回
-- 候选：完整标签 > 花色+点数 > 点数+牌名，目标名与「结束/不打出」这类
-- 关键词辅助消歧。分数不够或并列时宁可拒绝走兜底——错误地打出一手
-- 比保守跳过更伤对局。

-- 归一化文本：去掉空白与装饰符（【】·、——- 等），只留字母数字和 CJK
local function normText(s)
  local t = {}
  for ch in s:gmatch("[%w\128-\255]") do t[#t + 1] = ch end
  return table.concat(t)
end

local PASS_HINTS = {
  { keys = { "结束出牌", "结束", "pass", "end" }, hits = { "结束出牌" } },
  { keys = { "不打出", "不出", "放弃" }, hits = { "不打出" } },
  { keys = { "不弃", "不选", "都不弃" }, hits = { "不弃" } },
  { keys = { "不发动", "不使用", "跳过" }, hits = { "不发动" } },
}

-- 给一个候选按文本打分；返回分数（0 = 无证据）
local function scoreAction(text, a, room)
  local n = normText(text)
  if n == "" then return 0 end
  local descN = normText(a.desc or (a.short or ""))
  if descN ~= "" and descN == n then return 200 end

  local score = 0
  if a.card then
    local label = normText(string.format("%s%d%s",
      a.card:suitString(), a.card.number, a.card:zhName()))
    local suitNum = normText(a.card:suitString() .. a.card.number)
    local numName = normText(a.card.number .. a.card:zhName())
    if n:find(label, 1, true) then score = score + 100 -- 完整标签 C2杀
    elseif n:find(suitNum, 1, true) and n:find(normText(a.card:zhName()), 1, true) then
      score = score + 80                                   -- C2 + 杀 分开出现
    elseif n:find(suitNum, 1, true) then
      score = score + 70                                   -- 只认 C2（花色+点数仍唯一）
    elseif n:find(numName, 1, true) then
      score = score + 60                                   -- 2杀
    elseif n:find(normText(a.card:zhName()), 1, true) then
      score = score + 10                                   -- 只有牌名，同名牌多时不可靠
    end
  end
  -- 目标名：同一张牌能打多个目标时靠它消歧
  if a.target_seat and room then
    for _, p in ipairs(room.players) do
      if p.seat == a.target_seat and n:find(normText(p.name), 1, true) then
        score = score + 30
        break
      end
    end
  end
  -- 结束/放弃类关键词（pass 候选的 desc 是固定短语）
  for _, ph in ipairs(PASS_HINTS) do
    for _, h in ipairs(ph.hits) do
      if descN:find(normText(h), 1, true) then
        for _, k in ipairs(ph.keys) do
          if n:find(normText(k), 1, true) then score = score + 80 break end
        end
        break
      end
    end
  end
  -- 主动技：发动【X】
  if a.kind == "invoke" and a.value == true then
    if n:find("发动", 1, true) then score = score + 60 end
  end
  -- 纯选项（askForChoice 的 value 本身就是文案）
  if a.kind == "choice" and descN ~= "" and n:find(descN, 1, true) then
    score = score + 100
  end
  return score
end

-- 模型把编号和解释塞进同一个字符串的变体（hy-mt2-lite 实测）：
--   "1, 保留闪应对双刃拼点"（编号+逗号+注释）、"1, 3"（编号列表）、"第2个"。
-- 从头解析数字链：数字之间必须是分隔符（逗号/顿号/空白），数字后面
-- 允许单个量词（号/个/项/位）；一旦数字后直接跟内容（如 "2杀" 是牌面，
-- 不是编号），整体不按编号解释——宁可走文本匹配，不能把牌点当编号。
local function extractNumberList(s)
  if type(s) ~= "string" then return nil end
  local t = s:gsub("^%s*[第选项编号]+", "")
  local ids, pos = {}, 1
  while true do
    local s0, e0 = t:find("^(%d+)", pos)
    if not s0 then break end
    pos = e0 + 1
    local q = t:match("^[号个项位]", pos)
    if q then pos = pos + 1 end
    local sep = t:match("^[%s,，、;；/]+", pos)
    if sep then
      pos = pos + #sep
      ids[#ids + 1] = tonumber(t:sub(s0, e0))
    elseif pos > #t then
      ids[#ids + 1] = tonumber(t:sub(s0, e0))
      break
    else
      return nil
    end
  end
  if #ids == 0 then return nil end
  return ids
end

-- 泛指动词（"出牌"、"使用"）：模型想出牌但没说哪张。候选里**恰好只有
-- 一个**非放弃动作时可采纳；多个时无法定夺，仍走拒绝。
local GENERIC_PLAY = { ["出牌"] = true, ["出一张"] = true, ["打牌"] = true,
  ["使用"] = true, ["出一张牌"] = true }

-- 把一个文本动作解析成候选编号；无法唯一确定返回 nil
local function resolveTextAction(text, actions, room)
  local n = normText(text)
  local best, best_score = nil, 0
  local tied = {}
  for _, a in ipairs(actions) do
    local s = scoreAction(text, a, room)
    if s > best_score then
      best, best_score, tied = a, s, { a }
    elseif s == best_score and s > 0 then
      tied[#tied + 1] = a
    end
  end
  -- 门槛：至少要有牌面/关键词级别的证据（≥60），只有牌名（10）不算
  if best and best_score >= 60 then
    if #tied == 1 then return best.id end
    -- 并列且都是**同一张牌的不同目标**（模型说了出这张牌但没说打谁）：
    -- 选 desc 里距离最近的，仍然并列取靠前的——与机械兜底的结果相当，
    -- 但保留了 reason / beliefs 等元信息
    local same_card = true
    for _, a in ipairs(tied) do
      if a.card ~= tied[1].card then same_card = false break end
    end
    if same_card then
      local pick, pick_d = tied[1], math.huge
      for _, a in ipairs(tied) do
        local d = tonumber(a.desc and a.desc:match("距离 (%d+)")) or math.huge
        if d < pick_d then pick, pick_d = a, d end
      end
      return pick.id
    end
    return nil
  end
  -- 泛指动词：只在唯一非放弃候选时采纳
  if GENERIC_PLAY[normText(text)] then
    local only, count = nil, 0
    for _, a in ipairs(actions) do
      if a.kind ~= "pass" then only, count = a, count + 1 end
    end
    if count == 1 and only then return only.id end
  end
  -- 唯一牌名：模型只写「出【乐不思蜀】」没写花色点数（hy-mt2-lite 实测）。
  -- 候选里**只有一张**这个牌名的牌时，牌名足以唯一确定；同一张牌的
  -- 多个目标取距离最近。多张同名（两张杀）仍然拒绝。
  if best_score < 60 then
    local byname = {}
    for _, a in ipairs(actions) do
      if a.card and n:find(normText(a.card:zhName()), 1, true) then
        byname[#byname + 1] = a
      end
    end
    if #byname > 0 then
      local same = true
      for _, a in ipairs(byname) do
        if a.card ~= byname[1].card then same = false break end
      end
      if same then
        local pick, pick_d = byname[1], math.huge
        for _, a in ipairs(byname) do
          local d = tonumber(a.desc and a.desc:match("距离 (%d+)")) or math.huge
          if d < pick_d then pick, pick_d = a, d end
        end
        return pick.id
      end
    end
  end
  return nil
end

-- data.action/actions 是非编号文本时逐个模糊匹配；任何一个匹配失败
-- 整体作废（半猜半编比保守兜底更危险）。返回编号数组或 nil。
local function resolveTextIds(data, actions, room)
  local raw = data.actions
  if raw == nil and data.action ~= nil then raw = { data.action } end
  if type(raw) ~= "table" then
    if type(raw) == "string" then raw = { raw } else return nil end
  end
  if #raw == 0 then return nil end
  local out = {}
  for _, v in ipairs(raw) do
    if type(v) == "number" then
      out[#out + 1] = v
    elseif type(v) == "string" and tonumber(v) then
      out[#out + 1] = tonumber(v)
    elseif type(v) == "string" then
      -- "1, 保留闪…" / "1, 3" / "第2个"：编号混着解释，先按编号链提取
      local nums = extractNumberList(v)
      if nums then
        for _, n in ipairs(nums) do out[#out + 1] = n end
      else
        local id = resolveTextAction(v, actions, room)
        if not id then return nil end
        out[#out + 1] = id
      end
    else
      return nil
    end
  end
  return out
end

-- 每个请求类型期望选几个动作
local EXPECTED_COUNT = {
  askForUseCard = 1, askForCard = 1, askForChooseCard = 1,
  askForDiscardFrom = 1, askForSkillInvoke = 1, askForChoice = 1,
  askForGuanxing = 1,
}

-- 主入口：raw 是 LLM 原始字符串，actions 是 Actions.enumerate 的结果
-- 返回 (响应, nil) 或 (nil, 错误原因)
function Parse.response(raw, req, room, actions)
  -- curl 子进程失败时，stderr 会以 "curl: (28) ..." 的形式混进原始输出。
  -- 报成「不是合法 JSON」会误导排查方向（那是网络，不是模型）。
  if type(raw) == "string" and raw:find("^curl: ", 1) then
    return nil, "接口调用失败（网络）：" .. (raw:match("^[^\n]+") or raw)
  end
  local me = req.player
  local data = extractJson(raw)
  local ids = data and normalizeIds(data)
  -- 首个 JSON 不可用（整个没有 JSON，或里面没有 action 字段）时，
  -- 从最后一个 JSON 对象再试一次——推理模型的中间草稿 JSON 会把
  -- extractJson 带偏，最终答案往往在文本末尾
  if not ids then
    local last = extractLastJson(raw)
    if last and last ~= data then
      data = last
      ids = normalizeIds(data)
    end
  end
  -- 提取都失败或仍缺 action：试一次自动修复（少闭合引号一类的高频笔误）
  if not ids then
    local fixed = repairJson(raw)
    if fixed then
      data = fixed
      ids = normalizeIds(data)
    end
  end
  -- 编号不可用但 action 字段在：按候选标签做文本模糊匹配
  -- （弱模型会把 "出C2-杀" 这类标签抄进 action；C2-杀 本就是候选的牌面）
  if not ids and type(data) == "table" and (data.action ~= nil or data.actions ~= nil) then
    ids = resolveTextIds(data, actions, room)
    if not ids then
      local t = type(data.action) == "string" and data.action or tostring(data.action or "")
      return nil, string.format("动作文本无法对应合法动作：%s（请回候选编号）", t)
    end
  end
  if not ids then
    if type(data) ~= "table" then return nil, "输出不是合法 JSON" end
    return nil, "缺少 action/actions 字段"
  end

  local picked = {}
  for _, id in ipairs(ids) do
    local a = type(id) == "number" and actions[id] or nil
    if not a then return nil, string.format("动作编号越界: %s", tostring(id)) end
    picked[#picked + 1] = a
  end

  -- 数量校验：弃牌要正好 n 张（any 模式如【制衡】允许 0..n 张），
  -- 其余请求只能选一个
  if req.type == "askForDiscard" then
    local want_n = req.n or 0
    if req.any then
      if #picked > want_n then
        return nil, string.format("弃牌数量超限：至多 %d 张，给了 %d 个", want_n, #picked)
      end
    elseif #picked ~= want_n then
      return nil, string.format("弃牌数量不符：需要 %d 张，给了 %d 个", want_n, #picked)
    end
  else
    local want = EXPECTED_COUNT[req.type] or 1
    if #picked ~= want then
      return nil, string.format("动作数量不符：需要 %d 个，给了 %d 个", want, #picked)
    end
  end

  -- 混合类型一律拒绝：说明 LLM 没看懂，交给 BOT 更稳
  local kind = picked[1].kind
  for _, a in ipairs(picked) do
    if a.kind ~= kind then return nil, "一次选了不同类型的动作" end
  end

  -- 模型可选回传的「元信息」：身份判断与长期观察。
  -- 它们不影响这一步的合法性，解析失败也不该让整步作废，所以不做校验，
  -- 原样交给 Agent 去过滤（见 memory.lua 的 updateBeliefs）。
  local extra = {
    beliefs = type(data.beliefs) == "table" and data.beliefs or nil,
    note = type(data.note) == "string" and data.note or nil,
    reason = type(data.reason) == "string" and data.reason or nil,
  }

  if kind == "pass" then return nil, nil, extra end

  if kind == "use" then
    local a = picked[1]
    if not a.card then return nil, "动作缺少卡牌" end
    local target = playerBySeat(room, a.target_seat)
    if not target then return nil, "目标座位不存在" end
    if target ~= me then
      local ok, why = room:canUseCardOn(me, a.card, target)
      if not ok then return nil, "目标不合法：" .. tostring(why) end
    end
    extra.target_name = target.name
    return { card = a.card, target = target }, nil, extra
  end

  if kind == "card" then
    local a = picked[1]
    if not a.card then return nil, "动作缺少卡牌" end
    return a.card, nil, extra
  end

  if kind == "discard" then
    local out = {}
    for _, a in ipairs(picked) do
      if not a.card then return nil, "动作缺少卡牌" end
      -- 重复选同一张：弃牌数会对不上，直接拒绝
      for _, c in ipairs(out) do
        if c == a.card then return nil, "重复选择了同一张牌" end
      end
      out[#out + 1] = a.card
    end
    return out, nil, extra
  end

  if kind == "choose" then
    return picked[1].card, nil, extra
  end

  if kind == "invoke" or kind == "choice" then
    return picked[1].value, nil, extra
  end

  -- 观星：直接把候选里预构造的 up/down 顺序交给引擎
  -- （room.lua 对非表响应的约定是保持原序，这里的表一定合法：
  -- 元素就是刚从牌堆顶取出的那几张牌，只是顺序与顶底分配不同）
  if kind == "guanxing" then
    local a = picked[1]
    return { up = a.up, down = a.down }, nil, extra
  end

  return nil, "未知动作类型：" .. tostring(kind)
end

return Parse
