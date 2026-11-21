# V2CC Mac mini 标准部署

在一台 Apple Silicon Mac 上，为一个独立的管理员账户（例如 `v2cc`）一次性装好
Xcode Command Line Tools、Determinate Nix、Homebrew、nix-darwin 系统配置和
Claude Code。本机其他账户已有的 Nix / Home Manager 配置不会被改动。

## 一条命令部署

1. 机主在「系统设置 > 用户与群组」里新建一个管理员账户（例如 `v2cc`），并登录该账户。
2. V2CC 运营方在自己已登录 GitHub 的电脑上生成入口命令：

   ```sh
   tools/make-entry-command.sh            # 部署 main
   tools/make-entry-command.sh --dry-run  # 只检查、不改动的演练命令
   ```

3. 把输出的那一整行发给机主，在新账户的「终端」里粘贴运行。

这一行命令会下载部署包、校验 SHA-256、解压到 `~/v2cc-mac-setup`，然后运行
`bootstrap.sh`，依次完成：

| 步骤 | 内容 | 已具备时 |
| --- | --- | --- |
| 1 | 检查机型、系统版本、管理员身份、磁盘空间 | 不满足则停止 |
| 2 | Xcode Command Line Tools | 跳过 |
| 3 | Determinate Nix（固定版本，校验 SHA-256） | 跳过 |
| 4 | Homebrew（固定版本的官方安装脚本，校验 SHA-256） | 跳过 |
| 5 | 构建系统配置、检查不影响现有账户、切换 | 已是当前系统则跳过 |
| 6 | Claude Code（官方安装脚本） | 跳过 |
| 7 | 部署后验证，包括检查没有遗留 GitHub 凭据 | 每次都做 |

需要人工参与的只有 macOS 自身要求的环节：输入当前账户的登录密码（管理员授权，
可能不止一次），以及在本机已有 nix-darwin 系统时确认一次整机切换。这不是完全
无人值守的安装。

任何一步失败后，修复原因再运行同一条命令（或 `~/v2cc-mac-setup/bootstrap.sh`）
即可，已完成的步骤会被跳过。入口命令里的下载链接约 5 分钟后失效，过期后需要
运营方重新生成；`~/v2cc-mac-setup/bootstrap.sh` 不需要链接，可随时重跑。

## 多账户共存

nix-darwin 的系统配置是整机唯一的一份，不属于某个账户。如果新配置只声明了
正在部署的账户，切换后其他账户的 Home Manager 配置就不再受管理。因此：

- `prepare.sh` 根据正在运行的系统生成 `machine.nix`：受管理的账户 = 当前系统
  已管理的账户 + 正在部署的账户，只增不减。
- `system.primaryUser` 只能是一个账户。它是 nix-darwin 的过渡选项，决定
  Homebrew、用户级默认设置和 launchd 用户服务归谁，不是"受管理账户的列表"。
  本机已有系统时沿用原值，否则取正在部署的账户。
- `homebrew.user` 取 `/opt/homebrew` 的实际属主。
- `deploy.sh` 在切换前把新配置和正在运行的系统逐项比较，只允许"增加"：

  | 情况 | 处理 |
  | --- | --- |
  | 主用户改变、某个账户不再被管理、账户的软件包环境、launchd 服务或系统命令减少 | 一律拒绝 |
  | 某个账户的 Home Manager 配置内容改变、当前系统闭包里的任何内容被移除或改变、激活步骤有任何一行被移除或改变 | 默认拒绝；整机有意升级时用 `V2CC_ALLOW_SYSTEM_CHANGES=1` 放行 |

  被拒绝时系统没有任何改动，诊断信息写入
  `~/.local/state/v2cc/guard-report.txt`，发给运营方即可。

如果机主有自己的 nix-darwin 配置（不是本仓库生成的），部署会在这一步被拒绝。
本仓库不会用标准配置替换机主的配置。

## 常用命令

在 `~/v2cc-mac-setup` 目录下：

```sh
./bootstrap.sh --dry-run   # 演练：只报告将要做什么
./bootstrap.sh             # 检查、安装缺失项、部署、验证
./verify.sh                # 只做部署后验证（只读）
./verify.sh --credentials  # 只检查是否遗留 GitHub 凭据
./rollback.sh              # 回退到上次部署之前的系统配置
./rollback.sh --list       # 查看系统配置的历史版本
```

| 环境变量 | 作用 |
| --- | --- |
| `V2CC_DRY_RUN=1` | 同 `--dry-run` |
| `V2CC_ASSUME_YES=1` | 对脚本自己的确认问题回答"是"。不能跳过 macOS 的授权，也不能跳过任何安全拦截 |
| `V2CC_ALLOW_SYSTEM_CHANGES=1` | 允许改变（但不允许移除）现有账户和系统内容，用于整机有意升级 |

## 失败与回退

- 激活失败且本机此前有系统配置：`deploy.sh` 自动把系统配置指回原版本并重新
  激活它，然后以失败退出。
- 部署成功后想撤销：`./rollback.sh`。它重新激活上次部署前的系统配置，不删除
  任何账户主目录里的文件。
- 首次部署失败：此前没有系统配置可回退，修复原因后重跑即可。
- 彻底移除 Nix：`/nix/nix-installer uninstall`（Determinate Nix 自带）。

## 凭据

客户账户上不需要、也不应留下任何 GitHub 凭据：

- 运营方的 GitHub 令牌只在运营方的电脑上使用，用来向 GitHub 换取一个约 5 分钟
  有效、只能下载这一个部署包的链接。
- 部署包不含 `.git`，没有远程地址，也不调用 `git` 或 `gh` 登录。
- `verify.sh` 会检查 Git 配置、`~/.git-credentials`、`~/.netrc`、GitHub CLI
  登录信息、命令历史、shell 启动文件、部署目录、环境变量和登录钥匙串；发现时
  只报告位置，不输出凭据内容。

命令历史里会留下已失效的下载链接，它不能再下载任何内容。

## 开发与测试

```sh
tests/run.sh        # 桩测试：全新机器、部分安装、失败重跑、机主共存、回退、凭据、入口命令
tests/closures.sh   # 用真实构建的 nix-darwin 闭包检验共存检查（只构建，不激活）
shellcheck -x *.sh lib/*.sh tools/*.sh tests/*.sh
```

脚本必须兼容 macOS 自带的 `/bin/bash` 3.2（空白机器上只有它）。变量后面紧跟中文
时要写成 `${var}`，否则 bash 3.2 会把中文的首字节当成变量名的一部分。

真实机器上的验收步骤见 [docs/test-plan.md](docs/test-plan.md)。
