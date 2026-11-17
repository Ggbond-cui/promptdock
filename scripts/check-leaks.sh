#!/usr/bin/env bash
# 泄露检查：密钥（gitleaks）、个人信息黑名单、禁止提交的文件类型。
#
# 用法：
#   scripts/check-leaks.sh            全量检查：所有已跟踪文件 + 全部提交历史的内容
#   scripts/check-leaks.sh --staged   只检查暂存区（pre-commit 钩子使用）
#
# 个人信息黑名单：.git/info/leak-denylist（位于 .git 内，不会被提交）。
# 每行一个扩展正则，忽略大小写，# 开头为注释。可以写姓名拼音、内部项目代号等。
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
mode="${1:-all}"
failed=0
red() { printf '\033[31m%s\033[0m\n' "$*"; }
ok() { printf '\033[32m%s\033[0m\n' "$*"; }

# ---- 1. 密钥 ----
if command -v gitleaks >/dev/null 2>&1; then
  if [[ "$mode" == "--staged" ]]; then
    gitleaks git --pre-commit --staged --no-banner --redact --log-level warn . || { red "✗ gitleaks 发现疑似密钥"; failed=1; }
  else
    gitleaks git --no-banner --redact --log-level warn . || { red "✗ gitleaks 发现疑似密钥"; failed=1; }
  fi
else
  red "✗ 未安装 gitleaks（brew install gitleaks），无法检查密钥"
  failed=1
fi

# ---- 2. 禁止提交的文件类型 ----
forbidden='\.(png|jpe?g|gif|heic|mov|mp4|sqlite3?|db|log|p12|pfx|pem|key|cer|mobileprovision|env)$|(^|/)\.env(\.|$)'
if [[ "$mode" == "--staged" ]]; then
  files=$(git diff --cached --name-only --diff-filter=ACMR)
else
  files=$(git ls-files)
fi
bad_files=$(grep -iE "$forbidden" <<<"$files" || true)
if [[ -n "$bad_files" ]]; then
  red "✗ 禁止提交的文件类型（截图、数据库、日志、证书、环境变量文件）："
  sed 's/^/    /' <<<"$bad_files"
  failed=1
fi

# ---- 3. 个人信息黑名单（只查文件内容与历史提交内容）----
denylist="$(git rev-parse --git-path info/leak-denylist)"
if [[ -s "$denylist" ]]; then
  patterns=$(grep -vE '^[[:space:]]*(#|$)' "$denylist" || true)
  if [[ -n "$patterns" ]]; then
    pattern_file=$(mktemp)
    trap 'rm -f "$pattern_file"' EXIT
    printf '%s\n' "$patterns" >"$pattern_file"

    hits=""
    if [[ "$mode" == "--staged" ]]; then
      if [[ -n "$files" ]]; then
        # shellcheck disable=SC2086
        hits=$(git grep --cached -n -I -i -E -f "$pattern_file" -- $files 2>/dev/null || true)
      fi
    else
      hits=$(git grep -n -I -i -E -f "$pattern_file" 2>/dev/null || true)
      history_hits=$(git log --all -p --format='commit %h' | grep -i -E -f "$pattern_file" | head -20 || true)
      if [[ -n "$history_hits" ]]; then
        hits+=$'\n'"[历史提交中]"$'\n'"$history_hits"
      fi
    fi

    if [[ -n "${hits//[$'\n ']/}" ]]; then
      red "✗ 内容命中个人信息黑名单："
      sed 's/^/    /' <<<"$hits"
      failed=1
    fi
  fi
else
  echo "（未配置个人信息黑名单 $denylist，跳过该项）"
fi

if [[ $failed -eq 0 ]]; then
  ok "✓ 泄露检查通过"
else
  red "泄露检查未通过。确认是误报时可用 git commit --no-verify 跳过（慎用）。"
  exit 1
fi
