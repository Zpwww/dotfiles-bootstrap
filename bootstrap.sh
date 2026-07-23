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
    C_GREEN=$'[38;2;0;158;115m'; C_YELLOW=$'[38;2;230;159;0m'; C_RED=$'[38;2;213;94;0m'
    C_BLUE=$'[38;2;86;180;233m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_DIM=''; C_BOLD=''; C_RESET=''
fi

info()    { printf '%s>%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
warn()    { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error()   { printf '%sx%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }
ok()      { printf '%s✓%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
hint()    { printf '%s  %s%s\n' "$C_DIM"    "$*"       "$C_RESET"; }
# action: 醒目 CTA(黄底加粗),用于"你下一步该做什么"
action()  { printf '%s→%s %s%s%s\n' "$C_YELLOW" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
# stage: 顶层阶段标题(4 大步),编号 + 标题 + 简介, 全屏最醒目
# 格式:
#   ┌──────────────────────────────────────────
#   │  [N/4]  阶段标题
#   │         简介文字
#   └──────────────────────────────────────────
stage() {
    local num="$1" title="$2" desc="$3"
    echo ""
    printf '%s┌─────────────────────────────────────────────%s\n' "$C_BOLD$C_BLUE" "$C_RESET"
    printf '%s│  [%s]  %s%s\n' "$C_BOLD$C_BLUE" "$num" "$title" "$C_RESET"
    [ -n "$desc" ] && printf '%s│  %s%s%s\n' "$C_BOLD$C_BLUE" "$C_DIM$C_RESET" "$desc" "$C_RESET"
    printf '%s└─────────────────────────────────────────────%s\n' "$C_BOLD$C_BLUE" "$C_RESET"
}
# section: 阶段内的子模块标题(比 stage 轻一档)
section() { printf '\n%s▸ %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }

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
    local hint="[y/N]"
    [ "$default" = "y" ] && hint="[Y/n]"
    printf '%s?%s %s %s: ' "$C_YELLOW" "$C_RESET" "$prompt" "$hint" >&2
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

curl_with_spinner() {
    local tmp_err; tmp_err="$(mktemp -t curl_err.XXXXXX)"
    "$@" 2> "$tmp_err" &
    local pid=$!
    local spin='-\|/'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r%s> 正在下载 [%c]%s" "$C_BLUE" "${spin:$i:1}" "$C_RESET" >&2
        sleep 0.1
    done
    wait $pid
    local rc=$?
    printf "\r\033[K" >&2
    if [ $rc -ne 0 ] && [ -s "$tmp_err" ]; then
        cat "$tmp_err" >&2
    fi
    rm -f "$tmp_err"
    return $rc
}

# ─── 临时目录 ──────────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t bootstrap)"
_cleanup() {
    sudo rm -f "/private/etc/sudoers.d/dotfiles-bootstrap-global" 2>/dev/null || true
    rm -rf "$TMP_DIR" 2>/dev/null || true
    [ -n "${SUDO_PID:-}" ] && kill "$SUDO_PID" 2>/dev/null || true
}
trap '_cleanup; exit 130' INT TERM
trap _cleanup EXIT

# ─── 权限 ──────────────────────────────────────────────────────────────
check_admin() {
    if ! id -Gn "$(whoami)" | tr ' ' '\n' | grep -qx "admin"; then
        error "当前用户 '$(whoami)' 不是管理员,无法继续"
        hint "请到 系统设置 → 用户与群组 → 允许此用户管理这台电脑"
        exit 1
    fi
}

acquire_sudo() {
    if ! sudo -n true 2>/dev/null; then
        info "需要管理员权限,请输入 Mac 开机密码 (仅此一次,后续操作自动免密):"
        ensure sudo -v
    fi
    
    # 注入全局临时免密规则，彻底绕过 macOS tty_tickets 导致子进程要密码的问题
    local user
    user="$(id -un)"
    local sudoers_file="/private/etc/sudoers.d/dotfiles-bootstrap-global"
    if [ ! -f "$sudoers_file" ]; then
        local tmp_sudoers
        tmp_sudoers="$(mktemp)"
        echo "$user ALL=(ALL) NOPASSWD: ALL" > "$tmp_sudoers"
        if sudo visudo -cf "$tmp_sudoers" >/dev/null 2>&1; then
            sudo cp "$tmp_sudoers" "$sudoers_file"
            sudo chown root:wheel "$sudoers_file"
            sudo chmod 440 "$sudoers_file"
        fi
        rm -f "$tmp_sudoers"
    fi
    
    ( set +e; while true; do sudo -n -v 2>/dev/null || true; sleep 30; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_PID=$!
    ok "已获取管理员免密权限"
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

    info "回答 7 个问题 (只问一次,答案存到 $toml)"
    echo ""

    ask_choice "你想如何配置这台机器?" "完整装机(全新电脑)" "仅对齐配置(旧电脑)"
    local install_mode="$REPLY"
    [ "$install_mode" = "1" ] && ok "已选: 完整装机" || ok "已选: 仅对齐配置"
    echo ""

    local role_num=3
    local role_str="work"
    if [ "$install_mode" = "1" ]; then
        ask_choice "机器角色?" "${ROLE_LABELS[@]}"
        role_num="$REPLY"
        role_str="${ROLE_KEYS[$((role_num - 1))]}"
        ok "已选: ${ROLE_LABELS[$((role_num - 1))]}"
        echo ""
    fi

    local ioa_default="y"
    local needs_intranet="false"
    if confirm "是否需要配置腾讯办公内网(iOA, WeTERM 等)?" "$ioa_default"; then
        needs_intranet="true"
    fi
    ok "腾讯内网: $needs_intranet"
    echo ""

    ask "Git 用户名 (回车默认 $GITHUB_USERNAME)" ""
    local git_name="$REPLY"
    [ -z "$git_name" ] && git_name="$GITHUB_USERNAME"
    ok "已设: $git_name"
    echo ""

    ask "Git 邮箱 (回车跳过)" ""
    local git_email="$REPLY"
    [ -z "$git_email" ] && ok "已跳过邮箱" || ok "已设: $git_email"
    echo ""

    local sync_starship="true"
    if ! confirm "同步 starship 终端样式?" "y"; then
        sync_starship="false"
    fi
    ok "starship 同步: $sync_starship"
    echo ""

    local ssh_default="n"
    [ -f "$HOME/.config/chezmoi/key.txt" ] && ssh_default="y"
    local sync_ssh="false"
    if confirm "同步 SSH 配置? (需 age 私钥)" "$ssh_default"; then
        sync_ssh="true"
    fi
    ok "SSH 同步: $sync_ssh"
    echo ""

    ANS_ROLE_NUM="$role_num"
    ANS_ROLE_STR="$role_str"
    ANS_INSTALL_MODE="$install_mode"
    ANS_NEEDS_INTRANET="$needs_intranet"
    ANS_GIT_NAME="$git_name"
    ANS_GIT_EMAIL="$git_email"
    ANS_SYNC_STARSHIP="$sync_starship"
    ANS_SYNC_SSH="$sync_ssh"
    ANS_COLLECTED="true"
}

write_chezmoi_toml() {
    local role_num="$1" role_str="$2" install_mode="$3" needs_intranet="$4"
    local git_name="$5" git_email="$6" sync_starship="$7" sync_ssh="$8"
    local brew_prefix="/opt/homebrew"
    [ "$(uname -m)" != "arm64" ] && brew_prefix="/usr/local"

    # 转义引号,避免用户输入含 " 导致 TOML 破坏
    git_name="${git_name//\"/}"
    git_email="${git_email//\"/}"

    local run_install_pipeline="false"
    [ "$install_mode" = "1" ] && run_install_pipeline="true"

    local is_mobile=false is_studio=false is_work=false
    local is_heavy=false is_always_on=false
    case "$role_str" in
        mobile) is_mobile=true ;;
        studio) is_studio=true; is_heavy=true; is_always_on=true ;;
        work)   is_work=true;   is_heavy=true ;;
    esac

    ensure mkdir -p "$HOME/.config/chezmoi"
    cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
encryption = "age"

[age]
identity = "~/.config/chezmoi/key.txt"
recipient = "age1gu9dhr2az6ndjxdy00rf29r2aqaw9skm8683n0ds08mzlqv9p3gq8u7wts"

[data]
roleNum = $role_num
installMode = $install_mode
needsTencentIntranet = $needs_intranet
role = "$role_str"
name = "$git_name"
email = "$git_email"
syncStarship = $sync_starship
syncSshConfig = $sync_ssh
brewPrefix = "$brew_prefix"
tabbyToken = "${TABBY_TOKEN:-}"
proxyClashUrl = "${PROXY_CLASH_URL:-}"
proxyShadowrocketUrl = "${PROXY_SHADOWROCKET_URL:-}"

[data.roleFlags]
runInstallPipeline = $run_install_pipeline
needsTencentIntranet = $needs_intranet
isMobile = $is_mobile
isStudio = $is_studio
isWork = $is_work
isHeavy = $is_heavy
needsEnterprise = $needs_intranet
isAlwaysOn = $is_always_on
EOF
    ok "已生成 $HOME/.config/chezmoi/chezmoi.toml"
}

# ─── chezmoi 应用 ──────────────────────────────────────────────────────
# fetch_source: 依次尝试 3 种获取方式,首个成功即返回。
#   API tarball 端点 (api.github.com/repos/.../tarball) — 对 fine-grained
#      token 支持最全, 走 302 重定向, curl -L 自动跟。
#   archive 端点 (github.com/.../archive/refs/heads/main.tar.gz) — 部分
#      fine-grained token 权限不匹配会 404, 兜底方案。
#   git clone HTTPS + token 嵌入 URL — 最原始的方式, chezmoi 也这么做。
fetch_source() {
    local dst="$1"
    local api_url="https://api.github.com/repos/${DOTFILES_SLUG}/tarball/main"
    local archive_url="https://github.com/${DOTFILES_SLUG}/archive/refs/heads/main.tar.gz"

    if [ -z "${GITHUB_TOKEN:-}" ]; then
        warn "GITHUB_TOKEN 不存在,只能尝试公开仓路径"
    fi

    # ─── 方式 : API tarball (推荐,对 fine-grained token 最友好) ───
    info "尝试 API tarball 端点 (60s 超时)..."
    local tmp_tar; tmp_tar="$(mktemp -t chezmoi_src.tar.gz.XXXXXX)"
    local rc=0
    # --max-time 60 是硬顶: 无论连不上/连上不返回/半速传/DNS 挂, 60s 必退
    # -sS 显示进度条, 让用户能看到是"在传"还是"卡死"
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl_with_spinner curl -fL --connect-timeout 10 --max-time 60 --speed-limit 10240 --speed-time 15 -sS \
             -H "Authorization: Bearer $GITHUB_TOKEN" \
             -H "Accept: application/vnd.github+json" \
             -H "X-GitHub-Api-Version: 2022-11-28" \
             -o "$tmp_tar" "$api_url" || rc=$?
    else
        curl_with_spinner curl -fL --connect-timeout 10 --max-time 60 --speed-limit 10240 --speed-time 15 -sS \
             -o "$tmp_tar" "$api_url" || rc=$?
    fi
    if [ "$rc" -eq 0 ] && [ -s "$tmp_tar" ] && tar -tzf "$tmp_tar" >/dev/null 2>&1; then
        rm -rf "$dst" 2>/dev/null; mkdir -p "$dst"
        if tar -xzf "$tmp_tar" -C "$dst" --strip-components=1; then
            rm -f "$tmp_tar"
            local size; size=$(du -sh "$dst" 2>/dev/null | awk '{print $1}')
            ok "源码已获取 via API tarball (${size:-?})"
            return 0
        fi
    fi
    rm -f "$tmp_tar"
    warn "API tarball 失败(rc=$rc),尝试 archive 端点..."

    # ─── 方式 : archive 端点 ───
    info "尝试 archive 端点 (60s 超时)..."
    tmp_tar="$(mktemp -t chezmoi_src.tar.gz.XXXXXX)"
    rc=0
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl_with_spinner curl -fL --connect-timeout 10 --max-time 60 --speed-limit 10240 --speed-time 15 -sS \
             -H "Authorization: Bearer $GITHUB_TOKEN" \
             -o "$tmp_tar" "$archive_url" || rc=$?
    else
        curl_with_spinner curl -fL --connect-timeout 10 --max-time 60 --speed-limit 10240 --speed-time 15 -sS \
             -o "$tmp_tar" "$archive_url" || rc=$?
    fi
    if [ "$rc" -eq 0 ] && [ -s "$tmp_tar" ] && tar -tzf "$tmp_tar" >/dev/null 2>&1; then
        rm -rf "$dst" 2>/dev/null; mkdir -p "$dst"
        if tar -xzf "$tmp_tar" -C "$dst" --strip-components=1; then
            rm -f "$tmp_tar"
            local size; size=$(du -sh "$dst" 2>/dev/null | awk '{print $1}')
            ok "源码已获取 via archive (${size:-?})"
            return 0
        fi
    fi
    rm -f "$tmp_tar"
    warn "archive 失败(rc=$rc),尝试 git clone..."

    # ─── 方式 : git clone with token in URL ───
    rm -rf "$dst" 2>/dev/null
    local clone_url="https://github.com/${DOTFILES_SLUG}.git"
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        clone_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${DOTFILES_SLUG}.git"
    fi
    info "尝试 git clone..."
    if GIT_TERMINAL_PROMPT=0 git \
         -c http.lowSpeedLimit=20480 -c http.lowSpeedTime=30 \
         clone --depth=1 "$clone_url" "$dst" 2>&1 | \
         grep -vE '^(Cloning|remote:|Receiving|Resolving)' || [ -d "$dst/.git" ]; then
        if [ -d "$dst/.git" ]; then
            local size; size=$(du -sh "$dst" 2>/dev/null | awk '{print $1}')
            ok "源码已获取 via git clone (${size:-?})"
            return 0
        fi
    fi

    return 1
}

apply_dotfiles() {
    local src="$HOME/.local/share/chezmoi"

    section "拉取 dotfiles 源码"
    if ! fetch_source "$src"; then
        error "所有加速站+直连全部失败,请换个网络重试"
        exit 1
    fi

    # 强制重置 run_once 状态 → 装软件/装插件/装配置脚本必重跑
    # 目的: 用户"重跑 bootstrap = 一切自愈", 无需手动 brew install / chezmoi state delete。
    # 场景: 上次装机中途中断 → brew 数据库半装状态 → 90 秒判"已装"跳过 → 用户永远装不上
    # 重置后 90 会重扫每个 cask, is_installed 用 Artifacts 校验补齐漏装。
    section "重置装机脚本状态 (确保'重跑=修复')"
    if [ -f "$HOME/.config/chezmoi/chezmoistate.boltdb" ]; then
        chezmoi state delete-bucket --bucket=scriptState >/dev/null 2>&1 || true
        ok "run_once 状态已清空,装机脚本将全部重跑"
    fi

    info "正在启动 chezmoi apply 引擎，进入装机流水线..."
    ensure chezmoi init --apply --guess-repo-url=false --force --source="$src"
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

# ─── 收尾 (金字塔: 状态概览 → 失败明细 → CTA) ─────────────────────────
show_finish() {
    local setup_dir="$HOME/Desktop/🍉 Mac 装机"
    local retry="$HOME/.local/state/dotfiles-install-logs/last_failed.Brewfile"

    # 一级: 状态概览
    if [ -s "$retry" ]; then
        local n; n=$(wc -l < "$retry" | tr -d ' ')
        warn "$n 个软件安装失败:"
        # 二级: 失败明细,直接列出让用户不用往上翻
        awk '{gsub(/"/,"",$2); printf "    %s✗%s %s %s(%s)%s\n", "'"$C_RED"'", "'"$C_RESET"'", $2, "'"$C_DIM"'", $1, "'"$C_RESET"'"}' "$retry"
    else
        ok "所有软件已装完 ✨"
    fi
    echo ""

    # 三级: CTA (只 2-3 条,按优先级排)
    if [ -s "$retry" ]; then
        action "重试失败软件: bash bootstrap.sh retry"
    fi
    action "打开桌面「🍉 Mac 装机」文件夹，按编号依次完成最后的配置"
    hint "  日志: ~/.local/state/dotfiles-install-logs/"
    echo ""
}

# ─── 命令入口 ───────────────────────────────────────────────────────────
cmd_install() {
    # 提前回答配置意图，提升用户体验 (让用户觉得是“先规划再执行”)
    collect_answers

    stage "1/4" "环境准备" "管理员权限 / Xcode CLT / Homebrew / 核心工具"
    check_admin
    acquire_sudo
    install_clt
    install_brew
    install_core_tools
    persist_shellenv

    stage "2/4" "身份与密钥" "解密 vault / age 私钥 / GitHub 凭证"
    decrypt_vault
    if [ "${ANS_COLLECTED:-false}" = "true" ]; then
        write_chezmoi_toml "$ANS_ROLE_NUM" "$ANS_ROLE_STR" "$ANS_INSTALL_MODE" "$ANS_NEEDS_INTRANET" "$ANS_GIT_NAME" "$ANS_GIT_EMAIL" "$ANS_SYNC_STARSHIP" "$ANS_SYNC_SSH"
    fi
    install_age_key
    install_github_creds

    stage "3/4" "装软件与配置" "拉源码 / brew 软件包 / VS Code 插件 / 个人偏好"
    apply_dotfiles
    run_local_hook

    stage "4/4" "装机完成" "查看状态与下一步"
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
