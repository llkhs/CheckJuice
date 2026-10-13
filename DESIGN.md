# CheckJuice — 设计文档 v0.1

> 用「电池更换事件」驱动预测的设备续航管理器。主 App 记账 + iOS 17 桌面小组件倒计时。

## 1. 产品范围

**做什么**：管理一批「靠电池固定运行」的设备（传感器、门锁、遥控器、温湿度计…），
记录每次换电池的时间点，据此预测**下一次没电的日期**，并在桌面小组件上显示倒计时，
在进入风险窗口前推送提醒，让你来得及买/换电池。

**不做什么**：
- ❌ 不读第三方设备的实时电量（iPhone 没有这个接口，除非 BLE/HomeKit，见 §7）
- ❌ 不做云端同步（v1 纯本地；留 iCloud 扩展位不给钱）

**成功标准**：装到手机上，添加 3 个设备，换过一次电池后，小组件显示的预测日期误差 < 15%。

---

## 2. 数据模型

### 2.1 电池种类 `BatteryKind`
枚举 + 可扩展：`cr2032 / cr2450 / cr123a / aa_alkaline / aa_lithium / aaa_alkaline / 9v / coin_lr44 / builtin_li / other`

每种带一个**弱先验** `nominalLifeDays`（仅冷启动用，用户可覆盖）。
⚠️ 电池类型只决定「典型值」，真正寿命取决于**设备功耗**，所以先验置信度故意给得很低。

### 2.2 设备 `Device`
| 字段 | 说明 |
|---|---|
| `id` | UUID |
| `name` | "大门指纹锁" |
| `kind` | 电池种类 |
| `installedAt` | **本次电池的起算时间**（首次 = 添加时间） |
| `nominalLifeDays` | 冷启动先验（天），可空 |
| `notifyLeadDays` | 提前多少天提醒，默认 14 |
| `refDeviceId` | 可选：借用同型号设备的历史当先验 ⭐ |
| `events` | 更换事件序列 |

### 2.3 更换事件 `ReplacementEvent`
| 字段 | 说明 |
|---|---|
| `at` | 发生时间（上一次起算点 → 这一时刻的间隔就是本次观测） |
| `type` | `exhausted` 正常耗尽 / `preventive` 提前预防 / `faulty` 电池质量问题 / `initial` 首次安装 |
| `note` | 备注（可选） |

**关键规则**：`type` 决定这条数据是否进入寿命统计。
- `exhausted` → **有效样本**，间隔计入寿命估计
- `preventive` / `faulty` → **截尾观测（censored）**，间隔**不计入**寿命统计，
  但**仍然重置起算点**（因为装了新电池）。
- 这是生存分析的基本纪律：把"提前换掉的好电池"当成"寿命只有这么长"，会把模型带偏。

---

## 3. 预测模型 `LifetimeModel`（核心）

### 3.1 建模选择：对数正态 + 正态共轭

电池寿命**非负**、**右偏**（偶尔一个电池特别差，但不会有负数），所以不当成正态分布，
而是建模 `log(寿命) ~ Normal(m, σ²)`。好处：
1. 天然非负，不会预测出负天数
2. 正态-正态共轭有闭式解，**十几行代码**，不需要采样/数值优化
3. 参数 `σ` 直接可解释为"相对不确定度"（σ=0.3 ≈ ±35%）

### 3.2 先验

`log(寿命) ~ Normal(m₀, τ²)`
- `m₀ = log(nominalLifeDays)`，`τ = 0.5`（相对不确定度 ±50%）
- 若设备引用了 `refDeviceId` → 用参照设备的历史后验当先验，`τ` 收紧到 0.25 ⭐
- 若用户填了自定义寿命 → `τ = 0.35`

### 3.3 观测与加权

有效观测 `xᵢ = log(Δᵢ)`，`Δᵢ` = 第 i 次更换距上一次的间隔天数，仅取 `exhausted`。

**近期权重更高**（设备老化、环境季节变化是渐进的）：
```
wᵢ = λ^(n-i)          λ = 0.7  → 半衰期约 2 次更换
Kish 有效样本量:  n_eff = (Σwᵢ)² / Σwᵢ²
加权均值:         x̄ = Σwᵢxᵢ / Σwᵢ
加权方差:         s² = Σwᵢ(xᵢ-x̄)² / (Σwᵢ - Σwᵢ²/Σwᵢ)
```

### 3.4 后验

```
观测方差  σ² = max(s², σ_min²)，  σ_min = 0.15   ← 方差下限，防止假精确
后验精度  P  = 1/τ² + n_eff / σ²
后验均值  m  = (m₀/τ² + n_eff·x̄/σ²) / P
后验标准差 σ_post = 1/√P   （再做一次下限约束）
```

`σ_min = 0.15` 的物理依据：同一台设备连换两次同型号电池，寿命差异天然有 15%~20%。
样本再少也不能给出"±3 天"这种骗人的精度。**样本量决定的是「区间宽度」，不是「假装确定」。**

### 3.5 输出

```
预测中位寿命  = exp(m)                        （对数正态中位数，比均值稳健）
预计耗尽日    = installedAt + 预测中位寿命

预测分布宽度  σ_pred = min( sqrt(σ_post² + σ_within²), 0.70 )     ← 见下方修订说明
风险窗口起点  = installedAt + exp(m - 1.2816·σ_pred)             （P10）

剩余天数      = 预计耗尽日 - today
剩余比例      = 已用天数 / 预测中位寿命
```

> **★ 修订 v0.2（原稿用 σ_post，已推翻）**
>
> 原稿的风险窗口用 `σ_post`（对**期望寿命**的不确定度）。这是**错的**，
> 会系统性把窗口开晚。理由：要预测的是「**当前这一颗**电池什么时候死」，
> 而单颗电池的寿命本身就有 `σ_within` 的固有波动（设备功耗波动 + 电池个体差异），
> 不能只算对均值的认知不确定度。正确做法是把两者合成：
> `σ_pred² = σ_post² + σ_within²`。
>
> 蒙特卡洛实测：用 σ_post 时漏报率偏高；改用 σ_pred 后漏报率降到 7~10%（见 §3.9）。
> 本 App 的失败代价正是"没电了才发现"，所以宁可窗口开早，不可开晚。

**紧急度分级**：

### 3.6 紧急度分级

判据**全部基于「距风险窗口还剩几天」**，而非「距中位日还剩几天」。

| 状态 | 条件 | 小组件显示 |
|---|---|---|
| 🔴 已逾期 | `剩余天数 < 0`（已过 P50） | `逾期 N 天` |
| 🟠 风险窗口 | `距风险窗口 ≤ 0`（已过 P10） | `≤ N 天` |
| 🟡 需备货 | `距风险窗口 ≤ notifyLeadDays` | `N 天` |
| 🟢 正常 | 其他 | `N 天` |

> **★ 修订 v0.3（原稿判据反了，已推翻）**
>
> 原稿写「需备货 = 距**中位日**不足 lead 天」。这是**错的**，会导致 🟡 永不触发：
> 风险窗口（P10）通常远早于中位日，实测某设备 P10=189 天 / P50=299 天，
> 距中位日 14 天时年龄已 285 天 —— **早已进入🟠风险窗口 3 个多月**，
> 优先级更高的 🟠 永远先命中，🟡 成了死代码。
>
> 改为「距**风险窗口开启**不足 lead 天」后语义才正确：
> 「你还有 14 天进入危险区，现在去买电池」。同时删掉了原稿里
> `已用比例 ≥ 0.80` 这条拍脑袋的魔数判据。

### 3.6 冷启动退化（样本量处理）

| 有效样本 n | 行为 |
|---|---|
| 0（刚添加） | 纯先验，`σ` 强制 0.5，UI 显示"样本不足，估计粗糙，误差可能 ±50%" |
| 1 | 先验 + 单观测加权，`σ` 强制 ≥ 0.3 |
| 2~3 | 正常共轭更新，但仍显示"置信度：中" |
| ≥4 | 显示"置信度：高" |

**置信度必须显式展示**，不能把 1 个样本的预测和 10 个样本的预测画等号。这是这个 App 的诚信底线。

### 3.7 逾期不自动修正 ⭐

预测日过了、用户还没换 → **不更新预测**，状态标记为「逾期 N 天」。
因为逾期本身就是信息（说明比模型预期耐用），只有用户点了"已更换"，这次间隔才闭环成一条观测。
绝不偷偷把预测往后推——那是自欺。

### 3.8 漂移检测（v2，v1 不做）

若最近 3 个间隔单调递减且累计降幅 > 30% → 提示"该设备耗电在加快（可能设备老化/漏电）"。
用 log 尺度上的线性回归，斜率显著为负才报。**v1 不实现**，避免过度工程。

---

### 3.9 实测验证（已完成，M1 部分达成）✅

本机无 Swift 工具链，故先用 Python 落地同一套数学并实测，验证通过后再逐行移植。
代码：[reference/lifetime_model.py](minis://mounts/Minis-Home/CheckJuice/reference/lifetime_model.py) ·
[reference/validate_model.py](minis://mounts/Minis-Home/CheckJuice/reference/validate_model.py)

**A. 场景演示**（8 个构造场景，含坏电池、预防性更换、逾期）

关键正确性已验证：
- 坏电池场景 `[300,290,310,60,295,285]` → 60 天那条**被正确剔除**，`n_eff=4.04`
- 预防性更换场景 `[300,120,290,310]` → 120 天那条**被正确剔除**，但**起算点照样重置** ✅
- 逾期场景 → 正确标 🔴 已逾期（剩余 −26 天），**预测没有被偷偷往后推** ✅

**B. 蒙特卡洛校准**（真值 中位 300 天 / σ_within=0.2；先验刻意给偏成 365 天）
4000 次试验：

| n 有效样本 | 中位预测 | 偏差 | 漏报率 | 窗口宽度 | σ_within 估计 |
|---|---|---|---|---|---|
| 1 | 317.9 | +6.0% | 3.2% | 39.7% | 0.300（兜底） |
| 2 | 311.0 | +3.7% | 3.3% | 36.9% | 0.300（兜底） |
| 3 | 305.0 | +1.7% | 9.7% | 27.6% | 0.200 |
| 5 | 303.6 | +1.2% | 7.5% | 27.6% | 0.202 |
| 8 | 302.9 | +1.0% | 7.3% | 27.5% | 0.200 |
| 15 | 302.3 | +0.8% | 7.6% | 27.4% | 0.199 |

结论：
1. **偏差随样本收敛** 6.0% → 0.8%，证明**先验给偏了也能被数据纠正**（不硬编码电池标签）
2. **σ_within 被准确还原**（0.199~0.202 vs 真值 0.2），证明方差估计没写错
3. **漏报率 7~10%**（<20% 阈值）——"抽一颗新电池，它比风险窗口还早死"的概率
4. **窗口宽度收敛到 27.5% 就不再收窄** —— 这是 σ_min / σ_within 在起作用，**是故意的**
   同一设备换同型号电池，寿命天然有 15~20% 差异，样本再多也不能假装精确

**这些数值将直接作为 Swift 单元测试的黄金期望值（golden values）。**

---

## 4. 架构

```
CheckJuice/
├── project.yml                        # XcodeGen：工程由配置生成，不手写 pbxproj
├── CheckJuiceCore/                  # SPM 包 · 纯 Foundation，无 UI/无 SwiftData
│   ├── Sources/CheckJuiceCore/
│   │   ├── Models.swift               # Device / BatteryKind / ReplacementEvent（值类型）
│   │   ├── LifetimeModel.swift        # §3 全部数学
│   │   ├── Prediction.swift           # 输出结构 + 紧急度分级
│   │   └── WidgetSnapshot.swift       # 小组件读的 Codable 快照
│   └── Tests/CheckJuiceCoreTests/   # 纯函数，好测；模型是这里的主要测试对象
├── CheckJuice/                      # 主 App
│   ├── CheckJuiceApp.swift
│   ├── Persistence/                   # SwiftData @Model + Store（App Group 容器）
│   ├── Views/                         # 列表 / 详情 / 添加 / 记一次更换
│   ├── Intents/                       # LogReplacementIntent / SelectDeviceIntent
│   └── CheckJuice.entitlements      # App Group
├── CheckJuiceWidget/                # 小组件扩展
│   ├── BatteryWidget.swift            # 只读快照 JSON 渲染，不跑模型
│   └── CheckJuiceWidget.entitlements
└── .github/workflows/build.yml
```

### 4.1 数据流（关键设计）

```
用户点「已更换」
   → AppIntent 唤醒主 App 进程
   → SwiftData 追加事件
   → LifetimeModel 重算所有设备
   → 写出 WidgetSnapshot.json 到 App Group 目录
   → WidgetCenter.reloadAllTimelines()
   → 小组件进程只读 JSON 渲染（不碰数据库、不跑数学）
```

**为什么小组件只读快照**：widget 有内存和 CPU 预算，SwiftData 在扩展进程里建容器又慢又容易出事。
主 App 算好一个几十字节的 JSON，widget 拿来就画——这是 WidgetKit 的标准姿势。

### 4.2 小组件

- 配置用 `AppIntentConfiguration` + `SelectDeviceIntent`（iOS 17 特性），
  每个小组件实例选一台设备。
- 三种模式：指定设备 / **最紧急 N 台** / 全部列表
- 尺寸：小=1 台，中=2~3 台，大=全部
- 交互：小/中/大都可以放一个 `Button(intent: LogReplacementIntent)` → 桌面直接点"已换电池"

### 4.3 时间线刷新策略

- 基准：每天 1 次（按天粒度够用，省预算）
- 若某设备处于风险窗口（≤ P10）→ 缩短到每 6 小时
- 预测耗尽日当期加一次刷新
- 数据变化 → 立即 `reloadTimelines`

### 4.4 通知

用 `UNUserNotificationCenter` 本地通知，在 `预计耗尽日 - notifyLeadDays` 当天 09:00 提醒。
**不申请后台权限、不轮询**——一切都由本地通知调度，省电且无服务端。

---

## 5. 工具链与版本

| 项 | 选择 | 理由 |
|---|---|---|
| 最低版本 | **iOS 17.0** | 交互式小组件（`Button(intent:)`）刚需；AppIntent 配置小组件；SwiftData；2026 年覆盖率足够 |
| 构建 SDK | **Xcode 26 / iOS 26 SDK** | 用新 SDK 构建，老系统上自动降级外观；新 SDK 才有 Liquid Glass 适配 |
| CI runner | `macos-15` 或更新 | ⚠️ 旧的 `macos-14` 只有 Xcode 15，构建不了 |
| 工程文件 | **XcodeGen**（`project.yml`） | 三 target + 依赖关系，手写 pbxproj 必炸 |
| 核心逻辑 | **SPM 本地包** | 纯 Swift 无 UI 依赖 → 以后上 watchOS/macOS/快捷指令直接复用 |
| 多系统适配 | `#available` 能力降级 | **不靠拉低 deployment target 来兼容** |
| 测试 | Swift Testing (Xcode 16+) | 模型算法必须有测试，这是唯一容易算错的地方 |

---

## 6. 构建与分发（无 Mac 路线）

### 6.1 硬约束

⚠️ **小组件与主 App 共享数据必须用 App Group**，而 **App Groups capability 只有付费
Apple Developer Program 账号（¥688/年）才有**。免费 Apple ID 加不上这个 capability。

**没有付费账号 = 小组件拿不到数据 = widget 做出来是个摆设。**

另外：
- App ID 必须**显式注册**（`com.llkhs.batterywatch`），**不能用通配符 `com.llkhs.*`**
  ——通配符 App ID 不支持 App Groups
- App Group ID 需在 Developer Portal 手动创建并在 App ID 上启用 capability（网页可做）

### 6.2 路线 A：TestFlight（推荐）

```
GitHub Actions (macos-15 + Xcode 26)
  → XcodeGen 生成工程
  → xcodebuild archive -allowProvisioningUpdates
  → fastlane 上传 App Store Connect
  → iPhone 装 TestFlight → 下载
```
需要：付费账号 + **App Store Connect API Key (.p8)** 存 GitHub Secrets
优点：全自动、签名稳、widget 正常、90 天一轮；**完全不需要 Mac**
缺点：首次配置要 20 分钟点网页

### 6.3 路线 B：CI 出 IPA + 手机端自签工具装

```
GitHub Actions → archive → exportArchive（p12 + .mobileprovision 手动签名）
  → 产出签好的 IPA → 下载到 iPhone → Esign/AltStore 安装
```
需要：**自己账号的** p12 + mobileprovision（网页下载）
优点：不经 App Store Connect
缺点：⚠️ **Nested Bundle（`PlugIns/*.appex`）签名极易出错**，扩展掉签 = 小组件消失；
共享/购买的签名证书**不能用于此路线**（entitlement 里没有你的 App Group）

### 6.4 不能走的路线

- ❌ 借来的 / 网上买的共享 p12 → entitlement 里没有你的 App Group，widget 一定废
- ❌ 免费 Apple ID + 自签 → 7 天掉签 + 无 App Group
- ❌ 指望 CI 出**未签名** .app 装真机 → 装不上，之前 ThemeToggleApp 就是这么白做的

---

## 7. 未来扩展（只留口子，不实现）

| 方向 | 需要什么 |
|---|---|
| BLE 自动读电量 | GATT Battery Service `0x180F`；数据模型已预留事件来源字段 |
| 快捷指令 / Siri | AppIntents 已做，加 `AppShortcuts` 即可，零重构 |
| watchOS 表盘显示 | Core 是纯 Swift 包，直接复用 |
| iCloud 同步 | SwiftData 的 `ModelConfiguration` 换 CloudKit 容器 |

---

## 8. 里程碑

| # | 内容 | 交付 |
|---|---|---|
| M1 | Core 包：模型 + `LifetimeModel` + 单元测试 | 算法可验证，先跑通数学 |
| M2 | XcodeGen 工程 + App + SwiftData + 增删改查界面 | 手机能跑通记账 |
| M3 | 预测接入 + 通知 | 能收到"该备电池了" |
| M4 | 小组件（App Group + 快照 + 交互按钮） | 桌面能看能点 |
| M5 | CI 签名 + TestFlight 上传 | 自动出包 |

**M1 先做**：模型是唯一容易算错的地方，先用测试锁死，再谈界面。

---

## 9. 待确认

- [ ] p12 是**自己付费开发者账号**下的，还是网上买的共享证书？（决定小组件能不能做）
- [ ] 分发走路线 A（TestFlight）还是 B（自签 IPA）？
- [ ] App 名称、Bundle ID 前缀确认
