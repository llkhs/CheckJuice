#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BatteryWatch · 模型验证脚本
============================
两部分：
  A. 场景演示 —— 6 个人工构造的设备，看模型输出是否讲得通
  B. 校准检验 —— 蒙特卡洛：从已知真值生成数据，看模型能否把真值捞回来
如有任何一项不过关，Swift 就不该动手写。
"""

from __future__ import annotations

import math
import random
from datetime import date, timedelta

from lifetime_model import (
    BATTERY_KINDS, CENSORED_TYPES, CONFIDENCE_LABEL, DEFAULT_CONFIG,
    EXHAUSTED, FAULTY, INITIAL, PREVENTIVE, URGENCY_LABEL,
    Device, ReplacementEvent, fit, predict,
)

TODAY = date(2026, 10, 14)


def make_device(name, kind, intervals, days_since_last, types=None, **kw):
    """按「相邻更换间隔」构造设备；最后一个事件 = 当前电池的起算点。"""
    total = sum(intervals) + days_since_last
    origin = TODAY - timedelta(days=total)
    events = [ReplacementEvent(origin, INITIAL)]
    cur = origin
    for i, iv in enumerate(intervals):
        cur += timedelta(days=iv)
        events.append(ReplacementEvent(cur, (types or [EXHAUSTED] * len(intervals))[i]))
    return Device(name=name, kind=kind, events=events, **kw)


# ───────────────────────────────────────────────────────────── A. 场景演示

SCENARIOS = [
    ("① 冷启动 · 刚添加", "cr2032", [], 0, None, 14),
    ("② 首次更换 · 1 个样本", "cr2032", [300], 60, None, 14),
    ("③ 两次更换 · 2 个样本", "cr2032", [300, 280], 90, None, 14),
    ("④ 多次更换 · 3 个样本", "aa_alkaline", [300, 280, 320], 100, None, 14),
    ("⑤ 含一颗坏电池", "cr2032", [300, 290, 310, 60, 295, 285], 120,
     [EXHAUSTED, EXHAUSTED, EXHAUSTED, FAULTY, EXHAUSTED, EXHAUSTED], 14),
    ("⑥ 混入预防性更换", "cr2032", [300, 120, 290, 310], 150,
     [EXHAUSTED, PREVENTIVE, EXHAUSTED, EXHAUSTED], 14),
    ("⑦ 老化趋势（寿命递减）", "cr2032", [400, 370, 330, 300, 270], 200,
     None, 30),
    ("⑧ 已逾期未更换", "cr2032", [300, 290], 330, None, 14),
]


def run_scenarios():
    print("=" * 108)
    print(f"A. 场景演示   (今天 = {TODAY})")
    print("=" * 108)
    hdr = (f"{'场景':<24}{'n':>3}{'n_eff':>7}{'中位':>7}{'P10':>7}"
           f"{'已用':>6}{'剩余':>7}{'窗口':>7}  {'紧急度':<12}{'置信度'}")
    print(hdr)
    print("-" * 108)

    rows = []
    for name, kind, intervals, since, types, lead in SCENARIOS:
        dev = make_device(name, kind, intervals, since, types, notify_lead_days=lead)
        p = predict(dev, TODAY)
        conf = p.confidence
        print(f"{name:<24}{p.posterior.n_observed:>3}{p.posterior.n_eff:>7.2f}"
              f"{p.median_days:>7.0f}{p.p10_days:>7.0f}{p.age_days:>6}"
              f"{p.remaining_days:>7}{p.risk_remaining_days:>7}  "
              f"{URGENCY_LABEL[p.urgency]:<12}{conf}")
        rows.append((name, dev, p))

    print()
    print("明细（第 ④ / ⑤ / ⑥ 例 —— 观察截尾观测是否被正确剔除）：")
    for name, dev, p in rows:
        if not name.startswith(("④", "⑤", "⑥", "⑦")):
            continue
        from lifetime_model import observed_intervals
        ex, ce = observed_intervals(dev)
        print(f"\n  {name}")
        print(f"    全部间隔      : "
              f"{[ (e.at - s.at).days for s, e in zip(sorted(dev.events, key=lambda x: x.at), sorted(dev.events, key=lambda x: x.at)[1:]) ]}")
        print(f"    进统计(有效)  : {[round(x) for x in ex]}")
        print(f"    被剔除(截尾)  : {[(round(d), t) for d, t in ce]}")
        print(f"    → 后验 m={p.posterior.m:.4f} σ_post={p.posterior.sigma:.4f} "
              f"σ_within={p.posterior.sigma_within:.4f} n_eff={p.posterior.n_eff:.2f}")
        print(f"    → 中位 {p.median_days:.0f} 天 · P10 {p.p10_days:.0f} 天 · "
              f"预计耗尽 {p.median_date} · 风险起点 {p.risk_date} · "
              f"{URGENCY_LABEL[p.urgency]} · 置信度 {CONFIDENCE_LABEL[p.confidence]}")
    return rows


# ───────────────────────────────────────────────────────── B. 校准检验

def monte_carlo(trials=4000, seed=42):
    """从已知真值生成数据，检验模型能否把真值捞回来。

    真值设定：设备的中位寿命 L=300 天，设备内固有波动 σ_true=0.2（log 尺度）。
    先验故意给偏（按 CR2032 典型值 365 天，τ=0.5），检验模型是否被先验带跑。

    检验项：
      1. 中位数偏差 —— 预测中位寿命 vs 真值 300 天，应随样本增加而收敛
      2. P10 覆盖率 —— 从真值抽一颗新电池，其寿命 ≤ 预测 P10 的频率应 ≈ 10%
                      （偏低 = 窗口开得太晚 = 该响的时候没响，这是最危险的失误）
      3. 区间宽度单调收窄 —— 样本越多，P10~中位 的窗口应越窄
    """
    random.seed(seed)
    L_TRUE = 300.0
    SIGMA_TRUE = 0.2
    mu_true = math.log(L_TRUE)

    print()
    print("=" * 108)
    print(f"B. 蒙特卡洛校准检验   (真值: 中位 {L_TRUE:.0f} 天, σ_within={SIGMA_TRUE}, "
          f"先验故意偏成 365 天/τ=0.5, {trials} 次试验)")
    print("=" * 108)
    print(f"{'n':>4}{'n_eff':>9}{'中位预测':>10}{'偏差%':>9}"
          f"{'P10预测':>10}{'漏报%':>9}{'窗口宽度%':>11}"
          f"{'σ_within':>10}{'σ_pred':>9}")
    print("-" * 108)

    cfg = DEFAULT_CONFIG
    out = []
    for n in (1, 2, 3, 5, 8, 15):
        med_preds, p10_preds, widths, sigmas, swithins = [], [], [], [], []
        missed = 0
        for _ in range(trials):
            obs = [math.exp(random.gauss(mu_true, SIGMA_TRUE)) for _ in range(n)]
            dev = make_device(f"t{n}", "cr2032", obs, 0)
            p = predict(dev, TODAY)
            med_preds.append(p.median_days)
            p10_preds.append(p.p10_days)
            widths.append((p.median_days - p.p10_days) / p.median_days)
            sigmas.append(p.sigma_pred)
            swithins.append(p.posterior.sigma_within)
            # 抽一颗「新电池」：若它比风险窗口起点还早阵亡 → 用户在预警前就被打脸
            new_life = math.exp(random.gauss(mu_true, SIGMA_TRUE))
            if new_life <= p.p10_days:
                missed += 1

        med = sum(med_preds) / trials
        p10 = sum(p10_preds) / trials
        w = sum(widths) / trials
        sp = sum(sigmas) / trials
        sw = sum(swithins) / trials
        neff = fit(make_device("x", "cr2032", [300.0] * n, 0), cfg).n_eff
        bias = (med - L_TRUE) / L_TRUE * 100
        miss = missed / trials * 100
        print(f"{n:>4}{neff:>9.2f}{med:>10.1f}{bias:>8.1f}%{p10:>10.1f}"
              f"{miss:>8.1f}%{w*100:>10.1f}%{sw:>10.3f}{sp:>9.4f}")
        out.append((n, med, bias, p10, miss, w, sp))

    print()
    print("判读标准：")
    print("  * 偏差%  ：|偏差| 应随样本增加收敛到 0 附近（先验刻意给偏，检验数据能否纠正它）")
    print("  * 漏报%  ：抽一颗新电池，若它比风险窗口起点还早阵亡 → 用户毫无预警就断供。")
    print("             **此值越低越安全**。高于 20% = 窗口开太晚，该响的时候没响。")
    print("  * 窗口宽度%：应单调收窄，但**不会收敛到 0** —— 那是 σ_min / σ_within 在起作用，")
    print("             是故意的：同一设备换同型号电池，寿命天然就有 15%~20% 的差异。")
    return out


if __name__ == "__main__":
    run_scenarios()
    monte_carlo()
