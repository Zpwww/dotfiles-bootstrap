# dotfiles-bootstrap

公开的一行装机入口仓库。真正的 dotfiles 仓库 `Zpwww/dotfiles` 保持私有。

## 用户路径

```bash
bash -c "$(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/Zpwww/dotfiles-bootstrap/main/bootstrap.sh)"
```

然后输入 vault 密码。脚本会自动：

1. 安装/确认 CLT、Homebrew、age、git、chezmoi、gh；
2. 下载并解密 `bootstrap.vault.age`；
3. 恢复 age 私钥到 `~/.config/chezmoi/key.txt`；
4. 把 GitHub token 写入 macOS 钥匙串；
5. 拉取私有仓 `Zpwww/dotfiles` 并执行 `chezmoi init --apply`。

## 生成 vault

在可信任的主力 Mac 上运行：

```bash
./create_vault.sh
```

脚本会读取本机：

```text
~/.config/chezmoi/key.txt
```

并要求输入 GitHub fine-grained token：

- Repository access：只给 `Zpwww/dotfiles`
- Permissions：`Contents = Read-only`
- 有效期：建议 90/180 天，不要永久

生成：

```text
bootstrap.vault.age
```

把 `bootstrap.sh`、`bootstrap.vault.age`、`README.md` 推到公开仓即可。

## 密码要求

不要用弱密码。`bootstrap.vault.age` 里会包含 GitHub token 和 age 私钥，公开存储时安全性完全依赖 vault 密码强度。

`1qaz@WSX` 只能用于临时本地测试，不能长期公开使用。
