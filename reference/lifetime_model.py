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
* 逾期不自动修正：预测日过了就标"逾期 N 天"

本文件只依赖 Python 标准库。
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Optional, Sequence

# ════════════════════════════════════════════════════════════ 1. 常量与枚举

#: 电池种类 → (显示名, 冷启动先验寿命天数)
#: ⚠️ 这些只是「典型值」，真实寿命主要由设备功耗决定，所以先验置信度故意给得很低。
BATTERY_KINDS: dict[str, tuple[str, float]] = {
    "cr2032":       ("CR2032 纽扣锂电",  365.0),
    "cr2450":       ("CR2450 纽扣锂电",  730.0),
    "cr123a":       ("CR123A 锂电",      900.0),
    "aa_alkaline":  ("AA 碱性",          180.0),
    "aa_lithium":   ("AA 锂铁",          540.0),
    "aaa_alkaline": ("AAA 碱性",         120.0),
    "9v":           ("9V 碱性",          365.0),
    "lr44":         ("LR44 碱性纽扣",    270.0),
    "builtin_li":   ("内置锂电",        1095.0),
    "other":        ("其他 / 未知",      365.0),
}

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

    tau_default: float = 0.5   # 冷启动先验相对不确定度（±50%）
    tau_user: float = 0.35     # 用户手填寿命时的先验不确定度
    tau_ref: float = 0.25      # 借用同型号设备历史当先验时的不确定度
    sigma_min: float = 0.15    # 方差下限：同设备换同型号电池，寿命天然差 15%
    sigma_unidentified: float = 0.30   # 样本 <3 时无法估计方差，用此值兜底
    sigma_pred_cap: float = 0.70       # 预测分布宽度上限，防止冷启动出现荒谬窗口
    beta: float = 0.7          # 指数加权衰减：半衰期约 2 次更换
    z10: float = 1.2815515655446004    # 标准正态 P10 分位（负号见下文）
    min_samples_for_variance: int = 3  # 至少 3 个有效间隔才敢相信样本方差


DEFAULT_CONFIG = ModelConfig()


# ════════════════════════════════════════════════════════════ 3. 数据模型

@dataclass
class ReplacementEvent:
    """一次更换（或首次安装）事件。

    约定：``type`` 描述的是「**上一颗**电池是被怎么处理掉的」，
    因此 ``events[i]`` 与 ``events[i-1]`` 之间的那段间隔，
    其有效性由 ``events[i].type`` 决定。
    """
    at: date
    type: str = EXHAUSTED
    note: str = ""


@dataclass
class Device:
    """一台被盯着的设备。"""
    name: str
    kind: str
    events: list[ReplacementEvent] = field(default_factory=list)
    notify_lead_days: int = 14
    nominal_life_days: Optional[float] = None   # 用户手填 → 覆盖电池种类的先验
    ref_prior: Optional[tuple[float, float]] = None  # (m, tau) 来自同型号设备

    @property
    def installed_at(self) -> date:
        """当前这颗电池的起算时间 = 最后一次事件的日期。"""
        return sorted(self.events, key=lambda e: e.at)[-1].at

    def prior(self, cfg: ModelConfig = DEFAULT_CONFIG) -> tuple[float, float]:
        """返回 (m0, tau0)。优先级：参照设备 > 用户手填 > 电池种类典型值。"""
        if self.ref_prior is not None:
            # 参照先验自带不确定度，直接采用，不要套 cfg.tau_ref
            return self.ref_prior[0], self.ref_prior[1]
        life = self.nominal_life_days
        if life is not None and life > 0:
            return math.log(life), cfg.tau_user
        _, typical = BATTERY_KINDS.get(self.kind, BATTERY_KINDS["other"])
        return math.log(typical), cfg.tau_default


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
    """给 UI / 小组件用的最终结论。"""
    median_days: float        # 预测中位寿命
    p10_days: float           # P10 下界寿命（风险窗口起点）
    median_date: date         # 预计耗尽日
    risk_date: date           # 风险窗口起点
    remaining_days: int       # 距预计耗尽日还有几天（可为负 = 逾期）
    risk_remaining_days: int  # 距风险窗口还有几天
    age_days: int             # 当前电池已用天数
    ratio: float              # 已用 / 中位寿命
    sigma_pred: float         # 预测分布宽度 = sqrt(σ_post² + σ_within²)，已封顶
    urgency: str
    confidence: str
    posterior: Posterior


# ════════════════════════════════════════════════════════════ 4. 观测提取

def observed_intervals(device: Device) -> tuple[list[float], list[tuple[float, str]]]:
    """把事件序列拆成 (有效间隔, 截尾间隔)。

    * 有效间隔：终点事件为 ``exhausted`` → 计入寿命统计
    * 截尾间隔：终点事件为 ``preventive`` / ``faulty`` → **剔除出寿命统计**

    注意：截尾观测虽不进统计，但它**照样重置了起算点**——
    因为当时确实装上了新电池。这是最容易做错的地方。
    """
    events = sorted(device.events, key=lambda e: e.at)
    exhausted: list[float] = []
    censored: list[tuple[float, str]] = []

    for prev, cur in zip(events, events[1:]):
        days = float((cur.at - prev.at).days)
        if days <= 0:
            continue
        if cur.type == EXHAUSTED:
            exhausted.append(days)
        elif cur.type in CENSORED_TYPES:
            censored.append((days, cur.type))
        # INITIAL 不作为间隔终点，忽略
    return exhausted, censored


# ════════════════════════════════════════════════════════════ 5. 加权统计

def weighted_log_stats(xs: Sequence[float], beta: float) -> tuple[float, Optional[float], float]:
    """对 log 尺度的观测做指数加权统计。

    近期观测权重更大（``w_i = beta^(n-1-i)``），因为设备老化、季节变化是渐进的。
    原始观测数不足时，样本方差不可信，返回 ``None``。

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
    """共轭更新：把观测到的寿命间隔融进先验，得到参数后验。"""
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

def _round_half_up(x: float) -> int:
    """四舍五入（正数下的 away-from-zero）。

    必须显式定义：Python 内建 round() 是**银行家舍入**（round(0.5)==0），
    而 Swift 的 .rounded() 默认是 .toNearestOrAwayFromZero。
    两者在 .5 边界上会差 1 天 —— 这是 Swift 移植期最隐蔽的坑，
    所以在参考实现里就把口径钉死。
    """
    return int(math.floor(x + 0.5))


def predict(device: Device, today: date,
            cfg: ModelConfig = DEFAULT_CONFIG) -> Prediction:
    """产出完整预测。"""
    post = fit(device, cfg)
    installed = device.installed_at
    age = (today - installed).days

    median_days = math.exp(post.m)

    # ★ 关键修订（相对 DESIGN.md §3.5）：
    # 风险窗口要预测的是「**当前这颗**电池什么时候死」，而不是「期望寿命的下界」。
    # 单颗电池的寿命本身就有 σ_within 的固有波动，再加上对 m 的不确定度 σ_post，
    # 预测分布宽度应为 σ_pred = sqrt(σ_post² + σ_within²)。
    # 用 σ_post 会系统性偏乐观（窗口开得太晚），而本 App 的失败代价正是「没电了才发现」。
    sigma_pred = math.sqrt(post.sigma ** 2 + post.sigma_within ** 2)
    sigma_pred = min(sigma_pred, cfg.sigma_pred_cap)

    p10_days = math.exp(post.m - cfg.z10 * sigma_pred)

    median_date = installed + timedelta(days=_round_half_up(median_days))
    risk_date = installed + timedelta(days=_round_half_up(p10_days))
    remaining = (median_date - today).days
    risk_remaining = (risk_date - today).days
    ratio = age / median_days if median_days > 0 else 1.0

    if remaining < 0:
        urgency = URGENCY_OVERDUE       # 已过预测中位日
    elif risk_remaining <= 0:
        urgency = URGENCY_RISK          # 已进入风险窗口（P10 之后）
    elif risk_remaining <= device.notify_lead_days:
        urgency = URGENCY_STOCKUP       # 距风险窗口开启不足 lead 天 → 该备货
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
        median_days=median_days,
        p10_days=p10_days,
        median_date=median_date,
        risk_date=risk_date,
        remaining_days=remaining,
        risk_remaining_days=risk_remaining,
        age_days=age,
        ratio=ratio,
        sigma_pred=sigma_pred,
        urgency=urgency,
        confidence=confidence,
        posterior=post,
    )


URGENCY_LABEL = {
    URGENCY_OVERDUE: "🔴 已逾期",
    URGENCY_RISK:    "🟠 风险窗口",
    URGENCY_STOCKUP: "🟡 该备货",
    URGENCY_NORMAL:  "🟢 正常",
}

CONFIDENCE_LABEL = {
    CONFIDENCE_LOW:    "低（样本不足，误差可能 ±50%）",
    CONFIDENCE_MEDIUM: "中",
    CONFIDENCE_HIGH:   "高",
}
