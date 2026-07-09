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

# ---- 全局幕头（金字塔式：5 幕剧统一编号，用户永远知道走到哪了）----
# 用法：act 1 "浇筑地基"
TOTAL_ACTS=5
act() {
  local n="$1"; shift
  echo ""
  echo "${C_BOLD}${C_BLUE}╔══════════════════════════════════════════════════╗${C_RESET}"
  printf "${C_BOLD}${C_BLUE}║${C_RESET} ${C_BOLD}第 %s / %s 幕：%-32s${C_RESET} ${C_BOLD}${C_BLUE}║${C_RESET}\n" "$n" "$TOTAL_ACTS" "$*"
  echo "${C_BOLD}${C_BLUE}╚══════════════════════════════════════════════════╝${C_RESET}"
}

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
  # 不 unset：ensure_software 里可能还要用 token 从 raw 直下私有仓文件(fallback)。
  # bootstrap 结束进程退出后环境变量自然消失，不落盘、无残留。
  ok "GitHub 凭证已写入 macOS 钥匙串。"
}

run_chezmoi() {
  local repo="https://github.com/${DOTFILES_SLUG}.git"

  # ─── shell 前置问答：可控回显 + 输入校验 + 立刻反馈 ───
  # 为什么不让 chezmoi 模板自己问？
  # 实测 promptIntOnce 在 chezmoi 命令行输出流里，用户输 1 之后没有任何回显，
  # 视觉上像"被吃掉了"。把交互提前到 shell 层，问完把答案通过
  # --promptInt/--promptString/--promptBool 精确注入 chezmoi 模板，
  # 模板里保留 promptXxxOnce 兜底(以后单跑 chezmoi apply 时也能用)。
  #
  # 幂等：如果 ~/.config/chezmoi/chezmoi.toml 已存在,说明角色等已缓存过,
  # 跳过所有问题,直接 chezmoi init --apply 用已有配置继续。
  local toml="$HOME/.config/chezmoi/chezmoi.toml"
  local prompt_args=()
  if [ -f "$toml" ] && grep -q '^role' "$toml" 2>/dev/null; then
    ok "检测到已有 chezmoi 配置，跳过选择题，直接应用。"
  else
    echo ""
    title "📋 5 道选择题（只问一次，答案写入 $toml 后永不再问）"
    echo ""

    # ① 机器角色
    local role_num=""
    while true; do
      echo "${C_BOLD}① 这台机器的角色？${C_RESET}"
      echo "   [1] mobile — MacBook Air 移动机（每天带走、轻量、续航优先）"
      echo "   [2] studio — Mac Mini 大模型工作站（常开、跑本地 LLM）"
      echo "   [3] work   — MacBook Pro 公司主力（重开发+内网应用）"
      printf "   请输入数字 1/2/3： "
      read -r role_num </dev/tty
      case "$role_num" in
        1) echo "   ${C_GREEN}✔ 已选：mobile (MacBook Air 移动机)${C_RESET}"; break ;;
        2) echo "   ${C_GREEN}✔ 已选：studio (Mac Mini 大模型工作站)${C_RESET}"; break ;;
        3) echo "   ${C_GREEN}✔ 已选：work (MacBook Pro 公司主力)${C_RESET}"; break ;;
        *) echo "   ${C_RED}✗ 请输入 1、2 或 3。${C_RESET}" ;;
      esac
    done
    echo ""

    # ② Git 用户名
    printf "${C_BOLD}② Git 用户名${C_RESET}（回车用默认 ${C_BOLD}ailan${C_RESET}）： "
    local git_name=""
    read -r git_name </dev/tty
    [ -z "$git_name" ] && git_name="ailan"
    echo "   ${C_GREEN}✔ 已设：$git_name${C_RESET}"
    echo ""

    # ③ Git 邮箱
    printf "${C_BOLD}③ Git 邮箱${C_RESET}（回车跳过，日后再补）： "
    local git_email=""
    read -r git_email </dev/tty
    if [ -n "$git_email" ]; then
      echo "   ${C_GREEN}✔ 已设：$git_email${C_RESET}"
    else
      echo "   ${C_GREEN}✔ 跳过（未设邮箱）${C_RESET}"
    fi
    echo ""

    # ④ starship 样式
    local starship_ans="" sync_starship="true"
    while true; do
      printf "${C_BOLD}④ 同步 starship 终端提示符样式？${C_RESET}（y/n，回车=y）： "
      read -r starship_ans </dev/tty
      case "$starship_ans" in
        ""|Y|y|Yes|yes) sync_starship="true"; echo "   ${C_GREEN}✔ 已启用 starship 同步${C_RESET}"; break ;;
        N|n|No|no)      sync_starship="false"; echo "   ${C_GREEN}✔ 关闭 starship 同步${C_RESET}"; break ;;
        *) echo "   ${C_RED}✗ 请输入 y 或 n（或直接回车用默认 y）。${C_RESET}" ;;
      esac
    done
    echo ""

    # ⑤ SSH 配置
    local ssh_ans="" sync_ssh="true"
    local ssh_default="y"; local ssh_default_v="true"
    [ ! -f "$HOME/.config/chezmoi/key.txt" ] && ssh_default="n" && ssh_default_v="false"
    while true; do
      printf "${C_BOLD}⑤ 同步 SSH 配置？${C_RESET}（需要 age 私钥；y/n，回车=$ssh_default）： "
      read -r ssh_ans </dev/tty
      if [ -z "$ssh_ans" ]; then ssh_ans="$ssh_default"; fi
      case "$ssh_ans" in
        Y|y|Yes|yes) sync_ssh="true"; echo "   ${C_GREEN}✔ 已启用 SSH 同步${C_RESET}"; break ;;
        N|n|No|no)   sync_ssh="false"; echo "   ${C_GREEN}✔ 关闭 SSH 同步${C_RESET}"; break ;;
        *) echo "   ${C_RED}✗ 请输入 y 或 n。${C_RESET}" ;;
      esac
    done
    echo ""

    # 用 --promptInt/--promptString/--promptBool 把 shell 答案精确注入模板
    prompt_args=(
      --promptInt "roleNum=$role_num"
      --promptString "name=$git_name"
      --promptString "email=$git_email"
      --promptBool "syncStarship=$sync_starship"
      --promptBool "syncSshConfig=$sync_ssh"
    )
  fi

  log "拉取并应用私有 dotfiles：$repo"
  # 冲突时自动用仓库版覆盖，不打断用户（个人手动改过 gitconfig 等会触发）
  chezmoi init --apply --guess-repo-url=false --force "${prompt_args[@]}" "$repo"
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
      # 策略 A：整仓 git fetch（多加速站兜底）——最完整，但 git 端点常被墙。
      # 国内直连 github.com 常年不稳,若只走 origin 会 fallback 到旧版脚本,
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
        # 策略 B（降级）：git 端点全挂，但 bootstrap.sh 自己是从 raw 拉下来的
        # → 说明 raw.githubusercontent.com 通。直接从 raw 下载 90 脚本覆盖本地文件，
        # 只更新装软件脚本这一个关键文件，绕开 git 协议端点被墙的问题。
        # 私有仓 raw 需要 Bearer token；从当前进程环境变量取(vault 解密后未被 unset)。
        warn "git fetch 全部失败，改用 raw 直下核心脚本..."
        local curl_auth=()
        if [ -n "${GITHUB_TOKEN:-}" ]; then
          curl_auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
        fi
        local raw_bases=(
          "https://gh-proxy.com/https://raw.githubusercontent.com/${DOTFILES_SLUG}/main"
          "https://raw.gitmirror.com/${DOTFILES_SLUG}/main"
          "https://raw.githubusercontent.com/${DOTFILES_SLUG}/main"
        )
        # 只补下最关键的 90 脚本(装软件)。其他脚本要么早就跑过、要么本机版够用。
        local target_file="run_once_after_90_install_brew_bundle.sh"
        local raw_ok=""
        for raw_base in "${raw_bases[@]}"; do
          local raw_url="${raw_base}/${target_file}"
          log "raw 下载尝试: ${raw_base%%/https:*}"
          if curl -fsSL --max-time 30 "${curl_auth[@]}" "$raw_url" -o "${src}/${target_file}.new" 2>/dev/null \
             && [ -s "${src}/${target_file}.new" ] \
             && head -1 "${src}/${target_file}.new" | grep -q '^#!'; then
            mv "${src}/${target_file}.new" "${src}/${target_file}"
            chmod +x "${src}/${target_file}"
            ok "已直接更新 ${target_file} 到最新版。"
            raw_ok=1
            break
          fi
          rm -f "${src}/${target_file}.new" 2>/dev/null
        done
        [ -z "$raw_ok" ] && warn "raw 也全挂了。请检查网络后重跑；本次将用本机现有脚本继续。"
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
  # 90 脚本内部已做失败汇总，不会因单个失败中断；用 || true 防止 set -e 提前退出
  bash "$sw" || warn "部分软件未装成功（见上方汇总），可再次重跑本命令补齐。"
}

main() {
  hr
  title "🚀 Mac 一行装机 · vault 版 · 全流程 5 幕剧"
  hr
  echo "接下来会分 5 幕自动执行，全程你只需 ${C_BOLD}3 次输入${C_RESET}："
  echo "  幕 1 · 浇筑地基       — 装 CLT / Homebrew（可能弹一次 CLT 安装窗口）"
  echo "  幕 2 · 解密身份       — 需要输入 ${C_YELLOW}【vault 装机密码】${C_RESET}"
  echo "  幕 3 · 拉取仓库&选择题 — 需要输入 ${C_YELLOW}【开机密码】${C_RESET} + 回答机器角色等"
  echo "  幕 4 · 注入系统设置   — 自动（触控板、听写、电源策略等）"
  echo "  幕 5 · 批量装软件     — 自动，约 ${C_BOLD}30-60 分钟${C_RESET}（40+ 软件、含 Office/微信大包）"
  echo ""
  echo "${C_DIM}💡 本脚本${C_BOLD}完全幂等${C_RESET}${C_DIM}：中途卡住/失败随时 Ctrl+C，重贴一行命令自动续跑，${C_RESET}"
  echo "${C_DIM}   已完成的步骤会秒判跳过，绝不重复浪费时间。${C_RESET}"
  hr
  preflight_admin

  # ─── 幕 1：浇筑地基 ─────────────────────────────────────────
  act 1 "浇筑地基（CLT + Homebrew + 核心工具）"
  ensure_clt
  ensure_brew
  ensure_tools

  # ─── 幕 2：解密身份 ─────────────────────────────────────────
  act 2 "解密身份（age 私钥 + GitHub 凭证）"
  download_and_decrypt_vault
  install_age_identity
  install_github_token

  # ─── 幕 3：拉取仓库 + 选择题 ────────────────────────────────
  # 注：chezmoi apply 会串行触发幕 4（10 脚本系统设置）与幕 5 前置（20 地基复检）。
  # 由 bootstrap 打幕头 + 各脚本自己不再喊大标题（改用小节标题）。
  act 3 "拉取 dotfiles 仓库 + 回答选择题"
  run_chezmoi

  # ─── 幕 5：批量装软件 ────────────────────────────────────────
  # 幕 4 已由 chezmoi apply 内触发（10 脚本）。这里由 bootstrap 主动跑 90
  # 是为了处理"中途卡死重跑"场景（chezmoi 会认为 run_once 已跑过而跳过）。
  act 5 "批量装软件（逐条进度+心跳+超时保护）"
  ensure_software

  echo ""
  hr
  title "🎉 五幕演出完成！Mac 已从裸机变成你的顶级工作站。"
  echo "${C_DIM}下一步：${C_RESET}"
  echo "  ${C_BOLD}·${C_RESET} 重启一次电脑（触控板/听写等系统设置才完全生效）"
  echo "  ${C_BOLD}·${C_RESET} 查看 ${C_BOLD}~/.Brewfile.manual.txt${C_RESET} 手动装剩下的（WorkBuddy 等司内软件）"
  echo "  ${C_BOLD}·${C_RESET} 双击桌面「补装海外软件.command」补 Chrome/Claude/ChatGPT（需外网）"
  echo "  ${C_BOLD}·${C_RESET} 系统设置 → 隐私与安全性 → 辅助功能：勾选 Raycast / Loop"
  echo ""
  echo "${C_DIM}如个别软件未装成功，直接重跑本命令即可继续补齐（已装的会跳过）。${C_RESET}"
  hr
}

main "$@"
