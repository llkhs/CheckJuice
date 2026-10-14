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
    PREVENTIVE, audit_intervals, predict, format_remaining_short,
)

D = 24.0                              # 一天多少小时，仅为让下面的场景定义保持可读
TODAY = datetime(2026, 10, 14, 12, 0)  # 固定的「现在」


def dev(name, nominal_life_hours, intervals_h, since_h, types=None, **kw):
    """intervals_h = 相邻更换间隔（小时）；since_h = 最后一次更换距 TODAY 的小时数。"""
    total = sum(intervals_h) + since_h
    origin = TODAY - timedelta(hours=total)
    events = [ReplacementEvent(origin, INITIAL)]
    cur = origin
    ts = types or [EXHAUSTED] * len(intervals_h)
    for iv, t in zip(intervals_h, ts):
        cur += timedelta(hours=iv)
        events.append(ReplacementEvent(cur, t))
    return Device(name=name, nominal_life_hours=nominal_life_hours, events=events, **kw)


CASES = {
    "coldStart":      dev("冷启动", 8760.0, [], 0),
    "oneSample":      dev("单样本", 8760.0, [300*D], 60*D),
    "twoSamples":     dev("两样本", 8760.0, [300*D, 280*D], 90*D),
    "threeSamples":   dev("三样本", 4320.0, [300*D, 280*D, 320*D], 100*D),
    "faultyOutlier":  dev("坏电池", 8760.0, [300*D, 290*D, 310*D, 60*D, 295*D, 285*D], 120*D,
                          [EXHAUSTED, EXHAUSTED, EXHAUSTED, FAULTY, EXHAUSTED, EXHAUSTED]),
    "preventive":     dev("预防性更换", 8760.0, [300*D, 120*D, 290*D, 310*D], 150*D,
                          [EXHAUSTED, PREVENTIVE, EXHAUSTED, EXHAUSTED]),
    "agingTrend":     dev("老化趋势", 8760.0, [400*D, 370*D, 330*D, 300*D, 270*D], 200*D),
    "overdue":        dev("耗尽中", 8760.0, [300*D, 290*D], 330*D),
    "lead30d":        dev("提前30天提醒", 17520.0, [300*D, 290*D, 310*D], 200*D,
                          notify_lead_hours=30*D),
    "customLife":     dev("手填寿命", 8760.0, [300*D, 290*D], 100*D),
    # ⚠️ 陷阱：ref_prior 的 m 是 **log 尺度**的中位数。
    #    换单位时它要 **+log(24)**，不是 ×24 —— 对数尺度上是加法。
    #    （真实代码里这个值来自另一台设备的 posterior.m，那台也换成小时后自动一致；
    #      这里的硬编码值必须手写对，否则黄金数值会把 Swift 也带进沟里。）
    "refPrior":       dev("引用同型号", 8760.0, [300*D, 290*D], 100*D,
                          ref_prior=(math.log(300*D), 0.25)),
    "tinyIntervals":  dev("极短间隔", 2880.0, [5*D, 6*D, 4*D], 1*D),   # 边界：小数值
    "longIntervals":  dev("超长间隔", 26280.0, [1200*D, 1100*D, 1300*D], 400*D),
    # 紧急度分级覆盖：确认「该备货」看的是**距风险窗口**的距离，而不是距中位时刻
    "stockUpWindow":  dev("该备货", 8760.0, [300*D, 290*D], 170*D, notify_lead_hours=30*D),
    "riskWindow":     dev("已入风险窗口", 8760.0, [300*D, 290*D], 200*D),
    # ── 间隔护栏 ────────────────────────────────────────────────────────
    # 真实事故：用户填 100 天，添加后 2 分钟点「自然耗尽」，模型把这 2 分钟
    # 当成真实寿命观测，中位寿命从 100 天塌到 39 分钟。这两条用例把它钉死。
    "misTap":         dev("误触两分钟", 2400.0, [2/60.0], 0.5),
    # 4 小时电池：下限放宽到 24 分钟，所以 18 分钟那段【不】算（低于下限），
    # 而 3 小时那段算 —— 证明自适应下限没有误杀真实的短周期。
    "tinyBattery":    dev("四小时电池", 4.0, [0.3, 3.0], 0.5),
}


def main():
    out = {"today": TODAY.isoformat(), "cases": {}}
    for key, d in CASES.items():
        p = predict(d, TODAY, DEFAULT_CONFIG)
        out["cases"][key] = {
            "name": d.name,
            "nominalLifeHours": d.nominal_life_hours,
            "installedAt": d.installed_at.isoformat(),
            "notifyLeadHours": d.notify_lead_hours,
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
            # 每一段间隔的判定结果：进了统计没有、为什么。
            # Swift 的 auditIntervals 必须逐条对上，否则界面会给错误的记录打标。
            "intervals": [
                {
                    "hours": a.hours,
                    "type": a.type,
                    "reason": a.reason,
                    "floorHours": a.floor_hours,
                }
                for a in audit_intervals(d, DEFAULT_CONFIG)
            ],
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
