#!/usr/bin/env bash
#
# 打印 App / 扩展的 bundle id 及其前缀关系，以 ::notice:: 注解抛出。
#
# 为什么需要：构建失败在「嵌入二进制校验」时，报的是
#   "Embedded binary's bundle identifier is not prefixed with the parent app's bundle identifier."
# 这条错误本身不告诉你是哪个 id 不对。这个脚本把**实际解析出来的**值打出来
# （用 -showBuildSettings，不触发完整构建），一眼就能看出是配置错还是 plist 缺键。
#
# 用法: dump-bundle-ids.sh
set -uo pipefail

project="CheckJuice.xcodeproj"

resolve() {
  xcodebuild -project "$project" -target "$1" -showBuildSettings 2>/dev/null \
    | sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER = //p' | head -1
}

app=$(resolve CheckJuice)
widget=$(resolve CheckJuiceWidget)

echo "::notice::主 App  bundle id = '${app:-（解析失败）}'"
echo "::notice::扩展    bundle id = '${widget:-（解析失败）}'"

# 同时把 plist 里解析后的 CFBundleIdentifier 打出来（证明 plist 有没有缺键）
for plist in CheckJuiceWidget/Info.plist; do
  if [ -f "$plist" ]; then
    if grep -q 'CFBundleIdentifier' "$plist"; then
      echo "::notice::$plist 含 CFBundleIdentifier 键 ✅"
    else
      echo "::error::$plist 缺少 CFBundleIdentifier 键 —— 嵌入校验会读到空值"
    fi
  fi
done

if [ -n "$app" ] && [ -n "$widget" ]; then
  case "$widget" in
    "$app".*) echo "::notice::前缀关系 OK：'$widget' 以 '$app.' 开头 ✅" ;;
    *)        echo "::error::前缀关系错误：'$widget' 不是 '$app.' 开头" ;;
  esac
fi
