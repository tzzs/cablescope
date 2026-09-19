#!/usr/bin/env bash
# 强制 AGENTS.md 的分层规则：只有 Sources/CableKit 允许直接触碰 IOKit /
# CoreGraphics / system_profiler 等系统接口；CLI、App、Widget 只能消费
# CableKit 导出的值类型。此前这条规则只靠人工 review 记忆，这里把它变成
# CI 能强制执行的检查。
set -euo pipefail

cd "$(dirname "$0")/.."

# CableScopeWidget 是 Xcode-only target（不在 Package.swift），但源码仍在仓库里，
# 同样受分层规则约束。
CHECK_DIRS=(Sources/CableScopeCLI Sources/CableScopeApp Sources/CableScopeWidget)

violations=0

check_pattern() {
    local pattern="$1"
    local description="$2"
    local hits
    hits=$(grep -rnE "$pattern" "${CHECK_DIRS[@]}" --include="*.swift" 2>/dev/null || true)
    if [ -n "$hits" ]; then
        echo "违反分层规则：$description"
        echo "$hits"
        echo ""
        violations=$((violations + 1))
    fi
}

check_pattern '^\s*(@_implementationOnly[[:space:]]+)?import[[:space:]]+(IOKit|CoreGraphics)([[:space:].]|$)' \
    "CableKit 之外直接 import IOKit / CoreGraphics"
check_pattern '\bsystem_profiler\b' \
    "CableKit 之外直接调用 system_profiler"
check_pattern '\bProcess\(\)' \
    "CableKit 之外直接创建 Process()"

if [ "$violations" -gt 0 ]; then
    echo "以上访问必须封装进 Sources/CableKit 的 Service（见 AGENTS.md「架构：分层规则」）。"
    exit 1
fi

echo "分层检查通过：CableKit 之外没有直接的系统访问。"
