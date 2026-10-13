#!/usr/bin/env bash
#
# 把构建/测试日志里的错误行转成 GitHub 注解（annotation）。
#
# ── 为什么需要这个 ────────────────────────────────────────────────
# GitHub 现在要求**登录**才能看 Actions 的原始日志，页面直接显示
# "Sign in to view logs"。而本项目是在没有 Mac 的手机上开发，
# 靠 CI 当编译器 —— 读不到日志就等于瞎了。
#
# 而**注解是免登录可见的**，会以明文嵌在运行页的 HTML 里。
# 所以把错误行用 ::error:: 抛出来，就能在无账号的情况下读到真正的编译错误。
#
# ── 用法 ─────────────────────────────────────────────────────────
#   report-errors.sh <日志文件> [匹配正则]
#
# ── 注意 ─────────────────────────────────────────────────────────
# * GitHub 每个 step 只展示前 10 条注解，所以这里把所有错误**合并成一条**，
#   这样能把更多内容带出来。
# * 本脚本永远退出 0 —— 它的职责是"报告"，不是"判定成败"。
#   判断成败由调用方根据原命令的退出码决定。
set -uo pipefail

log="${1:?用法: report-errors.sh <日志文件> [匹配正则]}"
pattern="${2:-error:}"

if [ ! -f "$log" ]; then
  echo "::error::报告脚本找不到日志文件：$log"
  exit 0
fi

matched=$(sed -n "/$pattern/p" "$log" | sed 's/^[[:space:]]*//' | sort -u | head -40)
total=$(sed -n "/$pattern/p" "$log" | wc -l | tr -d ' ')

if [ -z "$matched" ]; then
  # 匹配不到错误行（链接器报错、脚本自身出错等），退而求其次给日志尾部。
  # 注意：多行都得各自带 ::error:: 前缀才会被识别。
  echo "::error::构建失败，但未匹配到 '$pattern'。以下为日志尾部 $(( $(wc -l < "$log") )) 行中的最后 30 行："
  tail -30 "$log" | sed 's/^/::error::/'
  exit 0
fi

# GitHub 注解转义规则：'%' -> '%25'，换行 -> '%0A'。
# 先转义 %，再把换行替换成 %0A（用 awk 逐行拼接，避免 $'...' 的兼容问题）。
escaped=$(printf '%s\n' "$matched" | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')

echo "::error::构建失败：日志中共 $total 行匹配 '$pattern'，去重后前 40 行如下%0A$escaped"
