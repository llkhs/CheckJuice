#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CheckJuice · 寿命预测模型 —— 参考实现（Reference Implementation）
====================================================================
存在意义
--------
本机 iSH 没有 Swift 工具链，Swift 代码写出来无法编译、无法测试。
因此在 Swift 落地之前，先用可运行的语言把 DESIGN.md §3 的数学实现并实测，
验证通过后逐行移植到 CheckJuiceCore（纯 Swift Package）。
本文件产出的数值同时作为 Swift 单元测试的黄金期望值（golden values）。

设计纪律（对应 DESIGN.md）
--------------------------
* 对数正态建模：寿命非负且右偏，log(寿命) ~ Normal(m, σ²)
* 正态-正态共轭：闭式解，无采样、无数值优化
* 方差下限 σ_min：样本再少也不给出骗人的精度
* 截尾观测：preventive / faulty 的间隔不进寿命统计，但仍重置起算点
* 耗尽中不自动修正：预测时刻过了就标「耗尽中 N 小时」

★ 时间单位一律是「小时」，时刻类型一律是 ``datetime``
--------------------------------------------------------------------
早期版本用 ``date`` + 整「天」建模，那是错的：
``(a - b).days`` 会**向下取整**，把一个 93.6 小时的间隔砍成 72 小时（-23%）。
而且 ``date`` 根本没有「小时」这个维度 —— 4 天寿命的纽扣电池，
模型分辨率只有 25%（1 天 / 4 天）。
本 App 的失败代价是「没电了才发现」，任何取整都必须朝**保守**方向，
不能靠截断引入系统性低估。

本文件只依赖 Python 标准库。
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Optional, Sequence

# ════════════════════════════════════════════════════════════ 1. 常量与枚举

# 事件类型：描述「刚刚耗尽的那颗电池是被怎么处理掉的」
INITIAL    = "initial"     # 首次安装，永不作为间隔终点
EXHAUSTED  = "exhausted"   # 自然耗尽 → 有效样本，计入寿命统计
PREVENTIVE = "preventive"  # 提前预防性更换 → 截尾观测，剔除出寿命统计
FAULTY     = "faulty"      # 电池质量问题（漏液/失效）→ 截尾观测，剔除

CENSORED_TYPES = (PREVENTIVE, FAULTY)

# 置信度分级
CONFIDENCE_LOW, CONFIDENCE_MEDIUM, CONFIDENCE_HIGH = "low", "medium", "high"

# 紧急度分级
URGENCY_OVERDUE, URGENCY_RISK, URGENCY_STOCKUP, URGENCY_NORMAL = (
    "overdue", "risk", "stockUp", "normal",
)


# ════════════════════════════════════════════════════════════ 2. 模型配置

@dataclass(frozen=True)
class ModelConfig:
    """模型超参数。集中在一处，方便调参与写测试。"""

    tau_user: float = 0.5      # 用户手填「大概能用多久」的先验不确定度（±50%）——
                               # 那本质还是个人口级猜测：刚创建时一次实测都没有。
                               # 拿到真样本后 σ_post 会被数据压下去，这个宽度只在头几轮起作用。
    sigma_min: float = 0.15    # 方差下限：同设备换同型号电池，寿命天然差 15%
    sigma_unidentified: float = 0.30   # 样本 <3 时无法估计方差，用此值兜底
    sigma_pred_cap: float = 0.70       # 预测分布宽度上限，防止冷启动出现荒谬窗口
    beta: float = 0.7          # 指数加权衰减：半衰期约 2 次更换
    z10: float = 1.2815515655446004    # 标准正态 P10 分位
    min_samples_for_variance: int = 3  # 至少 3 个有效间隔才敢相信样本方差

    # ── 间隔合理性下限（护栏）─────────────────────────────────────────
    # 真实案例：用户填「100 天」，添加后 2 分钟就点了「自然耗尽」，
    # 模型把这 2 分钟当成一次真实寿命观测 —— 它带着 11 倍于先验的精度权重，
    # 后验中位寿命从 100 天直接塌到 39 分钟。
    #
    # 一段间隔短于下限，说明它不可能是「一颗电池的真实寿命」，
    # 只能是误触 / 修正 / 测试。这类间隔**不进寿命统计，但照样重置起算点**
    # （当时确实装上了新电池）。
    sample_floor_hours: float = 1.0        # 绝对上限：不足 1 小时必然是误触
    sample_floor_fraction: float = 0.10    # 相对标称寿命的比例


DEFAULT_CONFIG = ModelConfig()


def sample_floor_hours_for(device: "Device", cfg: ModelConfig = DEFAULT_CONFIG) -> float:
    """这台设备的「间隔太短」下限。**单位：小时。**

    取 ``min(绝对上限, 标称寿命 × 比例)``：

    * 100 天的电池 → ``min(1h, 240h)`` = **1 小时**
    * 4 小时的电池 → ``min(1h, 24min)`` = **24 分钟**（放宽，别把真实的短周期当垃圾）

    纯绝对阈值会把 4 小时电池的真实周期误杀，所以对极短寿命的设备按比例放宽。
    """
    nominal = max(device.nominal_life_hours, 1.0)
    return min(cfg.sample_floor_hours, cfg.sample_floor_fraction * nominal)


#: 默认提前量：距风险窗口开启不足这么多小时 → 该备货。
#: 336 小时 = 14 天 —— 留出快递 / 出门采购的时间。
#: ⚠️ 这个值决定了 App 什么时候催你，是**产品决策**，不是模型推导出来的。
DEFAULT_NOTIFY_LEAD_HOURS: float = 336.0


def hours_between(start: datetime, end: datetime) -> float:
    """两个时刻之间的**精确**小时数（浮点，含小数）。

    绝不要退回 ``(end - start).days`` —— 那是向下取整的整数天，
    会把 93.6 小时砍成 72 小时（-23%）。
    """
    return (end - start).total_seconds() / 3600.0


# ════════════════════════════════════════════════════════════ 3. 数据模型

@dataclass
class ReplacementEvent:
    """一次更换（或首次安装）事件。

    约定：``type`` 描述的是「**上一颗**电池是被怎么处理掉的」，
    因此 ``events[i]`` 与 ``events[i-1]`` 之间的那段间隔，
    其有效性由 ``events[i].type`` 决定。
    """
    at: datetime
    type: str = EXHAUSTED
    note: str = ""


@dataclass
class Device:
    """一台被盯着的设备。

    用户创建时只填 ``name`` 和 ``nominal_life_hours``（「大概能用多久」）——
    没有电池型号选择器，因为型号根本不决定寿命（同一颗 CR2032 在高功耗传感器里
    撑几天，在电子秤上撑几年）。之后每换一次电池补一个事件，
    样本越多先验被压得越扁，预测越准。
    """
    name: str
    nominal_life_hours: float                        # 用户手填的预期寿命（小时）= 冷启动先验
    events: list[ReplacementEvent] = field(default_factory=list)
    notify_lead_hours: float = DEFAULT_NOTIFY_LEAD_HOURS
    ref_prior: Optional[tuple[float, float]] = None  # (m, tau) 借用同类设备的历史

    @property
    def installed_at(self) -> datetime:
        """当前这颗电池的起算时刻 = 最后一次事件的时刻。"""
        return sorted(self.events, key=lambda e: e.at)[-1].at

    def prior(self, cfg: ModelConfig = DEFAULT_CONFIG) -> tuple[float, float]:
        """返回 (m0, tau0)。参照先验（若显式给了）压过用户手填的估计值。"""
        if self.ref_prior is not None:
            # 参照先验自带不确定度，直接采用，不要套 cfg.tau_user
            return self.ref_prior[0], self.ref_prior[1]
        # 手改 JSON 可能写出 0 / 负数，log 会变 -inf 污染整条算术 → 设 1 小时下限
        return math.log(max(self.nominal_life_hours, 1.0)), cfg.tau_user


@dataclass(frozen=True)
class Posterior:
    """参数后验。``m``/``sigma`` 是 log 尺度的均值与标准差。"""
    m: float
    sigma: float          # σ_post：对「期望寿命」的不确定度
    n_eff: float          # Kish 有效样本量
    n_observed: int       # 原始有效间隔数
    sigma_within: float   # 设备内固有波动（电池颗与颗之间的差异）


@dataclass(frozen=True)
class Prediction:
    """给 UI / 小组件用的最终结论。**所有时间量单位均为小时。**"""
    median_hours: float         # 预测中位寿命
    p10_hours: float            # P10 下界寿命（风险窗口起点）
    p50_exhaust_at: datetime    # 预计耗尽时刻（中位）
    p10_exhaust_at: datetime    # 风险窗口起点时刻（P10，早于中位）
    remaining_hours: float      # 距中位耗尽还有几小时（可为负 = 逾期）
    p10_remaining_hours: float  # 距风险窗口还有几小时（可为负）
    age_hours: float            # 当前电池已用小时
    ratio: float                # 已用 / 中位寿命
    sigma_pred: float           # 预测分布宽度 = sqrt(σ_post² + σ_within²)，已封顶
    urgency: str
    confidence: str
    posterior: Posterior


# ════════════════════════════════════════════════════════════ 4. 观测提取

#: 间隔的判定结果
INTERVAL_SAMPLE    = "sample"     # 计入寿命统计
INTERVAL_CENSORED  = "censored"   # 截尾观测（预防性更换 / 故障），不进统计
INTERVAL_TOO_SHORT = "tooShort"   # 间隔短得不可能是真实寿命 → 不进统计


@dataclass(frozen=True)
class IntervalAudit:
    """一段相邻更换间隔的判定结果。**单位：小时。**

    存在的意义是让「哪几段进了统计、为什么没进」变成**可显示的事实**，
    而不是藏在模型里的黑盒 —— 界面要靠它给每条记录打标。
    """
    start: datetime
    end: datetime
    hours: float
    type: str          # 终点事件的类型，即「上一颗电池是怎么结束的」
    reason: str        # INTERVAL_* 之一
    floor_hours: float  # 判定时用的下限（方便界面解释「为什么不算」）

    @property
    def counted(self) -> bool:
        return self.reason == INTERVAL_SAMPLE


def audit_intervals(device: Device, cfg: ModelConfig = DEFAULT_CONFIG) -> list[IntervalAudit]:
    """把事件序列逐段判定，返回每一段间隔的完整审计结果。

    这是间隔提取的**唯一真相源**：``observed_intervals`` 只是它的一个投影，
    界面也用它来给记录打「未计入统计」的标。

    判定优先级：间隔过短 > 截尾 > 有效样本。
    （一段 2 分钟的「预防性更换」也是过短，报过短更准确。）
    """
    events = sorted(device.events, key=lambda e: e.at)
    floor = sample_floor_hours_for(device, cfg)
    out: list[IntervalAudit] = []

    for prev, cur in zip(events, events[1:]):
        hours = hours_between(prev.at, cur.at)
        if hours <= 0:
            # 时间倒挂 / 同一时刻，事件本身保留（起算点照走），但它显然不是一段寿命
            out.append(IntervalAudit(prev.at, cur.at, hours, cur.type, INTERVAL_TOO_SHORT, floor))
            continue
        if hours < floor:
            reason = INTERVAL_TOO_SHORT
        elif cur.type == EXHAUSTED:
            reason = INTERVAL_SAMPLE
        elif cur.type in CENSORED_TYPES:
            reason = INTERVAL_CENSORED
        else:
            continue  # INITIAL 不作为间隔终点
        out.append(IntervalAudit(prev.at, cur.at, hours, cur.type, reason, floor))
    return out


def observed_intervals(device: Device) -> tuple[list[float], list[tuple[float, str]]]:
    """把事件序列拆成 (有效间隔, 截尾间隔)。**单位：小时。**

    * 有效间隔：终点事件为 ``exhausted`` **且长度过得了护栏** → 计入寿命统计
    * 截尾间隔：终点事件为 ``preventive`` / ``faulty`` → **剔除出寿命统计**

    注意：截尾观测虽不进统计，但它**照样重置了起算点**——
    因为当时确实装上了新电池。这是最容易做错的地方。
    """
    exhausted: list[float] = []
    censored: list[tuple[float, str]] = []
    for a in audit_intervals(device):
        if a.reason == INTERVAL_SAMPLE:
            exhausted.append(a.hours)
        elif a.reason == INTERVAL_CENSORED:
            censored.append((a.hours, a.type))
    return exhausted, censored


# ════════════════════════════════════════════════════════════ 5. 加权统计

def weighted_log_stats(xs: Sequence[float], beta: float) -> tuple[float, Optional[float], float]:
    """对 log 尺度的观测做指数加权统计。

    近期观测权重更大（``w_i = beta^(n-1-i)``），因为设备老化、季节变化是渐进的。
    原始观测数不足时，样本方差不可信，返回 ``None``。

    ⚠️ 这里在 **log 尺度**上计算，所以与「天 / 小时」无关 —— 换单位不改变任何数值。

    返回 ``(加权均值, 加权方差 或 None, Kish 有效样本量)``。
    """
    n = len(xs)
    if n == 0:
        return 0.0, None, 0.0

    ws = [beta ** (n - 1 - i) for i in range(n)]
    sw = sum(ws)
    sw2 = sum(w * w for w in ws)
    x_bar = sum(w * x for w, x in zip(ws, xs)) / sw

    # 可靠性权重下的无偏方差：分母 = Σw − Σw²/Σw
    denom = sw - sw2 / sw
    s2: Optional[float] = None
    if n >= 3 and denom > 1e-9:
        s2 = sum(w * (x - x_bar) ** 2 for w, x in zip(ws, xs)) / denom

    n_eff = sw * sw / sw2   # Kish 有效样本量
    return x_bar, s2, n_eff


# ════════════════════════════════════════════════════════════ 6. 参数拟合

def fit(device: Device, cfg: ModelConfig = DEFAULT_CONFIG) -> Posterior:
    """共轭更新：把观测到的寿命间隔融进先验，得到参数后验。

    ⚠️ 全程在 log 尺度上，与时间单位无关。
    """
    m0, tau0 = device.prior(cfg)
    exhausted, _ = observed_intervals(device)

    if not exhausted:
        # 纯先验。此时「设备内波动」完全未知，与先验不确定度同宽。
        return Posterior(m=m0, sigma=tau0, n_eff=0.0, n_observed=0,
                         sigma_within=tau0)

    xs = [math.log(d) for d in exhausted]
    x_bar, s2, n_eff = weighted_log_stats(xs, cfg.beta)

    # 设备内固有波动。样本不足时不敢信样本方差，用兜底值。
    if s2 is None:
        sigma_within = cfg.sigma_unidentified
    else:
        sigma_within = max(math.sqrt(s2), cfg.sigma_min)

    # 后验精度 = 先验精度 + 数据精度
    prec = 1.0 / (tau0 ** 2) + n_eff / (sigma_within ** 2)
    m = (m0 / (tau0 ** 2) + n_eff * x_bar / (sigma_within ** 2)) / prec
    sigma_post = max(1.0 / math.sqrt(prec), cfg.sigma_min)

    return Posterior(m=m, sigma=sigma_post, n_eff=n_eff,
                     n_observed=len(exhausted), sigma_within=sigma_within)


# ════════════════════════════════════════════════════════════ 7. 预测

def predict(device: Device, today: datetime,
            cfg: ModelConfig = DEFAULT_CONFIG) -> Prediction:
    """产出完整预测。``today`` 是「现在」这个精确时刻。"""
    post = fit(device, cfg)
    installed = device.installed_at
    age_hours = hours_between(installed, today)

    median_hours = math.exp(post.m)

    # ★ 关键修订（相对 DESIGN.md §3.5）：
    # 风险窗口要预测的是「**当前这颗**电池什么时候死」，而不是「期望寿命的下界」。
    # 单颗电池的寿命本身就有 σ_within 的固有波动，再加上对 m 的不确定度 σ_post，
    # 预测分布宽度应为 σ_pred = sqrt(σ_post² + σ_within²)。
    # 用 σ_post 会系统性偏乐观（窗口开得太晚），而本 App 的失败代价正是「没电了才发现」。
    sigma_pred = math.sqrt(post.sigma ** 2 + post.sigma_within ** 2)
    sigma_pred = min(sigma_pred, cfg.sigma_pred_cap)

    p10_hours = math.exp(post.m - cfg.z10 * sigma_pred)

    # 直接对 datetime 加小时，不再 round 到整天、不再经过 date
    p50_exhaust_at = installed + timedelta(hours=median_hours)
    p10_exhaust_at = installed + timedelta(hours=p10_hours)
    remaining_hours = hours_between(today, p50_exhaust_at)
    p10_remaining_hours = hours_between(today, p10_exhaust_at)
    ratio = age_hours / median_hours if median_hours > 0 else 1.0

    if remaining_hours < 0:
        urgency = URGENCY_OVERDUE            # 已过预测中位时刻
    elif p10_remaining_hours <= 0:
        urgency = URGENCY_RISK               # 已进入风险窗口（P10 之后）
    elif p10_remaining_hours <= device.notify_lead_hours:
        urgency = URGENCY_STOCKUP            # 距风险窗口开启不足 lead 小时 → 该备货
    else:
        urgency = URGENCY_NORMAL

    n = post.n_observed
    if n == 0:
        confidence = CONFIDENCE_LOW
    elif n == 1:
        confidence = CONFIDENCE_LOW
    elif n < 4:
        confidence = CONFIDENCE_MEDIUM
    else:
        confidence = CONFIDENCE_HIGH

    return Prediction(
        median_hours=median_hours,
        p10_hours=p10_hours,
        p50_exhaust_at=p50_exhaust_at,
        p10_exhaust_at=p10_exhaust_at,
        remaining_hours=remaining_hours,
        p10_remaining_hours=p10_remaining_hours,
        age_hours=age_hours,
        ratio=ratio,
        sigma_pred=sigma_pred,
        urgency=urgency,
        confidence=confidence,
        posterior=post,
    )


# ════════════════════════════════════════════════════════════ 8. 显示口径

def floor_to_hour(t: datetime) -> datetime:
    """把时刻**向下**取整到整点。

    显示「将在 XX 时刻耗尽」时必须向下取整：宁可说「23:00」，
    也不要说「次日 00:00」—— 本 App 的失败代价是「没电了才发现」，
    所有取整一律朝保守方向。Swift 侧必须用同一口径（``Date`` 截断分秒）。
    """
    return t.replace(minute=0, second=0, microsecond=0)


def whole_hours(x: float) -> int:
    """把小时数**朝零截断**到整数小时。

    为什么朝零而不是向下 —— 两个方向都要「宁少不多」：
      * 剩余 619.4 小时 → 报 619，不吹牛说自己撑得久；
      * 逾期 619.4 小时 → 报 619，不把逾期说得比实际更严重。
    用 floor 的话负数会变 -620（=-「逾期 620 小时」），那是**夸大**逾期程度，
    和吹牛一样是撒谎。Swift 侧 `LifetimeModel.wholeHours` 用 `.rounded(.towardZero)`，
    两边必须一致，否则同一个 -619.35 会显示成 619 vs 620。
    """
    return int(x)          # Python 的 int() 就是朝零截断


def format_remaining_short(hours: float) -> str:
    """「剩余时长」格式的参考输出（App 设置里可选的一种显示方式）。

    单位自适应，不让 5 号电池显示「还剩 1443 小时」这种假精度：
      * |h| >= 1440（60 天）→ 「约 N 个月」
      * |h| >= 48  （2 天）  → 「约 N 天」
      * |h| >= 1   （1 小时）→ 「还剩 N 小时」
      * |h| >= 1 分钟        → 「还剩 N 分钟」
      * 更小                 → 「不足 1 分钟」

    负数（已耗尽）走同一套量级分支，只是措辞换成「耗尽中」且**不加「约」**——
    耗尽多久是既成事实，不需要修饰；「耗尽中 3 个月」也比「耗尽中 2160 小时」好读。

    **符号必须用原始值判断，不能先 whole_hours 截断**：
    whole_hours(-0.892) == 0，那样「已耗尽 53 分钟」会显示成「还剩 0 小时」——
    已经没电了却告诉用户还剩着。真机反馈过这个 bug（两个方向都是它）。

    不足 1 小时改用分钟，是因为 1 小时的电池还剩 22 分钟时显示「还剩 0 小时」，
    用户分不出「马上没电」和「真的没了」，而这两件事该做的事完全不同。

    与 Swift 的 `Prediction.adaptiveHours` 必须逐字符一致。
    """
    if not math.isfinite(hours):
        return "—"

    exhausted = hours < 0
    magnitude = abs(hours)

    if magnitude >= 1440:
        n, unit = int(magnitude // 720), "个月"      # 一个月按 30 天算
        prefix = "耗尽中" if exhausted else "约"
        return f"{prefix} {n} {unit}"
    if magnitude >= 48:
        n, unit = int(magnitude // 24), "天"
        prefix = "耗尽中" if exhausted else "约"
        return f"{prefix} {n} {unit}"
    if magnitude >= 1:
        n = int(magnitude)                           # 朝零截断
        prefix = "耗尽中" if exhausted else "还剩"
        return f"{prefix} {n} 小时"

    minutes = int(magnitude * 60)
    if minutes >= 1:
        prefix = "耗尽中" if exhausted else "还剩"
        return f"{prefix} {minutes} 分钟"
    return "刚刚耗尽" if exhausted else "不足 1 分钟"


URGENCY_LABEL = {
    URGENCY_OVERDUE: "🔴 耗尽中",
    URGENCY_RISK:    "🟠 风险窗口",
    URGENCY_STOCKUP: "🟡 该备货",
    URGENCY_NORMAL:  "🟢 正常",
}

CONFIDENCE_LABEL = {
    CONFIDENCE_LOW:    "低（样本不足，误差可能 ±50%）",
    CONFIDENCE_MEDIUM: "中",
    CONFIDENCE_HIGH:   "高",
}
