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

# ---- 全局 6 幕编号（用户永远知道走到哪了）----
# 用法：act 1 "浇筑地基"
TOTAL_ACTS=6
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
  echo "   输入时屏幕不显示任何字符，这是正常的，输完按回车即可。"
  echo "   本次只问这一次，接下来的所有系统操作都由此授权覆盖。${C_RESET}"
  hr
  if ! sudo -v; then
    echo ""
    err "sudo 授权失败，无法继续安装 Homebrew。请确认输入的是本机开机密码。"
    exit 1
  fi
  # 后台保活：只要主进程活着，就每 30 秒续期一次 sudo 时间戳。
  # macOS sudo 默认 5 分钟过期,30s 间隔留足 buffer。
  # 主进程退出后 kill -0 失败，自动结束。
  ( while true; do sudo -n true 2>/dev/null; sleep 30; kill -0 "$$" 2>/dev/null || exit; done ) &
  SUDO_KEEPALIVE_PID=$!
  ok "已获取管理员授权，全程只需这一次。"
}

ensure_brew() {
  log "检测 Homebrew..."
  if ! command -v brew >/dev/null 2>&1; then
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
  echo "   输入时屏幕不显示任何字符，这是正常的，输完按回车。"
  echo "   最多可以尝试 3 次,输错不会退出装机。${C_RESET}"
  hr

  # 允许最多 3 次密码尝试,输错不直接退出——防止误输导致前面全白干。
  local attempt=0
  local max_attempts=3
  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt + 1))
    if age -d "$vault_file" > "$env_file" 2>/dev/null; then
      break
    fi
    if [ $attempt -lt $max_attempts ]; then
      echo ""
      warn "vault 解密失败(第 $attempt/$max_attempts 次)。"
      echo "${C_DIM}   提示：这里要输的是【vault 装机密码】,不是电脑开机密码。${C_RESET}"
      echo "${C_DIM}   继续尝试(还剩 $((max_attempts - attempt)) 次)...${C_RESET}"
    else
      echo ""
      err "vault 解密连续失败 $max_attempts 次,无法继续。"
      echo "${C_DIM}   如果确认密码正确但仍失败,可能是 vault 文件损坏——"
      echo "   请检查 https://github.com/Zpwww/dotfiles-bootstrap 是否有更新。${C_RESET}"
      exit 1
    fi
  done

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

run_chezmoi_prompts_only() {
  # ─── shell 前置问答：可控回显 + 输入校验 + 立刻反馈 ───
  # 收完 5 题后直接预填 ~/.config/chezmoi/chezmoi.toml,
  # chezmoi init 检测到配置已存在就不会再渲染模板,promptXxxOnce 一次都不会被调用。
  # (这是绕开"chezmoi init 时重复问询"的唯一可靠办法——上次踩过 --override-data-file 的坑)
  #
  # 幂等：如果 ~/.config/chezmoi/chezmoi.toml 已存在,说明角色等已缓存过,跳过所有问题。
  local toml="$HOME/.config/chezmoi/chezmoi.toml"
  if [ -f "$toml" ] && grep -q '^role' "$toml" 2>/dev/null; then
    ok "检测到已有 chezmoi 配置，跳过选择题（首次装机之后不再问）。"
    return
  fi

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
  printf "${C_BOLD}② Git 用户名${C_RESET}（回车用默认 ${C_BOLD}Zpwww${C_RESET}，即你的 GitHub 用户名）： "
  local git_name=""
  read -r git_name </dev/tty
  [ -z "$git_name" ] && git_name="Zpwww"
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
  local starship_ans=""
  local sync_starship="true"
  while true; do
    printf "${C_BOLD}④ 同步 starship 终端提示符样式？${C_RESET}（y/n，回车=y）： "
    read -r starship_ans </dev/tty
    case "${starship_ans}" in
      ""|Y|y|Yes|yes) sync_starship="true"; echo "   ${C_GREEN}✔ 已启用 starship 同步${C_RESET}"; break ;;
      N|n|No|no)      sync_starship="false"; echo "   ${C_GREEN}✔ 关闭 starship 同步${C_RESET}"; break ;;
      *) echo "   ${C_RED}✗ 请输入 y 或 n（或直接回车用默认 y）。${C_RESET}" ;;
    esac
  done
  echo ""

  # ⑤ SSH 配置
  # 智能默认：本机已有 age 私钥→默认 y；没有→默认 n。
  local ssh_ans=""
  local sync_ssh="true"
  local ssh_default="y"
  if [ ! -f "$HOME/.config/chezmoi/key.txt" ]; then
      ssh_default="n"
  fi
  while true; do
    printf "${C_BOLD}⑤ 同步 SSH 配置？${C_RESET}（需要 age 私钥；y/n，回车=${ssh_default}）： "
    read -r ssh_ans </dev/tty
    if [ -z "$ssh_ans" ]; then ssh_ans="${ssh_default}"; fi
    case "$ssh_ans" in
      Y|y|Yes|yes) sync_ssh="true"; echo "   ${C_GREEN}✔ 已启用 SSH 同步${C_RESET}"; break ;;
      N|n|No|no)   sync_ssh="false"; echo "   ${C_GREEN}✔ 关闭 SSH 同步${C_RESET}"; break ;;
      *) echo "   ${C_RED}✗ 请输入 y 或 n。${C_RESET}" ;;
    esac
  done
  echo ""

  # 写完整 chezmoi.toml 让 chezmoi init 直接跳过所有 prompt。
  # 关键:chezmoi init 检测到 ~/.config/chezmoi/chezmoi.toml 已存在时,
  # 就不会再渲染 .chezmoi.toml.tmpl,promptXxxOnce 一次都不会被调用。
  # 这是绕开"重复问询"的唯一可靠办法(--override-data-file 只作用于模板执行阶段,
  # chezmoi init 生成配置那一步不看它——上次踩过的坑)。
  mkdir -p "$HOME/.config/chezmoi"

  # 派生 role/roleFlags(和模板逻辑保持一致)
  local role_str="work"
  case "$role_num" in
    1) role_str="mobile" ;;
    2) role_str="studio" ;;
    3) role_str="work" ;;
  esac
  local is_mobile="false"; local is_studio="false"; local is_work="false"
  local is_heavy="false"; local needs_enterprise="false"; local is_always_on="false"
  case "$role_str" in
    mobile) is_mobile="true" ;;
    studio) is_studio="true"; is_heavy="true"; is_always_on="true" ;;
    work)   is_work="true"; is_heavy="true"; needs_enterprise="true" ;;
  esac
  local brew_prefix="/opt/homebrew"
  [ "$(uname -m)" != "arm64" ] && brew_prefix="/usr/local"

  cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
encryption = "age"

[age]
    identity = "~/.config/chezmoi/key.txt"
    recipient = "age1gu9dhr2az6ndjxdy00rf29r2aqaw9skm8683n0ds08mzlqv9p3gq8u7wts"

[data]
    roleNum = $role_num
    role = "$role_str"
    name = "$git_name"
    email = "$git_email"
    syncStarship = $sync_starship
    syncSshConfig = $sync_ssh
    brewPrefix = "$brew_prefix"

[data.roleFlags]
    isMobile = $is_mobile
    isStudio = $is_studio
    isWork = $is_work
    isHeavy = $is_heavy
    needsEnterprise = $needs_enterprise
    isAlwaysOn = $is_always_on
EOF
  ok "5 题已收集,配置已写入 ~/.config/chezmoi/chezmoi.toml"
}

run_chezmoi_apply() {
  local repo="https://github.com/${DOTFILES_SLUG}.git"
  log "拉取并应用私有 dotfiles：$repo"
  # chezmoi.toml 已由 run_chezmoi_prompts_only 预填,init 检测到不再问 prompt。
  # --force: 冲突时用仓库版覆盖(处理个人手动改过 gitconfig 等场景)。
  chezmoi init --apply --guess-repo-url=false --force "$repo"
}

ensure_software() {
  # 兜底续跑：只在检测到"上次装机没跑完"时才补跑,避免与 chezmoi apply 内触发的 90 重复输出。
  #
  # 判据(从强到弱):
  #   ① ~/.local/state/dotfiles-install-logs/last_failed.Brewfile 存在且非空
  #      → 上次有失败,补跑
  #   ② 没有装机日志文件(说明 chezmoi run_once 跳过了 90,当前是重跑 bootstrap)
  #      → 补跑
  #   ③ 有日志但很小(<50 行,说明中途崩掉)
  #      → 补跑
  # 其它情况(chezmoi apply 刚刚跑完 90,没失败,日志正常) → 跳过兜底,不重复。
  local src="${HOME}/.local/share/chezmoi"
  local log_dir="$HOME/.local/state/dotfiles-install-logs"
  local retry_file="$log_dir/last_failed.Brewfile"
  local need_run=""
  local latest_log=""

  if [ -s "$retry_file" ]; then
    need_run="1"; log "检测到上次有失败项 → 补跑装软件..."
  elif [ ! -d "$log_dir" ] || [ -z "$(ls -1 "$log_dir"/brew_bundle_*.log 2>/dev/null)" ]; then
    need_run="1"; log "未检测到装软件日志 → 主动跑一次装软件..."
  else
    latest_log="$(ls -1t "$log_dir"/brew_bundle_*.log 2>/dev/null | head -1)"
    if [ -n "$latest_log" ] && [ "$(wc -l < "$latest_log" 2>/dev/null)" -lt 50 ]; then
      need_run="1"; log "上次装软件日志异常短(疑似中断) → 补跑..."
    fi
  fi

  if [ -z "$need_run" ]; then
    ok "本轮 chezmoi apply 已完成装软件,无需再跑。"
    return
  fi

  # 走到这里 = 真需要补跑。先强同步最新脚本(处理"卡死重跑走旧脚本"场景)。
  if [ -d "$src/.git" ] && [ ! -L "$src" ]; then
    if [ -z "$(git -C "$src" status --porcelain 2>/dev/null)" ]; then
      log "更新本机 dotfiles 到最新版本..."
      local base_url="https://github.com/${DOTFILES_SLUG}.git"
      local orig_remote; orig_remote="$(git -C "$src" remote get-url origin 2>/dev/null || echo "$base_url")"
      local fetched=""
      for accel_prefix in "" "https://gh-proxy.com/" "https://ghproxy.net/" "https://github.akams.cn/"; do
        local try_url="${accel_prefix}${base_url}"
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
      git -C "$src" remote set-url origin "$orig_remote" 2>/dev/null || true

      if [ -n "$fetched" ]; then
        git -C "$src" reset --hard FETCH_HEAD >/dev/null 2>&1 \
          && ok "已更新到最新脚本。" \
          || warn "无法重置到最新，将用本机现有版本继续。"
      else
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
  # P2: preflight_admin 前置到 banner 之前——不满足条件的用户不看 banner,直接告诉他改权限
  preflight_admin

  hr
  title "🚀 Mac 一行装机 · vault 版 · 6 幕全流程"
  hr
  echo "全流程分 6 幕自动执行，${C_BOLD}你只需 2 次输入 + 1 组选择题${C_RESET}："
  echo "  幕 1 · 装地基         — 装 CLT / Homebrew / 核心工具"
  echo "                          需要输入 ${C_YELLOW}【开机密码】${C_RESET} × 1（全程只问这一次）"
  echo "  幕 2 · 解密身份       — 解密 vault，恢复 age 私钥 + GitHub 凭证"
  echo "                          需要输入 ${C_YELLOW}【vault 装机密码】${C_RESET} × 1"
  echo "  幕 3 · 5 题选项       — 机器角色/Git 身份/starship/SSH 同步"
  echo "                          shell 交互，答完立刻回显 ✔"
  echo "  幕 4 · 系统设置       — 触控板/听写/电源策略（按角色分化）"
  echo "  幕 5 · 生成软件清单   — 按角色推荐清单（默认自动；WIZARD=1 弹浏览器）"
  echo "  幕 6 · 批量装软件     — 40+ 软件，${C_BOLD}约 25-45 分钟${C_RESET}，逐条进度+心跳+超时"
  echo ""
  echo "${C_DIM}💡 装机进行时的使用指南（收藏本条）：${C_RESET}"
  echo "${C_DIM}   ✔ 可以：切窗口做别的、让电脑合盖休眠（brew 会自动暂停恢复）${C_RESET}"
  echo "${C_DIM}   ✘ 不要：断网 / 关机 / 强制重启${C_RESET}"
  echo "${C_DIM}   💾 想中断：Ctrl+C 随时安全退出，重贴同一行命令自动续跑（已完成步骤秒过）${C_RESET}"
  echo "${C_DIM}   📄 全程日志：~/.local/state/dotfiles-install-logs/brew_bundle_*.log${C_RESET}"
  hr

  # ─── 幕 1：装地基（先拿一次 sudo，全程 keepalive）──────────────
  act 1 "装地基（CLT + Homebrew + 核心工具）"
  ensure_sudo             # 全程唯一一次开机密码，keepalive 到进程退出
  ensure_clt
  ensure_brew
  ensure_tools

  # ─── 幕 2：解密身份 ─────────────────────────────────────────
  act 2 "解密身份（age 私钥 + GitHub 凭证）"
  download_and_decrypt_vault
  install_age_identity
  install_github_token

  # ─── 幕 3：5 题选择 + 拉取仓库 ──────────────────────────────
  act 3 "回答 5 道选择题（1 分钟）"
  run_chezmoi_prompts_only

  # ─── 幕 4/5/6：chezmoi apply 会串行触发 10 → 80 → 90 → 95 ────
  # 提前告诉用户接下来会看到什么,避免"突然一堆子脚本冒出来"的懵。
  act 4 "注入系统设置（触控板/听写/电源/分辨率）"
  echo "${C_DIM}由 chezmoi apply 自动触发 run_once_after_10。约 5 秒。${C_RESET}"

  act 5 "生成软件清单（按角色推荐，无需操作）"
  echo "${C_DIM}由 chezmoi apply 自动触发 run_once_after_80。约 3 秒。${C_RESET}"

  act 6 "批量装软件（40+ 项 · ${C_BOLD}25-45 分钟${C_RESET}${C_DIM}）"
  echo "由 chezmoi apply 自动触发 run_once_after_90 → run_once_after_95。${C_RESET}"

  run_chezmoi_apply

  # ─── 兜底续跑（智能判断,不重复输出）───
  # 只在 chezmoi apply 因为 run_once 缓存跳过 90、或上次有失败项时才补跑。
  # 正常首次装机走完就 return,不会重复输出装软件进度。
  ensure_software

  # ─── 收尾展示 ───────────────────────────────────────────
  show_completion_banner
}

# P3: 子命令入口——细粒度操作,不必每次跑完整 6 幕
show_help() {
  cat <<EOF
用法: bash bootstrap.sh [子命令]

子命令:
  (无参数)         完整 6 幕装机流程（首次装机必走这条）
  retry            只重跑上次失败的软件（读取 ~/.local/state/dotfiles-install-logs/last_failed.Brewfile）
  reset            清 chezmoi 缓存 + 重问 5 题（换角色/换 Git 身份时用）
  apply            只跑 chezmoi apply（配置改动后同步）
  install          只跑装软件的 90 脚本（清单已生成时用）
  wizard           启动图形向导让你手动勾选软件（等同 WIZARD=1 apply）
  help, --help     打印本帮助

例子:
  # 首次装机
  bash -c "\$(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/Zpwww/dotfiles-bootstrap/main/bootstrap.sh)"

  # 只补装失败的软件
  curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/Zpwww/dotfiles-bootstrap/main/bootstrap.sh | bash -s retry
EOF
}

cmd_retry() {
  hr
  title "🔁 只重试上次失败的软件"
  hr
  local retry_file="$HOME/.local/state/dotfiles-install-logs/last_failed.Brewfile"
  if [ ! -s "$retry_file" ]; then
    ok "没有需要重试的软件（上次装机全成功或未装过）。"
    return
  fi
  local count; count=$(grep -cE '^(cask|brew|mas) ' "$retry_file" 2>/dev/null || echo 0)
  echo "上次失败的 $count 个软件:"
  cat "$retry_file"
  echo ""
  HOMEBREW_ARTIFACT_DOMAIN=https://gh-proxy.com brew bundle --file="$retry_file" \
    && ok "重试完成。" \
    || warn "仍有失败,查看日志: ~/.local/state/dotfiles-install-logs/"
}

cmd_reset() {
  hr
  title "🔄 重置 chezmoi 配置(下次会重问 5 题)"
  hr
  local toml="$HOME/.config/chezmoi/chezmoi.toml"
  if [ -f "$toml" ]; then
    mv "$toml" "${toml}.bak.$(date +%Y%m%d_%H%M%S)"
    ok "已备份并清除 $toml，下次运行会重新问 5 题。"
  else
    warn "$toml 不存在,无需清理。"
  fi
}

cmd_apply() {
  hr
  title "⚙️ 只跑 chezmoi apply（同步配置改动）"
  hr
  chezmoi apply --force
  ok "chezmoi apply 完成。"
}

cmd_install() {
  hr
  title "📦 只跑装软件的 90 脚本"
  hr
  local sw="${HOME}/.local/share/chezmoi/run_once_after_90_install_brew_bundle.sh"
  [ -f "$sw" ] || { err "找不到 90 脚本 $sw,请先跑完整 bootstrap"; exit 1; }
  bash "$sw"
}

cmd_wizard() {
  hr
  title "🖱️ 启动图形向导手动勾选软件"
  hr
  WIZARD=1 chezmoi apply --force
}

show_completion_banner() {
  echo ""
  hr
  title "🎉 六幕演出完成！Mac 已从裸机变成你的顶级工作站。"
  hr
  echo ""
  echo "${C_BOLD}📋 完整待办清单已生成：${C_RESET}"
  echo ""
  echo "  📄 ${C_BOLD}~/装机待办.md${C_RESET}"
  echo "  📄 ${C_BOLD}~/Desktop/装机待办.md${C_RESET}  (桌面副本,双击 Obsidian/编辑器打开)"
  echo ""
  echo "${C_YELLOW}${C_BOLD}⚡ 装完必做（3 分钟搞定）${C_RESET}"
  echo ""
  echo "  ${C_BOLD}① 立即重启一次电脑${C_RESET}"
  echo "     触控板灵敏度、听写关闭、三指拖移、电源策略——都需要重启才 100% 生效。"
  echo ""
  echo "  ${C_BOLD}② 启用微信输入法（30 秒）${C_RESET}"
  echo "     · 打开 WeType（Launchpad 找 or \`open -a WeType\`）"
  echo "     · 系统设置 → 键盘 → 输入法 → 编辑 → 加号 → 简体中文 → 微信输入法"
  echo "     · WeType 偏好里勾：中英文切换键=Shift、Caps Lock=直接大写、开机启动"
  echo ""
  echo "  ${C_BOLD}③ 授予辅助权限${C_RESET}"
  echo "     系统设置 → 隐私与安全性 → 辅助功能 → 勾选 Raycast、Loop"
  echo ""
  echo "${C_DIM}详细待办、其他可选项、故障排查见 ~/装机待办.md${C_RESET}"
  echo ""
  if [ -s "$HOME/.local/state/dotfiles-install-logs/last_failed.Brewfile" ]; then
    echo "${C_YELLOW}⚠️ 本次有软件未装成功，一键重试：${C_RESET}"
    echo "     curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/${DOTFILES_SLUG%/*}/dotfiles-bootstrap/main/bootstrap.sh | bash -s retry"
    echo "     或直接: HOMEBREW_ARTIFACT_DOMAIN=https://gh-proxy.com brew bundle --file=~/.local/state/dotfiles-install-logs/last_failed.Brewfile"
    echo ""
  fi
  echo "${C_DIM}其他子命令: reset(重问 5 题) / apply(同步配置) / install(只装软件) / wizard(图形勾选) / help${C_RESET}"
  hr

  # 收尾：结束 sudo keepalive
  [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
}

# 入口分发
case "${1:-}" in
  help|-h|--help) show_help ;;
  retry)          cmd_retry ;;
  reset)          cmd_reset ;;
  apply)          cmd_apply ;;
  install)        cmd_install ;;
  wizard)         cmd_wizard ;;
  ""|main)        main ;;
  *)              echo "未知子命令: $1"; show_help; exit 1 ;;
esac
