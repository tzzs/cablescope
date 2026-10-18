#!/usr/bin/env bash
# 检查一次 push 引入的每个提交是否符合 Conventional Commits（<type>(<scope>): <描述>）。
#
# 为什么需要这个检查：本仓库用 merge commit 合 PR，release-please 会拿「被合并 PR 的
# 标题」当作提交主题去解析。标题不符合格式时，release-please 把那批提交整条丢弃
# （日志 "commit could not be parsed" → "Considering: 0 commits"），然后什么都不做、
# job 照样报 success —— release PR 永远不会生成，且没有任何报警（v0.6.0 实际踩过：
# PR #20 标题非 conventional，release PR 未生成，靠人工发现）。
#
# 用法：check_conventional_commits.sh <before-sha> <after-sha> <owner/repo>
#   before-sha 为全零（新分支）或不存在（强推）时，只检查 after 头部一个提交。
#   GH_TOKEN 需已设置：merge commit 要调用 GitHub API 读取被合并 PR 的标题。
#
# type 只要求是任意单词（如 design），不锁死 AGENTS.md 的类型表：release-please 对
# 可解析的 type 一律能处理（未知类型只是不进 changelog），守卫只拦「完全解析不了」
# 的提交，避免比底层工具更严导致误伤。
set -euo pipefail

before="${1:-0000000000000000000000000000000000000000}"
after="${2:?缺少 after sha}"
repo="${3:?缺少 owner/repo}"

log_args=(--format="%H %P")
if [[ "$before" != "0000000000000000000000000000000000000000" ]] &&
   git rev-parse --verify -q "$before" >/dev/null 2>&1; then
  log_args+=("$before..$after")
else
  log_args+=(-1 "$after")
fi

pattern='^[a-zA-Z]+(\([^)]+\))?!?: .+'
bad=0
while read -r sha parents; do
  subject=$(git log -1 --format=%s "$sha")
  if [[ $(wc -w <<< "$parents") -gt 1 ]]; then
    # merge commit：用被合并 PR 的标题检查（合并提交自身主题永远是 "Merge pull request ..."）
    if [[ "$subject" =~ Merge\ pull\ request\ \#([0-9]+) ]]; then
      subject=$(gh api "repos/$repo/pulls/${BASH_REMATCH[1]}" --jq .title)
    fi
  fi
  if ! [[ "$subject" =~ $pattern ]]; then
    printf '::error::提交 %s（「%s」）不是 Conventional Commits 格式。release-please 会静默丢弃它，release PR 不会生成。恢复方式：把 PR 标题改成 <type>(<scope>): <描述> 后重合并，或追加一个 conventional 格式的空提交（git commit --allow-empty）推送。规范见 AGENTS.md「Commit messages」。\n' "${sha:0:7}" "$subject"
    bad=1
  fi
done < <(git log "${log_args[@]}")
exit "$bad"
