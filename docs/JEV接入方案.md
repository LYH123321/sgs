# JEV 决策模型接入方案

> 状态：**一至三期已实施**（基线 `9e238ef` 之上，2026-09-21）。四期为可选增强，未实施。
> 参考：TypeSafe AI 官方文档（docs.typesafe.ai，2026-09 发布的 System One / Jev）。

## 一、背景与结论

TypeSafe AI 的 **Jev** 是"System One"决策模型：输入程序状态 `state` 和一组类型化问题 `questions`，直接输出**结构化决策 + 校准概率**，不生成任何文本。这与普通对话 LLM（本项目现有 `SGS_AI_*` 链路）的使用方式根本不同：

| 维度 | 现有 LLM 路径（chat/responses） | Jev 路径 |
| --- | --- | --- |
| 输入 | system + user 两条消息（自由文本） | `state`（状态文本）+ `questions`（类型化问题表） |
| 输出 | 自由文本，需抠 JSON、防 markdown 污染 | 类型安全的结构化答案，**不可能格式错误** |
| 概率 | 无（或口头的、过度自信的） | 每个答案带 `confidence` + `probabilities` |
| 速度 | 1.5~12 秒（视思维链） | 官方标称 70~500ms |
| 计费 | 输入 + 输出都计费 | 仅输入 $0.042/MTok，输出免费 |
| 多问题 | 一次一条消息串行 | **一次调用并行回答所有问题**，互不串扰 |
| 文本推理 | 有（reasoning 字段，UI 展示） | **无**，推测面板需改为展示概率分布 |

**结论**：Jev 与本项目「AI 只在候选动作里挑编号」的设计（`src/core/ai/actions.lua`）高度契合——`choice` 原语就是为"从清单里选一个"而生。接入方式是**在 Agent 内新增一个决策引擎分支（brain）**，复用现有的动作枚举、观察层、记忆、线程传输和机械兜底，不推翻任何现有结构；对话 LLM 路径原样保留，用配置开关切换。

## 二、Jev API 速览（接入相关的部分）

```
POST https://api.typesafe.ai/v1/systemone
Authorization: Bearer <KEY>
Content-Type: application/json

{
  "state": "<程序状态文本>",
  "model": "jev-latest",
  "questions": {
    "<问题名>": { "type": "choice|score|noul", "instructions": "...", "criteria": ... }
  }
}
```

响应（所有问题并行求值）：

```json
{
  "answers": {
    "动作": { "type": "choice", "choice": "a7", "confidence": 0.78,
              "probabilities": { "a7": 0.85, "a3": 0.15 } },
    "保留价值3": { "type": "score", "score": 1.0, "confidence": 1.0,
                   "probabilities": { "0": 0.0, "1": 1.0, "2": 0.0 } },
    "是否明智": { "type": "noul", "noul": 0.9 }
  }
}
```

三种原语：

- **choice**：从 criteria（`key → 描述` 的表）里选一个，返回 `choice + confidence + probabilities`。**基数上限 255**。
- **score**：按 criteria（等级描述数组）给状态打分，返回 `score + probabilities`。
- **noul**：判断陈述真假，返回 0~1。

官方使用范式：**原子问题 + 代码组合**——每个问题只问一件具体的事，多因素拆成多个问题，加权与分支逻辑写在代码里。

## 三、总体架构

新增一条与 LLM 并列的决策引擎分支，分层复用现有模块：

```
                     ┌─────────────────────────────────────────┐
  Room 请求 ──► Agent│ Actions.enumerate   （完全复用，候选枚举） │
  (askFor*)         │ View.build          （完全复用，观察层）    │
                    │ Memory              （完全复用，记忆回放）  │
                    │        │                                │
                    │        ├── engine=llm ──► Prompt.build ──► chat/responses 传输 ──► Parse
                    │        │                                │
                    │        └── engine=jev ──► Jev.build     ──► systemone 传输 ──► Jev.map
                    │              (state+questions)              (answers→引擎响应)
                    │                                          │
                    │ 机械兜底 _mechanical（完全复用，规则 BOT 不参与）│
                    └─────────────────────────────────────────┘
```

新增文件：`src/core/ai/jev.lua`（state 组装、questions 构造、answers 映射、置信度门控）。修改点集中在：

| 文件 | 改动 |
| --- | --- |
| `src/core/ai/jev.lua`（新增） | 决策引擎核心：`build(req, room, actions, memory)` 与 `map(answers, actions, req)` |
| `src/core/ai/transport.lua` | `buildBody` 增加 `jev` 分支：POST systemone、Bearer 认证、无 temperature/thinking 等字段 |
| `src/core/ai/agent.lua` | `engine` 字段（llm/jev），`_start/_poll` 按引擎分流；stats 增加 `low_confidence` 计数 |
| `src/ui/ai_transport.lua` | `fromEnv` 识别 `SGS_AI_ENGINE=jev`，读 `SGS_JEV_*`；线程层零改动（仍是 POST + Bearer + JSON） |
| `src/net/server.lua` | 服务端 AI 座位同样按 engine 分流 |
| `ai.env.example` | 新增 Jev 配置段（见第五节） |
| `src/ui/scene_room.lua` / `scene_menu.lua` | AI 面板对 jev 模式展示概率分布（替代 reasoning 文本）；菜单按钮描述 |

## 四、请求类型 → 问题原语映射

设计原则：单选用 `choice`，多选拆成并行 `score` 再代码取 top-N，是非用 `noul`，高基数（>255）用官方推荐的"先打分再选择"两段式。

| 请求类型 | 问题构造 | 答案映射 |
| --- | --- | --- |
| `askForUseCard`（出牌） | 1 个 `choice`：criteria = `a<id> → 候选描述`（含"结束出牌"）。候选含转化技，全部合法 | `answers.动作.choice` 反查 id → Parse 现有的动作→响应映射逻辑 |
| `askForCard`（响应杀/闪/桃/无懈） | 同上单个 `choice` | 同上 |
| `askForSkillInvoke`（技能发动） | 单个 `noul`：「此刻发动【技能】对【武将】是否有利」，阈值默认 0.5 | `noul ≥ 0.5` → true |
| `askForChoice` | 单个 `choice` | 直接映射 value |
| `askForChooseCard` / `askForDiscardFrom` | 单个 `choice` | 映射 card |
| `askForDiscard`（多选弃 n 张） | **每张牌一个并行 `score`**：「牌 X 在当前局面的保留价值」，rubric = [优先弃置, 一般, 必须保留] | 代码按 `probabilities` 期望分升序取前 n 张弃掉；`any` 模式（制衡）期望分全部高于阈值则选"不弃" |
| `askForGuanxing`（观星） | 候选已收敛为代表性子集（≤9），单个 `choice` | 映射 up/down 方案 |
| 身份推测（可选并行问题） | 每个未亮身份玩家一个 `choice`：「座位 N 最可能的身份」，criteria = 四身份+未知 | 写回 Memory.beliefs + `on_beliefs` 回调（需一致性调和，见 6.3） |
| 复核确认（可选） | 高风险决策（救桃/决斗/(key 技能)）的第二阶段：单个 `noul`：「执行动作 X 是否明智」 | `noul < 0.5` → 拒绝该动作，取概率次高的候选 |

**高基数两段式**：出牌候选 = 手牌 × 目标座位，极端后期（约 20 手牌 × 8 目标 + 转化技）可能超过 255。枚举数 > 200 时切换两段式：第一阶段对每个「牌型」并行 `score` 打攻击收益，第二阶段对最高分的牌型目标做 `choice`。这同时压缩 state 体积。

## 五、配置开关设计

在 `ai.env` / 环境变量里新增独立段落，与现有 LLM 配置互不干扰；**`SGS_AI_ENGINE` 是总开关**：

```ini
# ── Jev 决策模型（System One，可选）────────────────────────
# SGS_AI_ENGINE=jev            # llm（默认，走上面的对话接口）| jev
# SGS_JEV_URL=https://api.typesafe.ai/v1/systemone
# SGS_JEV_MODEL=jev-latest
# SGS_JEV_KEY=ts-...           # console.typesafe.ai/keys 获取
# SGS_JEV_MIN_CONFIDENCE=0.35  # choice 置信度低于此值走降级链
# SGS_JEV_BELIEFS=1            # 0/1，是否附带身份推测问题（默认 1）
```

规则：

1. `SGS_AI_ENGINE` 未设置或为 `llm` 时，一切行为与现在完全一致（含报错文案），Jev 代码不参与。
2. `engine=jev` 时：`SGS_JEV_KEY` 必填；URL/模型有默认值；原有 `SGS_AI_URL/KEY/MODEL/REASONING/THINKING` 全部忽略（菜单「AI 思考」档位对 jev 隐藏或置灰）。
3. 已 export 的环境变量优先于 ai.env 文件，沿用现有约定。
4. 联机服务端 `SGS_NET_AI` 与单机托管共用这个开关；座位级覆盖（`SGS_NET_AI` 座位列表）逻辑不变。

## 六、关键设计细节

### 6.1 state 组装（Jev 无 system 消息）

`state` = 现有 `View.build` 的状态文本（战场局面）+ `Memory:render` 的决策史 + 一段精简规则前缀（现 `Prompt.SYSTEM` 的浓缩版，Jev 同样需要知道身份目标、距离、濒死等规则语义）。规则文本从 system 挪进 state 头部即可，内容基本复用。

### 6.2 置信度门控与降级链

```
choice.confidence ≥ MIN_CONFIDENCE ──► 执行
       │ 否
       ├─ 高风险动作？── 是 ──► 两段式复核（noul 确认一次）
       │                        ├─ 通过 ──► 执行
       │                        └─ 不通过 ─► 取次高概率候选（若其 confidence 达标）
       └─ 否 ──► 机械兜底 _mechanical（复用：被动放弃/不发动/机械弃牌）
```

Jev 无状态、无重试意义（重问同样的问题大概率同样答案），Agent 现有 `retries` 机制对 jev 引擎关闭，超时仍保留（默认可下调到 15 秒，官方标称 0.5 秒内返回）。

### 6.3 身份推测的一致性调和

Jev 每个问题独立求值，可能给出「座位 2 是主公、座位 3 也是主公」的矛盾组合。映射代码需调和：同身份多人时只保留概率最高者，其余按其概率次高的身份回落，再不行记「未知」。该规则同时是单测用例。

### 6.4 记忆与展示适配

- **记忆写入**：`describeChoice` 与 LLM 路径完全一致（决策是我们自己的动作，与模型无关）。
- **记忆读取**：Jev 无状态，每次决策把记忆全文编入 state（官方 input 极便宜，无成本压力）。
- **推测面板（AI 思考）**：LLM 模式展示 reasoning 文本；Jev 模式改为展示「动作概率分布 + 各座位身份概率」，数据结构从 `on_reasoning(text)` 扩展为 `on_probs(distribution)`。这是唯一需要改 UI 数据结构的点。

### 6.5 传输层

线程层（`src/ui/ai_transport.lua` 的 curl/socket 线程）与协议无关——POST + Bearer + JSON 返回，零改动。`core/ai/transport.lua` 的 `buildBody` 增加 jev 分支（body 就是 state/questions 表，响应解析在 `jev.lua` 的 `map` 里做）。代理模式（ai_proxy.py）目前只认识 chat/responses 路径，一期 jev 只支持直连（密钥进游戏进程，与现有直连模式同等风险）；代理透传列为四期可选项。

## 七、测试与验收

| 层 | 内容 |
| --- | --- |
| 单测（mock 传输） | state/questions 构造的黄金用例；choice→动作映射；弃牌 top-N；高基数两段式触发；置信度门控各分支；身份调和（含矛盾用例）；jev body 构造；answers JSON 解析；Agent 全流程 respond（thinking→ready）；engine=llm 时 jev 模块零参与 |
| 真接口自检 | 扩展 `tools/ai-check.lua`：`SGS_AI_ENGINE=jev` 时打真实 API 跑一次最小决策（联网、花钱，与 LLM 自检同等定位） |
| 联机 | server 座位 AI 用 jev 引擎的回归（mock 传输） |
| 压测 | mock 传输下 `run-soak.sh` 增加 jev 模式组，验证决策合法性与对局可完结性 |
| 对比基线（人工） | 同种子对局：Jev vs LLM vs BOT 的胜率/时长/成本抽样，验证「决策模型更快更稳」的预期是否成立 |

## 八、实施阶段

1. **一期（核心）✅**：`src/core/ai/jev.lua`（build/map/answersFrom/调和/门控）+ transport `jev` 协议分支 + Agent `engine` 分流 + `SGS_AI_ENGINE` 开关 + 43 项单测（AI 测试 154→197）。
2. **二期（接线）✅**：`scene_room`/`server` 按 `SGS_AI_ENGINE` 创建 jev Agent（超时 20s、置信度可配）；`tools/ai-check.lua` 支持 jev 自检；`ai.env.example` 增补 Jev 配置段。推测面板概率展示未做（见四期），当前 jev 模式的推测展示沿用 beliefs 时间线（`on_beliefs` 回调已透传）。
3. **三期（联机）✅**：`net/server.lua` 线程版走 `ui/ai_transport.fromEnv`（自动识别 jev）；无 love 兜底路径支持 `SGS_JEV_*` 直连。
4. **四期（可选，未实施）**：UI 概率分布展示（`on_probs`）、代理透传、混合模式（Jev 管高频响应 + LLM 管身份长推理）、两段式复核、压测对比报告。

## 九、风险与边界

- **早期访问**：API 处于 early access，限流/稳定性/字段变更风险高于成熟网关；URL/模型名全部可配置以对冲。
- **无文本输出**：思维链展示、reasoning 记忆、`note` 字段在 jev 模式下不存在；相关 UI 与记忆字段做条件降级，不伪造。
- **决策质量未知**：Jev 面向"几秒内可判断"的原子问题，身份局长线博弈是否够用需压测+人工对局验证；保留 `engine=llm` 随时可切回。
- **基数 255 / state 体积**：两段式与 state 截断（战况日志条数上限）必须有单测兜底。
- **成本模型**：输出免费、输入极廉，但 state（含记忆）每次决策全量重发；按官方定价即使 10 QPS 也仅约 $7/小时量级（官方 Doom 演示口径），单机对局远低于此。
