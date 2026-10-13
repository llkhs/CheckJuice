#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
导出黄金期望值（golden values）
================================
把 lifetime_model.py 在若干「构造好的典型设备」上的输出导出为 JSON。
Swift 单元测试读取该文件并逐字段断言，确保移植后的 Swift 实现与参考实现数值一致。

⚠️ 所有时刻都是**绝对 naive datetime**，不依赖"今天"。
   Swift 侧必须用 **UTC 日历** 构造同一时刻，否则时区差会让数值对不上。
⚠️ 时间单位一律**小时**。
"""
import json
import math
import sys
from datetime import datetime, timedelta

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from lifetime_model import (  # noqa: E402
    DEFAULT_CONFIG, Device, ReplacementEvent, EXHAUSTED, FAULTY, INITIAL,
    PREVENTIVE, predict, format_remaining_short,
)

D = 24.0                              # 一天多少小时，仅为让下面的场景定义保持可读
TODAY = datetime(2026, 10, 14, 12, 0)  # 固定的「现在」


def dev(name, kind, intervals_h, since_h, types=None, **kw):
    """intervals_h = 相邻更换间隔（小时）；since_h = 最后一次更换距 TODAY 的小时数。"""
    total = sum(intervals_h) + since_h
    origin = TODAY - timedelta(hours=total)
    events = [ReplacementEvent(origin, INITIAL)]
    cur = origin
    ts = types or [EXHAUSTED] * len(intervals_h)
    for iv, t in zip(intervals_h, ts):
        cur += timedelta(hours=iv)
        events.append(ReplacementEvent(cur, t))
    return Device(name=name, kind=kind, events=events, **kw)


CASES = {
    "coldStart":      dev("冷启动", "cr2032", [], 0),
    "oneSample":      dev("单样本", "cr2032", [300*D], 60*D),
    "twoSamples":     dev("两样本", "cr2032", [300*D, 280*D], 90*D),
    "threeSamples":   dev("三样本", "aa_alkaline", [300*D, 280*D, 320*D], 100*D),
    "faultyOutlier":  dev("坏电池", "cr2032", [300*D, 290*D, 310*D, 60*D, 295*D, 285*D], 120*D,
                          [EXHAUSTED, EXHAUSTED, EXHAUSTED, FAULTY, EXHAUSTED, EXHAUSTED]),
    "preventive":     dev("预防性更换", "cr2032", [300*D, 120*D, 290*D, 310*D], 150*D,
                          [EXHAUSTED, PREVENTIVE, EXHAUSTED, EXHAUSTED]),
    "agingTrend":     dev("老化趋势", "cr2032", [400*D, 370*D, 330*D, 300*D, 270*D], 200*D),
    "overdue":        dev("耗尽中", "cr2032", [300*D, 290*D], 330*D),
    "lead30d":        dev("提前30天提醒", "cr2450", [300*D, 290*D, 310*D], 200*D,
                          notify_lead_hours=30*D),
    "customLife":     dev("手填寿命", "other", [300*D, 290*D], 100*D,
                          nominal_life_hours=180*D),
    # ⚠️ 陷阱：ref_prior 的 m 是 **log 尺度**的中位数。
    #    换单位时它要 **+log(24)**，不是 ×24 —— 对数尺度上是加法。
    #    （真实代码里这个值来自另一台设备的 posterior.m，那台也换成小时后自动一致；
    #      这里的硬编码值必须手写对，否则黄金数值会把 Swift 也带进沟里。）
    "refPrior":       dev("引用同型号", "cr2032", [300*D, 290*D], 100*D,
                          ref_prior=(math.log(300*D), 0.25)),
    "tinyIntervals":  dev("极短间隔", "aaa_alkaline", [5*D, 6*D, 4*D], 1*D),   # 边界：小数值
    "longIntervals":  dev("超长间隔", "builtin_li", [1200*D, 1100*D, 1300*D], 400*D),
    # 紧急度分级覆盖：确认「该备货」看的是**距风险窗口**的距离，而不是距中位时刻
    "stockUpWindow":  dev("该备货", "cr2032", [300*D, 290*D], 170*D, notify_lead_hours=30*D),
    "riskWindow":     dev("已入风险窗口", "cr2032", [300*D, 290*D], 200*D),
}


def main():
    out = {"today": TODAY.isoformat(), "cases": {}}
    for key, d in CASES.items():
        p = predict(d, TODAY, DEFAULT_CONFIG)
        out["cases"][key] = {
            "name": d.name,
            "kind": d.kind,
            "installedAt": d.installed_at.isoformat(),
            "notifyLeadHours": d.notify_lead_hours,
            "nominalLifeHours": d.nominal_life_hours,
            "referencePrior": ({"logMedian": d.ref_prior[0], "tau": d.ref_prior[1]}
                               if d.ref_prior else None),
            "events": [{"at": e.at.isoformat(), "type": e.type} for e in
                       sorted(d.events, key=lambda x: x.at)],
            "nObserved": p.posterior.n_observed,
            "nEff": p.posterior.n_eff,
            "m": p.posterior.m,
            "sigmaPost": p.posterior.sigma,
            "sigmaWithin": p.posterior.sigma_within,
            "sigmaPred": p.sigma_pred,
            "medianHours": p.median_hours,
            "p10Hours": p.p10_hours,
            "p50ExhaustAt": p.p50_exhaust_at.isoformat(),
            "p10ExhaustAt": p.p10_exhaust_at.isoformat(),
            "remainingHours": p.remaining_hours,
            "p10RemainingHours": p.p10_remaining_hours,
            "ageHours": p.age_hours,
            "ratio": p.ratio,
            "urgency": p.urgency,
            "confidence": p.confidence,
            # 主文案 = P10（最坏情况），副行 = 中位。两行都是**显示层**产物，
            # 放进黄金文件是为了让「跨语言格式漂移」也被 CI 抓住 ——
            # 取整方向差一个单位、单位阈值差一格，这里就会红。
            "headlineRemaining": format_remaining_short(p.p10_remaining_hours),
            "medianLineRemaining": "中位 · " + format_remaining_short(p.remaining_hours),
        }
    # 保留完整精度：json 用 repr 输出 float
    txt = json.dumps(out, indent=2, ensure_ascii=False, sort_keys=True)
    path = __file__.rsplit('/', 1)[0] + '/golden_values.json'
    with open(path, 'w', encoding='utf-8') as f:
        f.write(txt + "\n")
    # 日志走 stderr：stdout 要留给 JSON 本身（`emit_golden.py > x.json` 得干净）
    print(f"wrote {path}", file=sys.stderr)


if __name__ == '__main__':
    main()
