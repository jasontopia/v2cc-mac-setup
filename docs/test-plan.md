# 真实机器验收计划

桩测试和闭包测试证明了脚本的逻辑；下面这些只能在真实机器上证明。每一步写明
预期结果和停止条件。遇到停止条件就停下，把终端全部输出和
`~/.local/state/v2cc/guard-report.txt`（如果有）发给运营方，不要手工绕过。

系统切换需要单独批准。A1、B1 是演练，不改动系统，可以先做。

## A. 全新 Apple Silicon Mac mini

前提：刚完成 macOS 初始设置，只有机主账户，没有装过 Xcode CLT、Nix、Homebrew。

| # | 操作 | 预期结果 | 停止条件 |
| --- | --- | --- | --- |
| A0 | 机主新建管理员账户 `v2cc` 并登录 | 账户类型显示"管理员" | 无法设为管理员 |
| A1 | 运营方运行 `tools/make-entry-command.sh --dry-run`，机主在 `v2cc` 的终端粘贴运行 | 显示 `[1/7]` 通过；`[2/7]` 到 `[4/7]` 各显示一行"[演练] 将执行"；结尾"演练结束，系统没有任何改动" | 下载或完整性校验失败；`[1/7]` 报错 |
| A2 | 运营方运行 `tools/make-entry-command.sh`，机主粘贴运行 | 要求输入登录密码；依次安装 CLT、Determinate Nix、Homebrew，没有其他提问 | 任何安装器失败；出现密码以外的提问 |
| A3 | 观察 `[2/7]` | 通过 softwareupdate 安装，无弹窗；若它装不上，会弹出系统安装对话框，点"安装"后脚本自动继续 | 等待超过 60 分钟 |
| A4 | 观察 `[5/7]` | 显示"这是首次部署"，随后"系统配置已激活" | 出现 `Unexpected files in /etc`（见下） |
| A5 | 观察 `[7/7]` | 每项都是 ✓，结尾"验证通过"和"V2CC 部署完成" | 任何一项 ✗ |
| A6 | 重新打开终端，运行 `claude --version`、`git --version`、`node --version` | 都有版本号输出 | 命令找不到 |
| A7 | 运行 `~/v2cc-mac-setup/bootstrap.sh` | 七步全部显示"跳过"或"无需切换"；除验证外没有任何安装或切换；不要求输入密码 | 有任何重新安装或切换 |
| A8 | 重启，登录 `v2cc`，运行 `~/v2cc-mac-setup/verify.sh` | "验证通过" | 任何一项 ✗ |
| A9 | 登录机主账户，打开终端 | 终端正常，机主的文件和设置没有变化 | 终端报错或设置变化 |
| A10 | 在 `v2cc` 运行 `~/v2cc-mac-setup/verify.sh --credentials` | "未发现遗留的 GitHub 凭据" | 报告任何凭据 |

### 失败重跑（在 A2 过程中有意制造一次）

| # | 操作 | 预期结果 |
| --- | --- | --- |
| A11 | 在 Nix 安装过程中按 Ctrl-C，然后重新运行 `~/v2cc-mac-setup/bootstrap.sh` | 已装好的 CLT 被跳过；Nix 要么继续安装，要么提示"检测到不完整的 Nix 安装"并给出卸载命令，按提示处理后重跑成功 |
| A12 | 入口命令放置超过 6 分钟再粘贴 | "下载失败。链接约 5 分钟后失效"，`~/v2cc-mac-setup` 不变 |

### 已知的可能停止点

- `Unexpected files in /etc`：nix-darwin 只在 `/etc/zshrc`、`/etc/bashrc` 等文件
  是它认识的内容（macOS 原始内容或 Determinate 安装器改过的内容）时才接管。新的
  macOS 版本可能让这些文件变成它不认识的内容，这时它会在改动任何东西之前停止。
  需要运营方确认文件内容后再处理，脚本不会自动改名。
- Determinate Nix 安装器的 `install --no-confirm` 参数、Homebrew 安装脚本在
  `NONINTERACTIVE=1` 下复用已输入的管理员授权：两者都取自官方脚本的当前行为，
  尚未在真实空白机上跑过。

## B. 首台 Mac mini（机主 howard 已有系统配置）

前提：`howard`（501）和 `v2cc`（502）都是管理员；当前系统由本仓库以 `howard`
身份部署。

| # | 操作 | 预期结果 | 停止条件 |
| --- | --- | --- | --- |
| B1 | 在 `v2cc` 运行演练入口命令 | "受管理的账户：howard v2cc"；"主用户（system.primaryUser）：howard"；"已保留当前系统中已有的账户配置：howard"；"当前系统管理的账户、服务和命令在新配置中全部保留"；变化列表里只有 `activation-v2cc`、`hm_Usersv2cc.*`、`home-manager` 等新增项，没有任何 `howard` 相关的移除 | 出现任何 ✗（说明 howard 的配置不是本仓库这个版本生成的，见下） |
| B2 | 获得批准后，在 `v2cc` 运行正式入口命令，确认整机切换 | 输出中同时有 `Activating home-manager configuration for howard` 和 `... for v2cc`；"部署前已有的账户、服务和命令全部保留"；"验证通过" | 激活失败（会自动回退，回退后停止） |
| B3 | 登录 `howard`，打开新终端，运行 `which git node home-manager` 和 `ls -l ~/.local/state/home-manager/gcroots/current-home` | 命令都在；`current-home` 指向的路径与部署前相同 | 路径改变或命令缺失 |
| B4 | 在 `howard` 检查原有凭据：`gh auth status`、`ssh -T git@github.com`、`git config --global --list` | 与部署前一致 | 任何凭据丢失 |
| B5 | `howard` 未登录图形界面时（注销后）在 `v2cc` 重跑 `~/v2cc-mac-setup/bootstrap.sh` | "新配置已经是当前系统，无需切换" | 报错 |
| B6 | 在 `v2cc` 运行 `./rollback.sh`，确认 | "已回退到"部署前的系统路径；`howard` 一切如常 | 回退失败 |
| B7 | 重新运行 `./bootstrap.sh` | 再次部署成功，"验证通过" | 任何 ✗ |

### 如果 B1 被拒绝

说明这台机器当前的系统不是本仓库这个版本以 `howard` 身份生成的，例如 howard
用的是自己的配置或更早的 `flake.lock`。这时不能继续，需要机主决定
（见 PR 中的待定问题）。`~/.local/state/v2cc/guard-report.txt` 里有做决定所需的
全部信息：当前系统和新配置的路径与版本、各自的主用户和账户、拦截原因、完整的
闭包差异。

### 尚未在真实机器上验证

- 机主未登录图形界面时，nix-darwin 通过 `launchctl asuser` 为机主执行
  Home Manager 激活是否成功（B5 只在配置未变化时覆盖；B2 应在 howard 已登录和
  未登录两种状态下各做一次）。
- `/opt/homebrew` 属于 howard 时，`v2cc` 自己使用 `brew` 安装软件可能遇到权限
  问题。Homebrew 本身不支持多账户共用，部署只保证空的 Brewfile 以属主身份执行。
