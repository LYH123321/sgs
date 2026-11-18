-- AI 性格（persona）：给 system 提示词追加一段「你是个什么样的玩家」
--
-- 为什么放在 system 而不是 user：
--   性格是**稳定的人设**，每轮都一样；放在 user 里会随上下文增长被稀释，
--   也浪费 token。system 每次请求都重发一份，人设最稳。
--
-- 设计原则：
--   1) 性格只改「风格」，不改「规则」——合法性由引擎保证，性格不能让它
--      违规出牌，也不能让它无视身份目标。
--   2) 默认 none = 完全不加，保证老行为与既有测试一字不差。
--   3) 每个性格都是一句话的行为指令，避免长段落让模型跑偏。
local Persona = {}

-- key -> {label, hint}
-- label 显示在菜单/设置页，hint 拼进 system prompt。
Persona.ALL = {
  { key = "none", label = "默认",
    hint = nil },

  { key = "cautious", label = "稳健",
    hint = "你打法稳健：优先保命与留牌，不轻易把唯一的【杀】或【闪】打光；"
      .. "身份不明时宁可观望，不做高风险投机。" },

  { key = "aggressive", label = "激进",
    hint = "你打法激进：倾向主动进攻、集火残血目标，愿意用牌换节奏；"
      .. "局势不明时也敢于先手压制你怀疑的敌人。" },

  { key = "scheming", label = "腹黑",
    hint = "你擅长算计：会故意示弱、诱导他人互斗，保存关键牌等待收割时机；"
      .. "在不暴露自身身份的前提下让别人替你先流血。" },

  { key = "loyal", label = "忠厚",
    hint = "你重信守义：一旦认定盟友就全力相助，愿意为队友挡刀、出【桃】救援；"
      .. "不搞背叛与背刺，宁可自己吃亏。" },

  { key = "chaotic", label = "搅局",
    hint = "你喜欢搅局：优先制造混乱、打断他人节奏，哪怕对自己短期不利；"
      .. "享受让局势失控的乐趣，但不做明显自毁的操作。" },

  { key = "mengde", label = "孟德之姿",
    hint = "你以曹操自居：宁教我负天下人，休教天下人负我。极度多疑，"
      .. "对任何人都不给第二次机会；该背刺时毫不犹豫，且善于把背刺包装成善意。" },
}

local byKey = {}
for _, p in ipairs(Persona.ALL) do byKey[p.key] = p end

-- 合法 key 列表（测试与设置页校验用）
function Persona.keys()
  local out = {}
  for _, p in ipairs(Persona.ALL) do out[#out + 1] = p.key end
  return out
end

-- key -> 显示名；未知 key 原样返回，便于排错
function Persona.label(key)
  local p = byKey[key]
  return p and p.label or tostring(key)
end

-- key -> 拼进 system 的片段；none / 未知 / nil 返回 nil
function Persona.hint(key)
  local p = byKey[key]
  if not p then return nil end
  return p.hint
end

-- 把一个 base system prompt 与性格合成
-- 返回 base 原样（none）或 "base\n\n【你的性格】\nhint"
function Persona.apply(base, key)
  local hint = Persona.hint(key)
  if not hint then return base end
  return base .. "\n\n【你的性格】\n" .. hint
end

return Persona
