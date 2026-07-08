#!/bin/bash
# ==============================================================================
# Public bootstrap entry for Zpwww/dotfiles
# Path: public repo Zpwww/dotfiles-bootstrap/bootstrap.sh
# User path: paste one command, enter vault password, then answer chezmoi choices.
# ==============================================================================

set -euo pipefail

DOTFILES_SLUG="${DOTFILES_SLUG:-Zpwww/dotfiles}"
GITHUB_USERNAME="${GITHUB_USERNAME:-Zpwww}"
BOOTSTRAP_RAW_BASE="${BOOTSTRAP_RAW_BASE:-https://raw.githubusercontent.com/Zpwww/dotfiles-bootstrap/main}"
VAULT_URL="${VAULT_URL:-https://gh-proxy.com/${BOOTSTRAP_RAW_BASE}/bootstrap.vault.age}"

export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.ustc.edu.cn/brew.git"
export HOMEBREW_CORE_GIT_REMOTE="https://mirrors.ustc.edu.cn/homebrew-core.git"
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

log() { echo "[$(date +%H:%M:%S)] $*"; }

preflight_admin() {
  # 最优先检查：安装 Homebrew / App / 改系统设置都需要管理员。
  # 普通用户没有 sudo 权限，脚本再聪明也装不了 Homebrew，所以第一步就拦住，
  # 绝不让用户白等 CLT 安装几分钟后才在中途失败。
  if id -Gn "$(whoami)" | tr ' ' '\n' | grep -qx "admin"; then
    return
  fi
  local me; me="$(whoami)"
  echo ""
  echo "===================================================="
  echo "⛔ 装机前置检查：当前用户「$me」不是管理员，无法继续"
  echo "===================================================="
  echo "安装 Homebrew / 应用 / 系统设置都需要管理员权限，这是 macOS 的硬性要求。"
  echo "请用下面任一方式授权后，回来重新运行同一行命令即可（会跳过已完成步骤）："
  echo ""
  echo "【方式 A · 图形界面，推荐】"
  echo "  1. 系统设置 → 用户与群组"
  echo "  2. 点「$me」旁边的 ⓘ"
  echo "  3. 打开「允许此用户管理这台电脑」"
  echo "  4. 注销并重新登录（让权限生效）"
  echo ""
  echo "【方式 B · 一条命令】"
  echo "  用另一个「管理员账号」登录（或在其终端里）执行："
  echo "      sudo dseditgroup -o edit -a $me -t user admin"
  echo "  然后回到「$me」账号，重新运行本装机命令。"
  echo ""
  echo "授权完成后，重新粘贴运行那一行命令即可。"
  echo "===================================================="
  exit 1
}

ensure_clt() {
  log "检测 Xcode Command Line Tools..."
  if xcode-select -p >/dev/null 2>&1; then
    log "CLT 已就绪。"
    return
  fi
  log "触发 CLT 安装窗口（这是苹果弹的系统窗口）：请点【安装】，等它下载完成（约几分钟）。"
  xcode-select --install 2>/dev/null || true
  until xcode-select -p >/dev/null 2>&1; do
    printf "\r\033[K⏳ 正在等待 CLT 安装完成（在弹窗里点了【安装】后耐心等）..."
    sleep 5
  done
  printf "\r\033[K"
  log "CLT 安装完成。"
}

ensure_sudo() {
  echo ""
  echo "----------------------------------------------------"
  echo "🔑 需要授权：请输入【这台 Mac 的开机/登录密码】"
  echo "   （就是你每天开机、解锁这台电脑用的那个密码；不是 vault 密码）"
  echo "   输入时屏幕不显示任何字符，这是正常的，输完按回车即可。"
  echo "----------------------------------------------------"
  if ! sudo -v; then
    echo ""
    echo "sudo 授权失败，无法继续安装 Homebrew。请确认输入的是本机开机密码。"
    exit 1
  fi
}

ensure_brew() {
  log "检测 Homebrew..."
  if ! command -v brew >/dev/null 2>&1; then
    ensure_sudo
    log "通过中科大镜像安装 Homebrew。"
    /bin/bash -c "$(curl -fsSL https://mirrors.ustc.edu.cn/misc/brew-install.sh)"
  fi
  if [[ "$(uname -m)" == "arm64" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  log "Homebrew 已就绪。"
}

ensure_tools() {
  log "安装/确认 age、git、chezmoi、gh..."
  for pkg in age git chezmoi gh; do
    if brew list "$pkg" >/dev/null 2>&1; then
      log "$pkg 已安装。"
    else
      brew install "$pkg"
    fi
  done
}

decode_b64() {
  # macOS base64 supports -D, GNU supports -d.
  if base64 -D >/dev/null 2>&1 <<<""; then
    base64 -D
  else
    base64 -d
  fi
}

download_and_decrypt_vault() {
  local vault_file="$TMP_DIR/bootstrap.vault.age"
  local env_file="$TMP_DIR/bootstrap.vault.env"

  log "下载加密 vault：$VAULT_URL"
  if ! curl -fsSL "$VAULT_URL" -o "$vault_file"; then
    echo ""
    echo "无法下载 bootstrap.vault.age。"
    echo "请确认 public 仓 Zpwww/dotfiles-bootstrap 已创建，并已上传 bootstrap.vault.age。"
    exit 1
  fi

  echo ""
  echo "----------------------------------------------------"
  echo "🔐 需要输入：【vault 装机密码】（不是这台电脑的开机密码！）"
  echo "   这是你之前专门为装机设定的那个密码，用来解开加密的密钥包。"
  echo "   下面会出现一行英文 “Enter passphrase:”，那就是让你输这个密码。"
  echo "   输入时屏幕不显示任何字符，这是正常的，输完按回车。"
  echo "----------------------------------------------------"
  if ! age -d "$vault_file" > "$env_file"; then
    echo ""
    echo "vault 解密失败：密码不对，或 vault 文件损坏。"
    echo "提示：这里要输的是【vault 装机密码】，不是电脑开机密码。可重新运行本命令再试。"
    exit 1
  fi

  # shellcheck disable=SC1090
  set -a
  source "$env_file"
  set +a

  log "vault 已解密。"
}

install_age_identity() {
  if [[ -n "${AGE_IDENTITY_B64:-}" ]]; then
    mkdir -p "$HOME/.config/chezmoi"
    printf "%s" "$AGE_IDENTITY_B64" | decode_b64 > "$HOME/.config/chezmoi/key.txt"
    chmod 600 "$HOME/.config/chezmoi/key.txt"
    log "已恢复 age 私钥到 ~/.config/chezmoi/key.txt。"
  else
    log "vault 中未包含 AGE_IDENTITY_B64，将跳过 SSH 配置解密。"
  fi
}

install_github_token() {
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo ""
    echo "vault 中没有 GITHUB_TOKEN。请输入 GitHub fine-grained token（repo: $DOTFILES_SLUG，Contents Read-only）。"
    echo "如果不想输入，按 Ctrl+C 退出。"
    printf "Token: "
    read -s -r GITHUB_TOKEN </dev/tty
    echo ""
  fi

  git config --global credential.helper osxkeychain
  printf "protocol=https\nhost=github.com\nusername=%s\npassword=%s\n\n" "$GITHUB_USERNAME" "$GITHUB_TOKEN" | git credential approve
  unset GITHUB_TOKEN
  log "GitHub 凭证已写入 macOS 钥匙串。"
}

run_chezmoi() {
  local repo="https://github.com/${DOTFILES_SLUG}.git"
  log "拉取并应用私有 dotfiles：$repo"
  echo ""
  echo "接下来会出现几个中文选择题（很快，只问一次并记住）："
  echo "  1) 机器角色：输数字 1=移动机Air / 2=Mac Mini工作站 / 3=公司主力Pro"
  echo "  2) Git 用户名/邮箱：可直接按回车跳过（不影响装机）"
  echo "  3) 是否同步 starship 终端样式：一般选 y"
  echo "  4) 是否同步 SSH 配置：vault 已恢复密钥，可选 y"
  echo ""
  chezmoi init --apply --guess-repo-url=false "$repo"
}

main() {
  echo "===================================================="
  echo "🚀 Mac 一行装机 · vault 版"
  echo "===================================================="
  echo "全程你只需要做这几件事（其余全自动）："
  echo "  1. 若弹出 CLT 安装窗口 → 点【安装】"
  echo "  2. 输入一次【这台电脑的开机密码】（装 Homebrew 用）"
  echo "  3. 输入一次【vault 装机密码】（解密密钥包用，和开机密码不同）"
  echo "  4. 回答几个中文选择题（机器角色等）"
  echo ""
  echo "💡 本脚本可反复运行：已完成的步骤会自动跳过，"
  echo "   万一中途失败或卡住，直接重新粘贴同一行命令即可续跑，不会重来。"
  echo "===================================================="
  preflight_admin
  ensure_clt
  ensure_brew
  ensure_tools
  download_and_decrypt_vault
  install_age_identity
  install_github_token
  run_chezmoi
  echo ""
  echo "===================================================="
  echo "完成。若这是个人设备，记得只安装你需要的公司管控/内网工具。"
  echo "===================================================="
}

main "$@"
