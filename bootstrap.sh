#!/bin/bash
# =============================================================================
# Mac 一行装机脚本 · vault 版
# 一行命令: bash -c "$(curl -fsSL <URL>)"
#
# 设计原则(照抄 rustup / Homebrew / starship 三个业界标杆):
#   1. 输出只有 4 个函数: info / warn / error / ok，前缀式，无 banner 无大框
#   2. 依赖检查用 need_cmd / check_cmd / ensure 三件套 (rustup 模式)
#   3. NONINTERACTIVE 三触发: 环境变量 / CI / stdin 非 TTY 任一即非交互
#   4. confirm 从 /dev/tty 读，绕开 curl | bash 的 stdin 冲突 (starship 模式)
#   5. sudo 一次拿到位，后续 sudo -n 静默使用
#   6. 临时目录 mktemp + trap EXIT 清理
#   7. 追加 rc 用 grep -Fqs 保护 (thoughtbot 模式)
#   8. 用户扩展点: ~/.bootstrap.local (thoughtbot 模式)
#   9. 子命令: install(默认) / retry / reset / apply / help
#  10. 每个函数 <30 行,可读性 > 花哨
# =============================================================================

set -eu

# ─── 常量 ───────────────────────────────────────────────────────────────
DOTFILES_SLUG="${DOTFILES_SLUG:-Zpwww/dotfiles}"
GITHUB_USERNAME="${GITHUB_USERNAME:-Zpwww}"
BOOTSTRAP_RAW_BASE="${BOOTSTRAP_RAW_BASE:-https://raw.githubusercontent.com/Zpwww/dotfiles-bootstrap/main}"
VAULT_URL="${VAULT_URL:-https://gh-proxy.com/${BOOTSTRAP_RAW_BASE}/bootstrap.vault.age}"
LOCAL_HOOK="$HOME/.bootstrap.local"

# 国内镜像 (bootstrap 整个进程生命周期都用)
export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.ustc.edu.cn/brew.git"
export HOMEBREW_CORE_GIT_REMOTE="https://mirrors.ustc.edu.cn/homebrew-core.git"
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

# ─── 输出层: 只有 4 个函数,前缀式,自动降级无色 (starship 风格) ────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
    C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
    C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_DIM=''; C_RESET=''
fi

info()  { printf '%s>%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
warn()  { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%sx%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
ok()    { printf '%s✓%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
hint()  { printf '%s  %s%s\n' "$C_DIM"    "$*"       "$C_RESET"; }

# ─── 命令三件套 (rustup 风格) ────────────────────────────────────────────
check_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd()  { check_cmd "$1" || { error "需要 '$1' 但未找到"; exit 1; } }
ensure()    { "$@" || { error "命令失败: $*"; exit 1; } }

# ─── 交互 (从 /dev/tty 读,绕开 curl|bash stdin 冲突) ─────────────────────
NONINTERACTIVE="${NONINTERACTIVE:-}"
if [ -n "${CI:-}" ] || [ ! -t 0 ] && [ ! -t 1 ]; then
    NONINTERACTIVE=1
fi

confirm() {
    # 用法: confirm "问题" [默认 y/n]  返回 0=yes / 1=no
    local prompt="$1" default="${2:-n}" reply
    if [ -n "$NONINTERACTIVE" ]; then
        [ "$default" = "y" ]; return $?
    fi
    printf '%s?%s %s [y/N]: ' "$C_YELLOW" "$C_RESET" "$prompt" >&2
    read -r reply </dev/tty || reply=""
    [ -z "$reply" ] && reply="$default"
    case "$reply" in Y|y|yes|Yes) return 0 ;; *) return 1 ;; esac
}

ask() {
    # 用法: ask "问题" [默认值]  返回值放到 REPLY
    local prompt="$1" default="${2:-}"
    if [ -n "$NONINTERACTIVE" ]; then
        REPLY="$default"; return
    fi
    if [ -n "$default" ]; then
        printf '%s?%s %s [%s]: ' "$C_YELLOW" "$C_RESET" "$prompt" "$default" >&2
    else
        printf '%s?%s %s: ' "$C_YELLOW" "$C_RESET" "$prompt" >&2
    fi
    read -r REPLY </dev/tty || REPLY=""
    [ -z "$REPLY" ] && REPLY="$default"
}

ask_choice() {
    # 用法: ask_choice "问题" "选项1" "选项2" ...  返回 1-based 索引到 REPLY
    local prompt="$1"; shift
    local -a opts=("$@")
    if [ -n "$NONINTERACTIVE" ]; then
        REPLY=1; return
    fi
    printf '%s?%s %s\n' "$C_YELLOW" "$C_RESET" "$prompt" >&2
    local i=1
    for opt in "${opts[@]}"; do
        printf '   [%d] %s\n' "$i" "$opt" >&2
        i=$((i+1))
    done
    while true; do
        printf '   请输入数字 (1-%d): ' "${#opts[@]}" >&2
        read -r REPLY </dev/tty || REPLY=""
        if [ -n "$REPLY" ] && [ "$REPLY" -ge 1 ] 2>/dev/null && [ "$REPLY" -le "${#opts[@]}" ]; then
            return
        fi
        warn "无效输入,请重试"
    done
}

# ─── 临时目录 ──────────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t bootstrap)"
_cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
    [ -n "${SUDO_PID:-}" ] && kill "$SUDO_PID" 2>/dev/null || true
}
trap _cleanup EXIT INT TERM

# ─── 权限 ──────────────────────────────────────────────────────────────
check_admin() {
    if ! id -Gn "$(whoami)" | tr ' ' '\n' | grep -qx "admin"; then
        error "当前用户 '$(whoami)' 不是管理员,无法继续"
        hint "请到 系统设置 → 用户与群组 → 允许此用户管理这台电脑"
        exit 1
    fi
}

acquire_sudo() {
    if sudo -n true 2>/dev/null; then
        ok "已有管理员权限"
        return
    fi
    info "需要管理员权限,请输入 Mac 开机密码 (仅此一次,后续操作自动免密):"
    ensure sudo -v
    ( set +e; while true; do sudo -n true 2>/dev/null || true; sleep 30; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_PID=$!
    ok "已获取管理员权限"
}

# ─── 依赖安装 ──────────────────────────────────────────────────────────
install_clt() {
    if xcode-select -p >/dev/null 2>&1; then
        ok "Xcode CLT 已就绪"
        return
    fi
    info "安装 Xcode Command Line Tools (会弹出系统窗口,请点【安装】)..."
    xcode-select --install >/dev/null 2>&1 || true
    until xcode-select -p >/dev/null 2>&1; do sleep 5; done
    ok "Xcode CLT 安装完成"
}

install_brew() {
    if check_cmd brew; then
        ok "Homebrew 已就绪"
    else
        info "通过中科大镜像安装 Homebrew..."
        ensure /bin/bash -c "$(curl -fsSL https://mirrors.ustc.edu.cn/misc/brew-install.sh)"
        ok "Homebrew 安装完成"
    fi
    if [ "$(uname -m)" = "arm64" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    else
        eval "$(/usr/local/bin/brew shellenv)"
    fi
}

install_core_tools() {
    local pkgs="age git chezmoi gh"
    local missing=""
    for p in $pkgs; do
        brew list "$p" >/dev/null 2>&1 || missing="$missing $p"
    done
    if [ -z "$missing" ]; then
        ok "核心工具已就绪 (age/git/chezmoi/gh)"
        return
    fi
    info "安装核心工具:$missing"
    for p in $missing; do
        ensure brew install "$p" >/dev/null
    done
    ok "核心工具安装完成"
}

persist_shellenv() {
    # 幂等追加到 zprofile (thoughtbot 模式)
    local zp="$HOME/.zprofile"
    local marker="# === Homebrew (bootstrap) ==="
    if ! grep -Fqs "$marker" "$zp" 2>/dev/null; then
        {
            echo ""
            echo "$marker"
            if [ "$(uname -m)" = "arm64" ]; then
                echo 'eval "$(/opt/homebrew/bin/brew shellenv)"'
            else
                echo 'eval "$(/usr/local/bin/brew shellenv)"'
            fi
            echo 'export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.ustc.edu.cn/brew.git"'
            echo 'export HOMEBREW_CORE_GIT_REMOTE="https://mirrors.ustc.edu.cn/homebrew-core.git"'
            echo 'export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"'
            echo 'export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"'
        } >> "$zp"
        ok "已把 brew 环境写入 ~/.zprofile"
    fi
}

# ─── vault 解密 ────────────────────────────────────────────────────────
decode_b64() {
    if base64 -D >/dev/null 2>&1 <<<""; then base64 -D
    else base64 -d
    fi
}

decrypt_vault() {
    local vault="$TMP_DIR/vault.age"
    local env_file="$TMP_DIR/vault.env"
    info "下载加密 vault..."
    ensure curl -fsSL "$VAULT_URL" -o "$vault"

    local attempt=0 max=3
    while [ $attempt -lt $max ]; do
        attempt=$((attempt + 1))
        if [ $attempt -eq 1 ]; then
            info "需要输入 vault 装机密码 (不是 Mac 开机密码, 最多 3 次机会):"
        fi
        if age -d "$vault" > "$env_file" 2>/dev/null; then
            break
        fi
        if [ $attempt -lt $max ]; then
            warn "vault 解密失败 ($attempt/$max),再试..."
        else
            error "vault 解密连续失败 3 次,退出"
            exit 1
        fi
    done

    set -a; . "$env_file"; set +a
    ok "vault 已解密"
}

install_age_key() {
    if [ -z "${AGE_IDENTITY_B64:-}" ]; then
        warn "vault 里没有 AGE_IDENTITY_B64,SSH 加密配置将无法解密"
        return
    fi
    ensure mkdir -p "$HOME/.config/chezmoi"
    printf "%s" "$AGE_IDENTITY_B64" | decode_b64 > "$HOME/.config/chezmoi/key.txt"
    ensure chmod 600 "$HOME/.config/chezmoi/key.txt"
    ok "已恢复 age 私钥"
}

install_github_creds() {
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        warn "vault 里没有 GITHUB_TOKEN,私有仓将拉不动"
        return
    fi
    git config --global credential.helper osxkeychain
    printf "protocol=https\nhost=github.com\nusername=%s\npassword=%s\n\n" \
        "$GITHUB_USERNAME" "$GITHUB_TOKEN" | git credential approve
    ok "GitHub 凭证已写入钥匙串"
}

# ─── 5 题选择 (可控回显,答完直接写 chezmoi.toml) ────────────────────────
ROLE_LABELS=("mobile — MacBook Air 移动机" \
             "studio — Mac Mini 大模型工作站" \
             "work   — MacBook Pro 公司主力")
ROLE_KEYS=("mobile" "studio" "work")

collect_answers() {
    local toml="$HOME/.config/chezmoi/chezmoi.toml"
    if [ -f "$toml" ] && grep -qE 'role[[:space:]]*=' "$toml" 2>/dev/null; then
        ok "已有配置,跳过选择题"
        return
    fi

    info "回答 5 个问题 (只问一次,答案存到 $toml)"
    echo ""

    ask_choice "① 机器角色?" "${ROLE_LABELS[@]}"
    local role_num="$REPLY"
    local role_str="${ROLE_KEYS[$((role_num - 1))]}"
    ok "已选: ${ROLE_LABELS[$((role_num - 1))]}"
    echo ""

    ask "② Git 用户名" "$GITHUB_USERNAME"
    local git_name="$REPLY"
    ok "已设: $git_name"
    echo ""

    ask "③ Git 邮箱 (回车跳过)" ""
    local git_email="$REPLY"
    [ -z "$git_email" ] && ok "已跳过邮箱" || ok "已设: $git_email"
    echo ""

    local sync_starship="true"
    if ! confirm "④ 同步 starship 终端样式?" "y"; then
        sync_starship="false"
    fi
    ok "starship 同步: $sync_starship"
    echo ""

    local ssh_default="n"
    [ -f "$HOME/.config/chezmoi/key.txt" ] && ssh_default="y"
    local sync_ssh="false"
    if confirm "⑤ 同步 SSH 配置? (需 age 私钥)" "$ssh_default"; then
        sync_ssh="true"
    fi
    ok "SSH 同步: $sync_ssh"
    echo ""

    write_chezmoi_toml "$role_num" "$role_str" "$git_name" "$git_email" "$sync_starship" "$sync_ssh"
}

write_chezmoi_toml() {
    local role_num="$1" role_str="$2" git_name="$3" git_email="$4"
    local sync_starship="$5" sync_ssh="$6"
    local brew_prefix="/opt/homebrew"
    [ "$(uname -m)" != "arm64" ] && brew_prefix="/usr/local"

    # 转义引号,避免用户输入含 " 导致 TOML 破坏
    git_name="${git_name//\"/}"
    git_email="${git_email//\"/}"

    local is_mobile=false is_studio=false is_work=false
    local is_heavy=false needs_enterprise=false is_always_on=false
    case "$role_str" in
        mobile) is_mobile=true ;;
        studio) is_studio=true; is_heavy=true; is_always_on=true ;;
        work)   is_work=true;   is_heavy=true; needs_enterprise=true ;;
    esac

    ensure mkdir -p "$HOME/.config/chezmoi"
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
    ok "已生成 $HOME/.config/chezmoi/chezmoi.toml"
}

# ─── chezmoi 应用 ──────────────────────────────────────────────────────
apply_dotfiles() {
    local src="$HOME/.local/share/chezmoi"
    local base_url="https://github.com/${DOTFILES_SLUG}.git"

    # 决定用哪个 URL clone/fetch: 加速站优先, 直连兜底
    # 原因: 国内直连 ls-remote 常常能通(几百字节握手),但真 clone 传到中间会被 GFW 断连,
    # 造成'error: RPC failed; curl 56 Recv failure: Connection reset by peer'。
    # 加速站是 CDN, 稳定得多。
    local resolved_url=""
    for accel in "https://gh-proxy.com/" "https://ghproxy.net/" "https://github.akams.cn/" ""; do
        local try_url="${accel}${base_url}"
        if GIT_TERMINAL_PROMPT=0 git \
             -c http.lowSpeedLimit=10000 -c http.lowSpeedTime=8 \
             ls-remote "$try_url" HEAD >/dev/null 2>&1; then
            resolved_url="$try_url"
            if [ -n "$accel" ]; then
                info "使用加速站: ${accel%/}"
            else
                info "使用 GitHub 直连"
            fi
            break
        fi
    done
    [ -z "$resolved_url" ] && resolved_url="$base_url"  # 全挂时仍用直连兜底

    # 情况 A: 已 clone 过 → git fetch + reset 拉最新
    if [ -d "$src/.git" ] && [ ! -L "$src" ]; then
        info "更新 dotfiles 源码..."
        local orig_remote; orig_remote="$(git -C "$src" remote get-url origin 2>/dev/null || echo "$base_url")"
        git -C "$src" remote set-url origin "$resolved_url" 2>/dev/null || true
        if GIT_TERMINAL_PROMPT=0 git -C "$src" \
             -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 \
             fetch origin main >/dev/null 2>&1; then
            git -C "$src" reset --hard FETCH_HEAD >/dev/null 2>&1 && ok "源码已更新" \
                || warn "源码重置失败,用本机版继续"
        else
            warn "源码更新失败,用本机版继续"
        fi
        git -C "$src" remote set-url origin "$orig_remote" 2>/dev/null || true
        info "应用 dotfiles..."
        ensure chezmoi apply --force
    else
        # 情况 B: 首次 clone → 用探测到的加速 URL
        info "首次 clone dotfiles..."
        ensure chezmoi init --apply --guess-repo-url=false --force "$resolved_url"
    fi

    ok "dotfiles 已应用"
}

# ─── 用户扩展 hook (thoughtbot 模式) ────────────────────────────────────
run_local_hook() {
    if [ -x "$LOCAL_HOOK" ]; then
        info "执行本地扩展: $LOCAL_HOOK"
        ensure "$LOCAL_HOOK"
    elif [ -f "$LOCAL_HOOK" ]; then
        info "执行本地扩展: $LOCAL_HOOK"
        ensure bash "$LOCAL_HOOK"
    fi
}

# ─── 收尾 (MECE: 只讲状态和 next-step 入口,详情在桌面文件夹) ─────────
show_finish() {
    local setup_dir="$HOME/Desktop/🍉 Mac 装机"
    local retry="$HOME/.local/state/dotfiles-install-logs/last_failed.Brewfile"

    echo ""
    if [ -s "$retry" ]; then
        local n; n=$(wc -l < "$retry" | tr -d ' ')
        warn "装机完成,但 $n 个软件未装成功"
        hint "  重试: bash bootstrap.sh retry"
    else
        ok "装机完成 ✨"
    fi
    hint "  下一步: 打开桌面「🍉 Mac 装机」文件夹,按 01→05 顺序完成"
    echo ""
}

# ─── 命令入口 ───────────────────────────────────────────────────────────
cmd_install() {
    check_admin
    acquire_sudo
    install_clt
    install_brew
    install_core_tools
    persist_shellenv
    decrypt_vault
    install_age_key
    install_github_creds
    collect_answers
    apply_dotfiles
    run_local_hook
    show_finish
}

cmd_retry() {
    local retry="$HOME/.local/state/dotfiles-install-logs/last_failed.Brewfile"
    if [ ! -s "$retry" ]; then
        ok "没有需要重试的软件"
        return
    fi
    need_cmd brew
    check_admin
    acquire_sudo
    info "重试失败清单: $retry"
    HOMEBREW_ARTIFACT_DOMAIN="https://gh-proxy.com" brew bundle --file="$retry"
}

cmd_reset() {
    local toml="$HOME/.config/chezmoi/chezmoi.toml"
    if [ -f "$toml" ]; then
        local backup="$toml.bak.$(basename "$TMP_DIR")"
        mv "$toml" "$backup"
        ok "已备份并清除配置到 $backup"
        info "下次运行会重问 5 题"
    else
        ok "配置不存在,无需重置"
    fi
}

cmd_apply() {
    need_cmd chezmoi
    check_admin
    acquire_sudo
    ensure chezmoi apply --force
    ok "chezmoi apply 完成"
}

show_help() {
    cat <<EOF
Mac 一行装机脚本 · vault 版

用法:
  bash bootstrap.sh [命令]

命令:
  install    完整装机流程 (默认)
  retry      只重试上次失败的软件
  reset      清除配置,下次重新问 5 题
  apply      只跑 chezmoi apply (同步配置改动)
  help       显示本帮助

环境变量:
  NONINTERACTIVE=1   非交互模式,全用默认值
  NO_COLOR=1         禁用彩色输出

用户扩展:
  ~/.bootstrap.local 若存在,主流程末尾会执行 (适合公司特殊配置)

一行命令:
  bash -c "\$(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/Zpwww/dotfiles-bootstrap/main/bootstrap.sh)"
EOF
}

# ─── 入口分发 ─────────────────────────────────────────────────────────
main() {
    local cmd="${1:-install}"
    case "$cmd" in
        install)         cmd_install ;;
        retry)           cmd_retry ;;
        reset)           cmd_reset ;;
        apply)           cmd_apply ;;
        help|-h|--help)  show_help ;;
        *) error "未知命令: $cmd"; show_help; exit 1 ;;
    esac
}

main "$@"
