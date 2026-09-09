#!/usr/bin/env bash
# サムネイルPNGを生成する
#
# 使い方:
#   ./scripts/generate-thumbnail.sh "<記事タイトル>" "<出力先パス>" ["<タグテキスト>"]
#
# 例:
#   ./scripts/generate-thumbnail.sh "Claude Code Hooks入門" "./images/20260428-hooks_thumbnail.png"
#   ./scripts/generate-thumbnail.sh "Claude Code Hooks入門" "./images/20260428-hooks_thumbnail.png" "Claude Code × やってみた"
#
# 前提:
#   - リポジトリルートで実行 (templates/thumbnail.html を参照)
#   - puppeteer がインストール済み (npm ci 後の node_modules)

set -euo pipefail

ARTICLE_TITLE="${1:-}"
OUTPUT_PATH="${2:-}"
TAG_TEXT="${3:-Claude Code × やってみた}"

if [[ -z "${ARTICLE_TITLE}" || -z "${OUTPUT_PATH}" ]]; then
  echo "❌ 引数が足りません" >&2
  echo "使い方: $0 <記事タイトル> <出力パス> [タグテキスト]" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${REPO_ROOT}/templates/thumbnail.html"

if [[ ! -f "${TEMPLATE}" ]]; then
  echo "❌ テンプレが見つかりません: ${TEMPLATE}" >&2
  exit 1
fi

# 一時HTMLを作成 (タイトルとタグを差し込み)
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
TMP_HTML="${TMP_DIR}/thumbnail.html"

# sed特殊文字をエスケープして安全に置換
ESCAPED_TITLE=$(printf '%s' "${ARTICLE_TITLE}" | sed -e 's/[\/&]/\\&/g')
ESCAPED_TAG=$(printf '%s' "${TAG_TEXT}" | sed -e 's/[\/&]/\\&/g')

sed -e "s/{{ARTICLE_TITLE}}/${ESCAPED_TITLE}/g" \
    -e "s/{{TAG_TEXT}}/${ESCAPED_TAG}/g" \
    "${TEMPLATE}" > "${TMP_HTML}"

# 出力ディレクトリ作成
mkdir -p "$(dirname "${OUTPUT_PATH}")"

# Puppeteerで撮影
node -e "
const puppeteer = require('puppeteer');
(async () => {
  const browser = await puppeteer.launch({
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--single-process']
  });
  try {
    const page = await browser.newPage();
    await page.setViewport({ width: 1200, height: 630, deviceScaleFactor: 1 });
    await page.goto('file://${TMP_HTML}', { waitUntil: 'networkidle0' });
    await page.screenshot({
      path: '${OUTPUT_PATH}',
      clip: { x: 0, y: 0, width: 1200, height: 630 }
    });
  } finally {
    await browser.close();
  }
})().catch(e => { console.error(e); process.exit(1); });
"

if [[ -f "${OUTPUT_PATH}" ]]; then
  SIZE=$(wc -c < "${OUTPUT_PATH}" | tr -d ' ')
  echo "✅ サムネイル生成: ${OUTPUT_PATH} (${SIZE} bytes)"
else
  echo "❌ サムネイル生成失敗" >&2
  exit 1
fi
