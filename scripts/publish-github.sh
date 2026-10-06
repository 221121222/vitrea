#!/bin/bash
#
# publish-github.sh —— 一键把 Vitrea 发布到 GitHub
#
#   建仓 → 推送 main → 打 tag → 发 Release（挂 build/Vitrea.ipa）→ 添加协作者
#
# 用法：
#   export GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxx      # Personal Access Token，需 repo 权限
#   export GITHUB_OWNER=your-github-username      # 仓库所属账号
#   ./scripts/publish-github.sh
#
# 可选：
#   GITHUB_REPO=vitrea         仓库名（默认 vitrea）
#   RELEASE_TAG=v1.0.0         版本标签（默认取 project.yml 的 MARKETING_VERSION）
#   COLLABORATORS=ksjinhuo     协作者，逗号分隔（默认 ksjinhuo）
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${GITHUB_TOKEN:?请先 export GITHUB_TOKEN=<你的 Personal Access Token>}"
: "${GITHUB_OWNER:?请先 export GITHUB_OWNER=<你的 GitHub 用户名>}"
GITHUB_REPO="${GITHUB_REPO:-vitrea}"
COLLABORATORS="${COLLABORATORS:-ksjinhuo}"

API="https://api.github.com"
AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

# 注意：macOS 自带的是 BSD grep，不支持 \s，这里用 POSIX 字符类
VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"([^"]+)".*/\1/p' project.yml | head -1)"
[ -n "$VERSION" ] || VERSION="1.0.0"
RELEASE_TAG="${RELEASE_TAG:-v${VERSION}}"
IPA="build/Vitrea.ipa"

echo "==> 目标仓库：${GITHUB_OWNER}/${GITHUB_REPO}    版本：${RELEASE_TAG}"

# ---------------------------------------------------------------- 0. 前置检查
[ -d .git ] || { echo "错误：当前目录不是 git 仓库，请先 git init 并提交。"; exit 1; }
[ -f "$IPA" ] || { echo "错误：找不到 $IPA，请先执行 ./build-ipa.sh Release"; exit 1; }

# ---------------------------------------------------------------- 1. 建仓
echo "==> 1/6 创建仓库（已存在则跳过）"
HTTP="$(curl -sS -o /tmp/vitrea_repo.json -w '%{http_code}' -X POST "$API/user/repos" "${AUTH[@]}" \
  -d "{\"name\":\"${GITHUB_REPO}\",\"description\":\"Vitrea — Apple Wallet 卡面工坊，在 iPhone 上直接为 Apple Wallet 卡片换上自定义卡面，无需越狱。\",\"homepage\":\"https://cardart.cc\",\"private\":false,\"has_issues\":true,\"has_wiki\":false,\"has_projects\":false}")"
case "$HTTP" in
  201) echo "    已创建 ${GITHUB_OWNER}/${GITHUB_REPO}" ;;
  422) echo "    仓库已存在，继续" ;;
  401) echo "    错误：Token 无效或权限不足（401）"; exit 1 ;;
  *)   echo "    建仓返回 HTTP $HTTP"; cat /tmp/vitrea_repo.json; exit 1 ;;
esac

# ---------------------------------------------------------------- 2. 推送
echo "==> 2/6 推送 main 分支"
git remote remove origin 2>/dev/null || true
git remote add origin "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git"
# token 只出现在本次 push 的 URL 中，不写入 .git/config
git push "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git" main --force

# ---------------------------------------------------------------- 3. 打 tag
echo "==> 3/6 打标签 ${RELEASE_TAG}"
git tag -f -a "$RELEASE_TAG" -m "Vitrea ${RELEASE_TAG}"
git push "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git" "$RELEASE_TAG" --force

# ---------------------------------------------------------------- 4. 发 Release
echo "==> 4/6 创建 Release 并上传 IPA"
# 已存在同名 release 时先删除，保证可重复执行
OLD_ID="$(curl -sS "$API/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tags/${RELEASE_TAG}" "${AUTH[@]}" \
  | sed -n 's/.*"id": *\([0-9]*\).*/\1/p' | head -1)"
[ -n "${OLD_ID:-}" ] && curl -sS -X DELETE "$API/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/${OLD_ID}" "${AUTH[@]}" >/dev/null || true

RELEASE_ID="$(curl -sS -X POST "$API/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases" "${AUTH[@]}" \
  -d "$(printf '{"tag_name":"%s","name":"Vitrea %s","body":%s,"draft":false,"prerelease":false}' \
        "$RELEASE_TAG" "$RELEASE_TAG" "$(python3 -c 'import json,sys;print(json.dumps(open("RELEASE_NOTES.md").read()))')")" \
  | sed -n 's/.*"id": *\([0-9]*\).*/\1/p' | head -1)"
[ -n "$RELEASE_ID" ] || { echo "    Release 创建失败"; exit 1; }

curl -sS -X POST \
  "https://uploads.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/${RELEASE_ID}/assets?name=Vitrea.ipa" \
  "${AUTH[@]}" -H "Content-Type: application/octet-stream" --data-binary @"$IPA" >/dev/null
echo "    已上传 Vitrea.ipa ($(du -h "$IPA" | cut -f1))"

# ---------------------------------------------------------------- 5. 协作者
echo "==> 5/6 添加协作者"
IFS=',' read -ra NAMES <<< "$COLLABORATORS"
for name in "${NAMES[@]}"; do
  name="$(echo "$name" | tr -d ' ')"
  [ -z "$name" ] && continue
  HTTP="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
    "$API/repos/${GITHUB_OWNER}/${GITHUB_REPO}/collaborators/${name}" "${AUTH[@]}" \
    -d '{"permission":"push"}')"
  case "$HTTP" in
    201) echo "    已邀请 ${name}（等待对方接受）" ;;
    204) echo "    ${name} 已是协作者" ;;
    *)   echo "    邀请 ${name} 返回 HTTP $HTTP（可能账号名有误）" ;;
  esac
done

# ---------------------------------------------------------------- 6. 完成
echo "==> 6/6 完成"
echo "    仓库：https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
echo "    发布：https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${RELEASE_TAG}"
