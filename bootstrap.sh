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

# ---- 终端配色（bash 3.2 兼容；非 TTY 或不支持时自动降级为无色）----
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'
else
  C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_RESET=''
fi

log()  { echo "${C_DIM}[$(date +%H:%M:%S)]${C_RESET} $*"; }
ok()   { echo "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo "${C_YELLOW}⚠️  $*${C_RESET}"; }
err()  { echo "${C_RED}❌ $*${C_RESET}"; }
hr()   { echo "${C_CYAN}────────────────────────────────────────────────────${C_RESET}"; }
title(){ echo "${C_BOLD}${C_CYAN}$*${C_RESET}"; }

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
    ok "CLT 已就绪。"
    return
  fi
  echo "${C_YELLOW}📦 即将弹出苹果的 CLT 安装窗口 → 请点【安装】，等它下载完成（约几分钟）。${C_RESET}"
  xcode-select --install 2>/dev/null || true
  until xcode-select -p >/dev/null 2>&1; do
    printf "\r\033[K${C_DIM}⏳ 正在等待 CLT 安装完成（在弹窗里点了【安装】后耐心等）...${C_RESET}"
    sleep 5
  done
  printf "\r\033[K"
  ok "CLT 安装完成。"
}

ensure_sudo() {
  echo ""
  hr
  echo "${C_YELLOW}${C_BOLD}🔑 需要授权：请输入【这台 Mac 的开机/登录密码】${C_RESET}"
  echo "${C_DIM}   （就是你每天开机、解锁这台电脑用的那个密码；不是 vault 密码）"
  echo "   输入时屏幕不显示任何字符，这是正常的，输完按回车即可。${C_RESET}"
  hr
  if ! sudo -v; then
    echo ""
    err "sudo 授权失败，无法继续安装 Homebrew。请确认输入的是本机开机密码。"
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
  ok "Homebrew 已就绪。"
}

ensure_tools() {
  log "安装/确认 age、git、chezmoi、gh..."
  for pkg in age git chezmoi gh; do
    if brew list "$pkg" >/dev/null 2>&1; then
      ok "$pkg 已安装。"
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
  hr
  echo "${C_YELLOW}${C_BOLD}🔐 需要输入：【vault 装机密码】（不是这台电脑的开机密码！）${C_RESET}"
  echo "${C_DIM}   这是你之前专门为装机设定的那个密码，用来解开加密的密钥包。"
  echo "   下面会出现一行英文 “Enter passphrase:”，那就是让你输这个密码。"
  echo "   输入时屏幕不显示任何字符，这是正常的，输完按回车。${C_RESET}"
  hr
  if ! age -d "$vault_file" > "$env_file"; then
    echo ""
    err "vault 解密失败：密码不对，或 vault 文件损坏。"
    echo "${C_DIM}   提示：这里要输的是【vault 装机密码】，不是电脑开机密码。可重新运行本命令再试。${C_RESET}"
    exit 1
  fi

  # shellcheck disable=SC1090
  set -a
  source "$env_file"
  set +a

  ok "vault 已解密。"
}

install_age_identity() {
  if [[ -n "${AGE_IDENTITY_B64:-}" ]]; then
    mkdir -p "$HOME/.config/chezmoi"
    printf "%s" "$AGE_IDENTITY_B64" | decode_b64 > "$HOME/.config/chezmoi/key.txt"
    chmod 600 "$HOME/.config/chezmoi/key.txt"
    ok "已恢复 age 私钥到 ~/.config/chezmoi/key.txt。"
  else
    warn "vault 中未包含 AGE_IDENTITY_B64，将跳过 SSH 配置解密。"
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
  ok "GitHub 凭证已写入 macOS 钥匙串。"
}

run_chezmoi() {
  local repo="https://github.com/${DOTFILES_SLUG}.git"
  log "拉取并应用私有 dotfiles：$repo"
  echo ""
  title "📝 接下来会出现几个中文选择题（很快，只问一次并记住）："
  echo "  ${C_BOLD}1)${C_RESET} 机器角色：输数字 ${C_BOLD}1${C_RESET}=移动机Air / ${C_BOLD}2${C_RESET}=Mac Mini工作站 / ${C_BOLD}3${C_RESET}=公司主力Pro"
  echo "  ${C_BOLD}2)${C_RESET} Git 用户名/邮箱：可直接按回车跳过（不影响装机）"
  echo "  ${C_BOLD}3)${C_RESET} 是否同步 starship 终端样式：一般选 ${C_BOLD}y${C_RESET}"
  echo "  ${C_BOLD}4)${C_RESET} 是否同步 SSH 配置：vault 已恢复密钥，可选 ${C_BOLD}y${C_RESET}"
  echo "${C_DIM}   （若提示某文件已被改动，会自动用仓库版本覆盖，无需你选择）${C_RESET}"
  echo ""
  # 冲突时自动用仓库版覆盖，不打断用户（个人手动改过 gitconfig 等会触发）
  chezmoi init --apply --guess-repo-url=false --force "$repo"
}

ensure_software() {
  # 关键：chezmoi 的 run_once 脚本(装软件的 90)只按内容跑一次——
  # 若首次装机中途卡住/中断，重跑 bootstrap 时 chezmoi 会认为"已跑过"而跳过，
  # 导致软件没装全却显示完成。这里由 bootstrap 主动再跑一次装软件脚本。
  local src="${HOME}/.local/share/chezmoi"

  # 先把本机 dotfiles source 强制更新到 GitHub 最新，
  # 避免跑到本机残留的旧版装软件脚本（旧版无进度、无 GitHub 加速）。
  # 安全保护：source 是软链（如开发机指向云盘工作仓）或有未提交改动时不动它，
  # 只对"纯 clone 的新机 source"做强制同步。
  if [ -d "$src/.git" ] && [ ! -L "$src" ]; then
    if [ -z "$(git -C "$src" status --porcelain 2>/dev/null)" ]; then
      log "更新本机 dotfiles 到最新版本..."
      # 加速站候选：先本机加速前缀，最后裸连 GitHub 兜底。
      # 国内直连 github.com 常年不稳，若只走 origin 会 fallback 到旧版脚本，
      # 导致 90(装软件) 走的还是"无进度无超时"的老代码 → 用户看到卡死。
      local base_url="https://github.com/${DOTFILES_SLUG}.git"
      local orig_remote; orig_remote="$(git -C "$src" remote get-url origin 2>/dev/null || echo "$base_url")"
      # GIT_TERMINAL_PROMPT=0：绝不弹用户名/密码交互，避免卡在凭证输入。
      local fetched=""
      for accel_prefix in "" "https://gh-proxy.com/" "https://ghproxy.net/" "https://github.akams.cn/"; do
        local try_url="${accel_prefix}${base_url}"
        # 裸连时用 origin 原 URL(可能已带凭证)，加速时临时切
        if [ -n "$accel_prefix" ]; then
          git -C "$src" remote set-url origin "$try_url" 2>/dev/null || continue
          log "尝试通过加速站更新: ${accel_prefix%/}"
        else
          log "尝试直连 GitHub 更新..."
        fi
        if GIT_TERMINAL_PROMPT=0 git -C "$src" \
             -c http.lowSpeedLimit=1000 \
             -c http.lowSpeedTime=15 \
             fetch origin main >/dev/null 2>&1; then
          fetched=1
          break
        fi
      done
      # 无论成败,把 origin 还原为原始 URL(避免污染)
      git -C "$src" remote set-url origin "$orig_remote" 2>/dev/null || true

      if [ -n "$fetched" ]; then
        git -C "$src" reset --hard FETCH_HEAD >/dev/null 2>&1 \
          && ok "已更新到最新脚本。" \
          || warn "无法重置到最新，将用本机现有版本继续。"
      else
        warn "所有加速站均无法更新脚本（网络问题？），将用本机现有版本继续。"
      fi
    else
      warn "本机 dotfiles 有未提交改动，跳过自动更新（避免覆盖你的修改）。"
    fi
  fi

  local sw="${src}/run_once_after_90_install_brew_bundle.sh"
  if [ ! -f "$HOME/.Brewfile" ]; then
    warn "未找到 ~/.Brewfile（软件向导可能未生成清单），跳过补装。可重跑 'chezmoi apply' 触发向导。"
    return
  fi
  if [ ! -f "$sw" ]; then
    warn "未找到装软件脚本，跳过补装。"
    return
  fi
  echo ""
  hr
  title "📦 确保软件已装齐（幂等：已装的会自动跳过，未装的补上）"
  hr
  # 90 脚本内部已做失败汇总，不会因单个失败中断；用 || true 防止 set -e 提前退出
  bash "$sw" || warn "部分软件未装成功（见上方汇总），可再次重跑本命令补齐。"
}

main() {
  hr
  title "🚀 Mac 一行装机 · vault 版"
  hr
  echo "全程你只需做这几件事（其余全自动）："
  echo "  ${C_BOLD}1.${C_RESET} 若弹出 CLT 安装窗口 → 点${C_BOLD}【安装】${C_RESET}"
  echo "  ${C_BOLD}2.${C_RESET} 输入一次 ${C_YELLOW}【这台电脑的开机密码】${C_RESET}（装 Homebrew 用）"
  echo "  ${C_BOLD}3.${C_RESET} 输入一次 ${C_YELLOW}【vault 装机密码】${C_RESET}（解密密钥包，${C_BOLD}和开机密码不同${C_RESET}）"
  echo "  ${C_BOLD}4.${C_RESET} 回答几个中文选择题（机器角色等）"
  echo ""
  echo "${C_DIM}💡 本脚本可反复运行：已完成的步骤会自动跳过；"
  echo "   万一中途失败或卡住，直接重新粘贴同一行命令即可续跑，不会重来。${C_RESET}"
  hr
  preflight_admin
  ensure_clt
  ensure_brew
  ensure_tools
  download_and_decrypt_vault
  install_age_identity
  install_github_token
  run_chezmoi
  ensure_software
  echo ""
  hr
  title "🎉 装机流程完成！"
  echo "${C_DIM}若这是个人设备，记得只安装你需要的公司管控/内网工具。${C_RESET}"
  echo "${C_DIM}如仍有个别软件未装成功，直接重跑本命令即可继续补齐（已装的会跳过）。${C_RESET}"
  hr
}

main "$@"
