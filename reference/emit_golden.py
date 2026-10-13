#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
导出黄金期望值（golden values）
================================
把 lifetime_model.py 在若干「构造好的典型设备」上的输出导出为 JSON。
Swift 单元测试读取该文件并逐字段断言，确保移植后的 Swift 实现与参考实现数值一致。

⚠️ 所有日期均为**绝对日期**，不依赖"今天"。Swift 侧用同一个 UTC 日历构造。
"""
import json
import sys
from datetime import date, timedelta

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from lifetime_model import (  # noqa: E402
    DEFAULT_CONFIG, Device, ReplacementEvent, EXHAUSTED, FAULTY, INITIAL,
    PREVENTIVE, predict,
)

BASE = date(2020, 1, 1)          # 所有事件的锚点，保证两语言一致
TODAY = date(2026, 10, 14)       # 固定的"今天"


def dev(name, kind, intervals, since, types=None, **kw):
    """intervals = 相邻更换间隔；since = 最后一次更换距 TODAY 的天数。"""
    total = sum(intervals) + since
    origin = TODAY - timedelta(days=total)
    events = [ReplacementEvent(origin, INITIAL)]
    cur = origin
    ts = types or [EXHAUSTED] * len(intervals)
    for iv, t in zip(intervals, ts):
        cur += timedelta(days=iv)
        events.append(ReplacementEvent(cur, t))
    return Device(name=name, kind=kind, events=events, **kw)


CASES = {
    "coldStart":      dev("冷启动", "cr2032", [], 0),
    "oneSample":      dev("单样本", "cr2032", [300], 60),
    "twoSamples":     dev("两样本", "cr2032", [300, 280], 90),
    "threeSamples":   dev("三样本", "aa_alkaline", [300, 280, 320], 100),
    "faultyOutlier":  dev("坏电池", "cr2032", [300, 290, 310, 60, 295, 285], 120,
                          [EXHAUSTED, EXHAUSTED, EXHAUSTED, FAULTY, EXHAUSTED, EXHAUSTED]),
    "preventive":     dev("预防性更换", "cr2032", [300, 120, 290, 310], 150,
                          [EXHAUSTED, PREVENTIVE, EXHAUSTED, EXHAUSTED]),
    "agingTrend":     dev("老化趋势", "cr2032", [400, 370, 330, 300, 270], 200),
    "overdue":        dev("已逾期", "cr2032", [300, 290], 330),
    "leadDays30":     dev("提前30天提醒", "cr2450", [300, 290, 310], 200, notify_lead_days=30),
    "customLife":     dev("手填寿命", "other", [300, 290], 100, nominal_life_days=180.0),
    "refPrior":       dev("引用同型号", "cr2032", [300, 290], 100,
                          ref_prior=(5.70, 0.25)),
    "tinyIntervals":  dev("极短间隔", "aaa_alkaline", [5, 6, 4], 1),   # 边界：小数值
    "longIntervals":  dev("超长间隔", "builtin_li", [1200, 1100, 1300], 400),  # 365*3 天内
    # 紧急度分级覆盖：确认「该备货」看的是**距风险窗口**的距离，而不是距中位日
    "stockUpWindow":  dev("该备货", "cr2032", [300, 290], 170, notify_lead_days=30),
    "riskWindow":     dev("已入风险窗口", "cr2032", [300, 290], 200),
}


def main():
    out = {"today": TODAY.isoformat(), "cases": {}}
    for key, d in CASES.items():
        p = predict(d, TODAY, DEFAULT_CONFIG)
        out["cases"][key] = {
            "name": d.name,
            "kind": d.kind,
            "installedAt": d.installed_at.isoformat(),
            "notifyLeadDays": d.notify_lead_days,
            "nominalLifeDays": d.nominal_life_days,
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
            "medianDays": p.median_days,
            "p10Days": p.p10_days,
            "medianDate": p.median_date.isoformat(),
            "riskDate": p.risk_date.isoformat(),
            "remainingDays": p.remaining_days,
            "riskRemainingDays": p.risk_remaining_days,
            "ageDays": p.age_days,
            "ratio": p.ratio,
            "urgency": p.urgency,
            "confidence": p.confidence,
        }
    # 保留完整精度：json 用 repr 输出 float
    txt = json.dumps(out, indent=2, ensure_ascii=False, sort_keys=True)
    path = __file__.rsplit('/', 1)[0] + '/golden_values.json'
    with open(path, 'w', encoding='utf-8') as f:
        f.write(txt + "\n")
    print(f"wrote {path}")
    print(txt[:1200])
    print('...')


if __name__ == '__main__':
    main()
