#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CheckJuice · 模型验证脚本
============================
两部分：
  A. 场景演示 —— 8 个人工构造的设备，看模型输出是否讲得通
  B. 校准检验 —— 蒙特卡洛：从已知真值生成数据，看模型能否把真值捞回来
如有任何一项不过关，Swift 就不该动手写。

⚠️ 时间单位一律**小时**，时刻一律 **naive datetime**。
"""

from __future__ import annotations

import math
import random
from datetime import datetime, timedelta

from lifetime_model import (
    BATTERY_KINDS, CENSORED_TYPES, CONFIDENCE_LABEL, DEFAULT_CONFIG,
    EXHAUSTED, FAULTY, INITIAL, PREVENTIVE, URGENCY_LABEL,
    Device, ReplacementEvent, fit, hours_between, predict,
)

D = 24.0                                # 一天多少小时，仅为让场景定义可读
TODAY = datetime(2026, 10, 14, 12, 0)


def make_device(name, kind, intervals_h, hours_since_last, types=None, **kw):
    """按「相邻更换间隔（小时）」构造设备；最后一个事件 = 当前电池的起算点。"""
    total = sum(intervals_h) + hours_since_last
    origin = TODAY - timedelta(hours=total)
    events = [ReplacementEvent(origin, INITIAL)]
    cur = origin
    for i, iv in enumerate(intervals_h):
        cur += timedelta(hours=iv)
        events.append(ReplacementEvent(cur, (types or [EXHAUSTED] * len(intervals_h))[i]))
    return Device(name=name, kind=kind, events=events, **kw)


# ───────────────────────────────────────────────────────────── A. 场景演示

SCENARIOS = [
    ("① 冷启动 · 刚添加", "cr2032", [], 0, None, 14*D),
    ("② 首次更换 · 1 个样本", "cr2032", [300*D], 60*D, None, 14*D),
    ("③ 两次更换 · 2 个样本", "cr2032", [300*D, 280*D], 90*D, None, 14*D),
    ("④ 多次更换 · 3 个样本", "aa_alkaline", [300*D, 280*D, 320*D], 100*D, None, 14*D),
    ("⑤ 含一颗坏电池", "cr2032", [300*D, 290*D, 310*D, 60*D, 295*D, 285*D], 120*D,
     [EXHAUSTED, EXHAUSTED, EXHAUSTED, FAULTY, EXHAUSTED, EXHAUSTED], 14*D),
    ("⑥ 混入预防性更换", "cr2032", [300*D, 120*D, 290*D, 310*D], 150*D,
     [EXHAUSTED, PREVENTIVE, EXHAUSTED, EXHAUSTED], 14*D),
    ("⑦ 老化趋势（寿命递减）", "cr2032", [400*D, 370*D, 330*D, 300*D, 270*D], 200*D,
     None, 30*D),
    ("⑧ 耗尽中未更换", "cr2032", [300*D, 290*D], 330*D, None, 14*D),
]


def run_scenarios():
    print("=" * 118)
    print(f"A. 场景演示   (现在 = {TODAY})   单位：小时")
    print("=" * 118)
    hdr = (f"{'场景':<24}{'n':>3}{'n_eff':>7}{'中位':>9}{'P10':>9}"
           f"{'已用':>9}{'剩余':>9}{'P10剩余':>9}  {'紧急度':<12}{'置信度'}")
    print(hdr)
    print("-" * 118)

    rows = []
    for name, kind, intervals, since, types, lead in SCENARIOS:
        dev = make_device(name, kind, intervals, since, types, notify_lead_hours=lead)
        p = predict(dev, TODAY)
        conf = p.confidence
        print(f"{name:<24}{p.posterior.n_observed:>3}{p.posterior.n_eff:>7.2f}"
              f"{p.median_hours:>9.1f}{p.p10_hours:>9.1f}{p.age_hours:>9.1f}"
              f"{p.remaining_hours:>9.1f}{p.p10_remaining_hours:>9.1f}  "
              f"{URGENCY_LABEL[p.urgency]:<12}{conf}")
        rows.append((name, dev, p))

    print()
    print("明细（第 ④ / ⑤ / ⑥ / ⑦ 例 —— 观察截尾观测是否被正确剔除）：")
    for name, dev, p in rows:
        if not name.startswith(("④", "⑤", "⑥", "⑦")):
            continue
        from lifetime_model import observed_intervals
        ex, ce = observed_intervals(dev)
        ordered = sorted(dev.events, key=lambda x: x.at)
        print(f"\n  {name}")
        print(f"    全部间隔(小时): "
              f"{[round(hours_between(s.at, e.at), 1) for s, e in zip(ordered, ordered[1:])]}")
        print(f"    进统计(有效)  : {[round(x, 1) for x in ex]}")
        print(f"    被剔除(截尾)  : {[(round(d, 1), t) for d, t in ce]}")
        print(f"    → 后验 m={p.posterior.m:.4f} σ_post={p.posterior.sigma:.4f} "
              f"σ_within={p.posterior.sigma_within:.4f} n_eff={p.posterior.n_eff:.2f}")
        print(f"    → 中位 {p.median_hours:.1f} 小时 · P10 {p.p10_hours:.1f} 小时 · "
              f"预计耗尽 {p.p50_exhaust_at} · 风险起点 {p.p10_exhaust_at} · "
              f"{URGENCY_LABEL[p.urgency]} · 置信度 {CONFIDENCE_LABEL[p.confidence]}")
    return rows


# ───────────────────────────────────────────────────────── B. 校准检验

def monte_carlo(trials=4000, seed=42):
    """从已知真值生成数据，检验模型能否把真值捞回来。

    真值设定：设备的中位寿命 L=300 天（7200 小时），设备内固有波动 σ_true=0.2（log 尺度）。
    先验故意给偏（按 CR2032 典型值 365 天，τ=0.5），检验模型是否被先验带跑。

    ⚠️ 因为全程在 **log 尺度**上比较，以下三个统计量与时间单位**无关** ——
       换成小时后，偏差% / 漏报% / 窗口宽度% 应当**逐个数值不变**。
       这既是校准检验，也是「换单位没改数学」的回归测试。

    检验项：
      1. 中位数偏差 —— 预测中位寿命 vs 真值，应随样本增加而收敛
      2. P10 覆盖率 —— 从真值抽一颗新电池，其寿命 ≤ 预测 P10 的频率应 ≈ 10%
                      （偏低 = 窗口开得太晚 = 该响的时候没响，这是最危险的失误）
      3. 区间宽度单调收窄 —— 样本越多，P10~中位 的窗口应越窄
    """
    random.seed(seed)
    L_TRUE_H = 300.0 * D          # 7200 小时
    SIGMA_TRUE = 0.2
    mu_true = math.log(L_TRUE_H)

    print()
    print("=" * 118)
    print(f"B. 蒙特卡洛校准检验   (真值: 中位 {L_TRUE_H:.0f} 小时 = 300 天, "
          f"σ_within={SIGMA_TRUE}, 先验故意偏成 365 天/τ=0.5, {trials} 次试验)")
    print("=" * 118)
    print(f"{'n':>4}{'n_eff':>9}{'中位预测':>11}{'偏差%':>9}"
          f"{'P10预测':>11}{'漏报%':>9}{'窗口宽度%':>11}"
          f"{'σ_within':>10}{'σ_pred':>9}")
    print("-" * 118)

    cfg = DEFAULT_CONFIG
    out = []
    for n in (1, 2, 3, 5, 8, 15):
        med_preds, p10_preds, widths, sigmas, swithins = [], [], [], [], []
        missed = 0
        for _ in range(trials):
            obs = [math.exp(random.gauss(mu_true, SIGMA_TRUE)) for _ in range(n)]
            dev = make_device(f"t{n}", "cr2032", obs, 0)
            p = predict(dev, TODAY)
            med_preds.append(p.median_hours)
            p10_preds.append(p.p10_hours)
            widths.append((p.median_hours - p.p10_hours) / p.median_hours)
            sigmas.append(p.sigma_pred)
            swithins.append(p.posterior.sigma_within)
            # 抽一颗「新电池」：若它比风险窗口起点还早阵亡 → 用户在预警前就被打脸
            new_life = math.exp(random.gauss(mu_true, SIGMA_TRUE))
            if new_life <= p.p10_hours:
                missed += 1

        med = sum(med_preds) / trials
        p10 = sum(p10_preds) / trials
        w = sum(widths) / trials
        sp = sum(sigmas) / trials
        sw = sum(swithins) / trials
        neff = fit(make_device("x", "cr2032", [300.0 * D] * n, 0), cfg).n_eff
        bias = (med - L_TRUE_H) / L_TRUE_H * 100
        miss = missed / trials * 100
        print(f"{n:>4}{neff:>9.2f}{med:>11.1f}{bias:>8.1f}%{p10:>11.1f}"
              f"{miss:>8.1f}%{w*100:>10.1f}%{sw:>10.3f}{sp:>9.4f}")
        out.append((n, med, bias, p10, miss, w, sp))

    print()
    print("判读标准：")
    print("  * 偏差%  ：|偏差| 应随样本增加收敛到 0 附近（先验刻意给偏，检验数据能否纠正它）")
    print("  * 漏报%  ：抽一颗新电池，若它比风险窗口起点还早阵亡 → 用户毫无预警就断供。")
    print("             **此值越低越安全**。高于 20% = 窗口开太晚，该响的时候没响。")
    print("  * 窗口宽度%：应单调收窄，但**不会收敛到 0** —— 那是 σ_min / σ_within 在起作用，")
    print("             是故意的：同一设备换同型号电池，寿命天然就有 15%~20% 的差异。")
    print("  * 以上三者都是 **log 尺度** 的相对量，与「天/小时」无关 → 换单位后必须逐位不变。")
    return out


if __name__ == "__main__":
    run_scenarios()
    monte_carlo()
