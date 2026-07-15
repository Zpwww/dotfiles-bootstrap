#!/bin/bash
# ==============================================================================
# Create bootstrap.vault.age for public bootstrap repo.
# Run on trusted Mac only. Never commit bootstrap.vault.env.
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_FILE="$ROOT_DIR/bootstrap.vault.age"
TMP_ENV="$(mktemp)"
cleanup() { rm -f "$TMP_ENV"; }
trap cleanup EXIT

AGE_KEY_PATH="${AGE_KEY_PATH:-$HOME/.config/chezmoi/key.txt}"
DOTFILES_SLUG="${DOTFILES_SLUG:-Zpwww/dotfiles}"
GITHUB_USERNAME="${GITHUB_USERNAME:-Zpwww}"

encode_b64() {
  base64 | tr -d '\n'
}

if ! command -v age >/dev/null 2>&1; then
  echo "缺少 age：brew install age"
  exit 1
fi

if [[ ! -f "$AGE_KEY_PATH" ]]; then
  echo "找不到 age 私钥：$AGE_KEY_PATH"
  echo "如果还没生成：age-keygen -o ~/.config/chezmoi/key.txt"
  exit 1
fi

echo "将读取 age 私钥：$AGE_KEY_PATH"
echo "将生成加密 vault：$OUT_FILE"
echo ""
echo "读取 GitHub fine-grained token："
echo "  - Repository access: only $DOTFILES_SLUG"
echo "  - Permissions: Contents = Read-only"
GITHUB_TOKEN=""
if command -v security >/dev/null 2>&1; then
  GITHUB_TOKEN="$(security find-generic-password -a "$GITHUB_USERNAME" -s "dotfiles-bootstrap-github-token" -w 2>/dev/null || true)"
fi
if [[ -n "$GITHUB_TOKEN" ]]; then
  echo "  -> 已从 macOS Keychain 读取 service=dotfiles-bootstrap-github-token"
else
  printf "Token: "
  read -s -r GITHUB_TOKEN </dev/tty
  echo ""
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "Token 为空，退出。"
  exit 1
fi

echo ""
printf "代理订阅 URL（可选，回车跳过）："
read -r PROXY_SUBSCRIPTION_URL </dev/tty || PROXY_SUBSCRIPTION_URL=""

AGE_IDENTITY_B64="$(encode_b64 < "$AGE_KEY_PATH")"

cat > "$TMP_ENV" <<EOF
# bootstrap vault env. Decrypted locally by bootstrap.sh.
DOTFILES_SLUG="$DOTFILES_SLUG"
GITHUB_USERNAME="$GITHUB_USERNAME"
GITHUB_TOKEN="$GITHUB_TOKEN"
AGE_IDENTITY_B64="$AGE_IDENTITY_B64"
PROXY_SUBSCRIPTION_URL="$PROXY_SUBSCRIPTION_URL"
EOF

unset GITHUB_TOKEN AGE_IDENTITY_B64 PROXY_SUBSCRIPTION_URL

echo ""
echo "现在输入 vault 密码。"
echo "注意：不要用弱密码。公开 vault 里包含 token 和 age 私钥，弱密码等于裸奔。"
echo "如果只是临时测试，测试完请立即换强密码并重新生成 vault。"
age -p -o "$OUT_FILE" "$TMP_ENV"
chmod 600 "$OUT_FILE"

echo ""
echo "已生成：$OUT_FILE"
echo "下一步：把 bootstrap_public/ 作为 public repo Zpwww/dotfiles-bootstrap 推到 GitHub。"
