# 真实机器验收计划

桩测试和闭包测试证明了脚本的逻辑；下面这些只能在真实机器上证明。每一步写明
预期结果和停止条件。遇到停止条件就停下，把终端全部输出和
`~/.local/state/v2cc/guard-report.txt`（如果有）发给运营方，不要手工绕过。

系统切换需要单独批准。A1、B1 是演练，不改动系统，可以先做。

**只在测试机上测**（Captain 之前测过的那台测试 Mac mini），不在任何已经交给客户、或客户正在使用的机器上测。从迁移的第 2 步（取消 `v2cc` 的管理员权限）起，测试机上的 `v2cc` 就是普通账户了。改动任何东西之前，先做好重要文件的备份（例如 Time Machine）。监测程序的实测在 E 节。

账户：`v2ccops` 是平台维护管理员（默认账户名，`--ops` 可改，待机主确认），系统部分、自动登录和回退都在它
里面运行；`v2cc` 是客户的普通账户（标准用户），客户账户部分在它里面运行；机主账户
不运行本仓库的脚本。各步骤写明在哪个账户里做。本计划里的步骤都没有按这个账户做法
在真机上做过。

## A. 全新 Apple Silicon Mac mini

前提：刚完成 macOS 初始设置，只有机主账户，没有装过 Xcode CLT、Nix、Homebrew。

| # | 操作 | 预期结果 | 停止条件 |
| --- | --- | --- | --- |
| A0 | 机主新建管理员账户 `v2ccops` 和普通账户 `v2cc`，登录 `v2ccops` | `v2ccops` 显示"管理员"，`v2cc` 显示"普通"；`id -Gn v2cc` 里没有 `admin` | 账户类型不对 |
| A1 | 运营方运行 `tools/make-entry-command.sh --customer v2cc --dry-run`，在 `v2ccops` 的终端粘贴运行 | 显示 `[1/7]` 通过（客户账户 `v2cc` 是普通账户）；`[2/7]` 到 `[4/7]` 各显示"[演练] 将执行"，`[4/7]` 还有"安装后将把 /opt/homebrew 交给客户账户 v2cc"；结尾"演练结束，系统没有任何改动" | 下载或完整性校验失败；`[1/7]` 报错 |
| A2 | 运营方运行 `tools/make-entry-command.sh --customer v2cc`，在 `v2ccops` 粘贴运行 | 要求输入 `v2ccops` 的登录密码；依次安装 CLT、Determinate Nix、Homebrew，没有其他提问 | 任何安装器失败；出现密码以外的提问 |
| A3 | 观察 `[2/7]` | 通过 softwareupdate 安装，无弹窗；若它装不上，会弹出系统安装对话框，点"安装"后脚本自动继续 | 等待超过 60 分钟 |
| A4 | 观察 `[4/7]` 和 `[5/7]` | "Homebrew 已交给客户账户 v2cc"；`ls -ld /opt/homebrew` 显示属主 `v2cc`、组 `staff`；"这是首次部署"，随后"系统配置已激活" | 交接失败；出现 `Unexpected files in /etc`（见下） |
| A5 | 观察 `[6/7]` 和 `[7/7]` | `[6/7]` 显示"监测程序已安装并启动"和"第一轮已完成"；`[7/7]` 每项都是 ✓（"上传目标没有配置"是提醒，不是失败），结尾"验证通过"和"V2CC 系统部分部署完成" | 任何一项 ✗ |
| A6 | 运营方运行 `tools/make-entry-command.sh --customer-setup`，登录 `v2cc`，在它的终端粘贴运行 | 不要求任何密码；装好 Claude Code；结尾"验证通过"和"V2CC 客户账户部署完成" | 要求密码；任何一项 ✗ |
| A7 | 在 `v2cc` 新开一个终端窗口（部署前就开着的窗口看不到 `claude`，脚本结尾会提示），运行 `claude --version`、`git --version`、`node --version`、`brew --version`、`npm config get prefix` | 都有输出；npm 的位置在 `v2cc` 的主目录里 | 新窗口里命令找不到 |
| A8 | 在 `v2ccops` 运行 `~/v2cc-mac-setup/bootstrap.sh` | 七步全部显示"跳过""已安装"或"无需切换"（`[6/7]` 显示"监测程序已安装、是这一版，并且在运行"）；除验证外没有任何安装或切换；不要求输入密码 | 有任何重新安装或切换 |
| A9 | 重启，分别登录 `v2ccops` 和 `v2cc`，各运行 `~/v2cc-mac-setup/verify.sh` | 两次都是"验证通过" | 任何一项 ✗ |
| A10 | 登录机主账户，打开终端 | 终端正常，机主的文件和设置没有变化 | 终端报错或设置变化 |
| A11 | 在 `v2ccops` 和 `v2cc` 各运行 `~/v2cc-mac-setup/verify.sh --credentials` | "未发现遗留的 GitHub 凭据" | 报告任何凭据 |

### 失败重跑（在 A2 过程中有意制造一次）

| # | 操作 | 预期结果 |
| --- | --- | --- |
| A12 | 在 Nix 安装过程中按 Ctrl-C，然后重新运行 `~/v2cc-mac-setup/bootstrap.sh --customer v2cc` | 已装好的 CLT 被跳过；Nix 要么继续安装，要么提示"检测到不完整的 Nix 安装"并给出卸载命令，按提示处理后重跑成功 |
| A13 | 入口命令放置超过 6 分钟再粘贴 | "下载失败。链接约 5 分钟后失效"，`~/v2cc-mac-setup` 不变 |

### 已知的可能停止点

- `Unexpected files in /etc`：nix-darwin 只在 `/etc/zshrc`、`/etc/bashrc` 等文件
  是它认识的内容（macOS 原始内容或 Determinate 安装器改过的内容）时才接管。新的
  macOS 版本可能让这些文件变成它不认识的内容，这时它会在改动任何东西之前停止。
  需要运营方确认文件内容后再处理，脚本不会自动改名。
- Determinate Nix 安装器的 `install --no-confirm` 参数、Homebrew 安装脚本在
  `NONINTERACTIVE=1` 下复用已输入的管理员授权：两者都取自官方脚本的当前行为，
  尚未在真实空白机上跑过。

## B. 首台 Mac mini（机主 howard 已有系统配置）

前提：`howard`（501）是管理员，当前系统由本仓库以 `howard` 身份部署；`v2cc`（502）
是普通账户；`v2ccops` 是管理员。`/opt/homebrew` 属于 `v2cc`（属于 `howard` 时先按
docs/ONBOARDING.md 第 15 节 M5 由机主决定）。客户还在用管理员 `v2cc` 的机器先按
第 15 节迁移。

验收范围：机主账户只要求"保留、能正常登录、没有损坏"；开发环境可用只针对客户
账户 `v2cc`。"部署前已有的账户、服务和命令全部保留"由脚本自动检查，不是手工步骤。

| # | 操作 | 预期结果 | 停止条件 |
| --- | --- | --- | --- |
| B1 | 在 `v2ccops` 运行演练入口命令（`--customer v2cc`） | "客户账户（普通账户）：v2cc"；"受管理的账户：howard v2cc"；"主用户（system.primaryUser）：howard"；"已保留当前系统中已有的账户配置：howard"；"当前系统管理的账户、服务和命令在新配置中全部保留"；变化列表里只有 `activation-v2cc`、`hm_Usersv2cc.*`、`home-manager` 等新增项，没有任何 `howard` 相关的移除 | 出现任何 ✗（说明 howard 的配置不是本仓库这个版本生成的，见下） |
| B2 | 获得批准后，在 `v2ccops` 运行正式入口命令，确认整机切换 | 输出中同时有 `Activating home-manager configuration for howard` 和 `... for v2cc`；"部署前已有的账户、服务和命令全部保留"；"验证通过" | 激活失败（会自动回退，回退后停止） |
| B3 | 在 `v2cc` 运行客户入口命令，然后新开一个终端窗口，运行 `claude --version`、`brew --version` | 不要求密码；有版本号输出 | 要求密码；新窗口里命令找不到 |
| B4 | 登录机主账户 `howard` | 账户还在，能正常登录，没有损坏。机主账户不用开发环境，不需要检查其中的 git、node、home-manager、gh | 无法登录或账户异常 |
| B5 | `howard` 未登录图形界面时（注销后）在 `v2ccops` 重跑 `~/v2cc-mac-setup/bootstrap.sh` | "新配置已经是当前系统，无需切换" | 报错 |
| B6 | 在 `v2ccops` 运行 `./rollback.sh`，确认 | "已回退到"部署前的系统路径；`howard` 账户仍能正常登录 | 回退失败 |
| B7 | 在 `v2ccops` 重新运行 `./bootstrap.sh` | 再次部署成功，"验证通过" | 任何 ✗ |

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
- `/opt/homebrew` 属于 howard 时，部署不会改动它，`v2cc` 不能用 `brew` 安装软件，
  `verify.sh` 报告这一项 ✗。Homebrew 本身不支持多账户共用。机主同意交给 `v2cc` 时
  按 docs/ONBOARDING.md 第 15 节 M5 操作，此后 Homebrew 那一步激活改为以 `v2cc`
  运行，共存检查会要求 `V2CC_ALLOW_SYSTEM_CHANGES=1`。

## C. 7×24 在线设置与重启后恢复

桩测试和闭包测试只证明脚本的逻辑和"对已有系统只增不改"。下面每一条都要在真实
机器上才算验证过，在那之前一律按"未验证"对待，不能当成已经可用。

规则同上：每一步有预期结果和停止条件；遇到停止条件就停下，保留终端全部输出，
不要手工绕过。阶段 0 不改动任何东西，可以立即做。之后每个阶段都需要单独批准。

机主账户的验收范围不变：只要求"保留、能正常登录、没有损坏"。但这一节的设置是
整机的：电源、自动退出登录、系统更新对机主账户同样生效，FileVault 更是整块磁盘
一个开关。动手之前机主必须知情。

### 阶段 0 - 读取机器现状（不改动）

| # | 操作 | 记录 |
| --- | --- | --- |
| 0.1 | 在 `v2ccops` 运行 `sw_vers`、`pmset -g custom`、`pmset -g cap`、`pmset -g sched` | 完整输出，作为"改动前"的人工备份 |
| 0.2 | `fdesetup status`；`sysadminctl -autologin status`；`ls -l /etc/kcpassword` | **FileVault 开还是关，决定阶段 2 的全部内容** |
| 0.3 | `defaults read /Library/Preferences/com.apple.SoftwareUpdate`；`softwareupdate --history` | 更新开关的现状，以及这台机器因更新重启的频率 |
| 0.4 | UU远程 的版本、三个开关（允许本设备被控、开机自动启动、防止电脑休眠）、两项权限（辅助功能、录屏与系统录音）、「登录项与扩展」里的状态 | 截图 |
| 0.5 | 询问已在使用的机器的机主：重启后屏幕上到底显示什么（拍照）；UU远程 的录屏授权提示有没有在使用约一个月后再次出现 | 区分"磁盘解锁界面"和"登录窗口"；判断录屏授权是否需要定期重新确认 |

### 阶段 1 - 7×24 在线设置

| # | 操作 | 预期结果 | 停止条件 |
| --- | --- | --- | --- |
| 1.1 | 在 `v2ccops` 运行演练入口命令 | "当前系统管理的账户、服务和命令在新配置中全部保留"；"软件包没有增加、减少或版本变化"；"本次切换会启用 7×24 在线设置"及其下六行；"[演练] 将把系统切换到 ...（未执行）" | 出现任何 ✗ |
| 1.2 | 获得批准后运行正式入口命令，确认整机切换 | 激活输出里有 `v2cc always-on: machine-wide settings...`；"检查 7×24 在线设置"下六项都是 ✓；"验证通过" | 激活失败（脚本会自动回退系统配置并把设置恢复原值，之后停止） |
| 1.3 | `cat /var/db/v2cc/always-on-before.txt` | `pmset.c.sleep`、`pmset.c.autorestart`、`pmset.c.womp` 与 0.1 记录的一致；`macos-update-install` 与 0.3 一致 | 文件不存在或数值不符 |
| 1.4 | `pmset -g custom`；打开「系统设置 > 能源」「隐私与安全性 > 高级」「通用 > 软件更新 > 自动更新」 | `sleep 0`、`autorestart 1`、`womp 1`；能源里的开关与之一致；"闲置后自动退出登录"关闭；"安装 macOS 更新"关闭，其余更新开关与 0.3 相同 | 某个值没有生效，或系统设置里的开关与命令读到的不一致 |
| 1.5 | 登录机主账户 | 账户还在，能正常登录，没有损坏 | 无法登录或账户异常 |
| 1.6 | 记下 `pmset -g stats`，在没有远程连接的情况下让机器闲置 60 分钟，再看 `pmset -g stats` 和 `pmset -g log \| grep -E "Entering Sleep\|Display is turned off"` | 有 "Display is turned off"；这一小时内没有 "Entering Sleep"，睡眠次数没有增加；期间一直能 ping 通 | 系统睡眠了 |
| 1.7 | 在 `v2ccops` 重跑 `./bootstrap.sh` | "新配置已经是当前系统，无需切换"；不要求输入密码 | 有任何重新切换 |
| 1.8 | 重启，运行 `./verify.sh` | "验证通过"；数值不变 | 任何一项 ✗ |
| 1.9 | 回退演练：在 `v2ccops` 运行 `./rollback.sh`，确认；然后 `pmset -g custom` 并查看 1.4 的三处系统设置；最后重跑 `./bootstrap.sh` | "已回退到"部署前的系统；"已恢复为启用前的值"；各项与 0.1、0.3 的记录一致；重新部署后"验证通过" | 回退失败，或有设置没有回到原值 |

### 阶段 2 - 重启后恢复与 UU远程（需要机主在场并同意）

前提：阶段 1 通过；机主已同意在这台机器上关闭 FileVault；手边有第二台登录了同一
UU 账号的设备；机器上没有正在进行的重要工作。

脚本不设置 UU远程。先由人在 `v2cc` 的桌面里完成：登录 UU 账号，打开「允许本设备
被控」「开机自动启动」「防止电脑休眠」，授予「辅助功能」和「录屏与系统录音」，重启
UU远程 客户端，确认「系统设置 > 通用 > 登录项与扩展」里 UU远程 是开启的。普通账户
授予权限时系统要不要管理员的名字和密码，记录下来（D 节 D8）。

`auto-login.sh enable` 和 `disable` 在 `v2ccops` 里运行，`sysadminctl` 询问的是
`v2cc` 的密码。

| # | 操作 | 预期结果 | 停止条件 |
| --- | --- | --- | --- |
| 2.1 | 机主在「系统设置 > 隐私与安全性 > FileVault」里关闭 FileVault；等到 `fdesetup status` 显示 `FileVault is Off.` | 解密完成 | 几小时内没有完成 |
| 2.2 | **不开启**自动登录，重启。机器停在登录窗口时，从第二台设备用 UU远程 连接 | 记录：设备是否在线，能否看到并操作登录窗口 | 无（两种结果都是信息）。如果稳定可用，就不需要自动登录，后面的步骤改为验证这种方式 |
| 2.3 | 在 `v2ccops` 运行 `./auto-login.sh enable`，按提示输入账户名 `v2cc` 确认，在系统工具的提示下输入 `v2cc` 的密码 | "自动登录账户：v2cc"；"登录凭据由系统保存在 /etc/kcpassword（root:600）"；`./verify.sh` 显示"重启后自动登录账户 v2cc"；在 `~/.zsh_history` 和 `~/.zsh_sessions` 里搜不到密码 | 系统工具拒绝；出现"读回检查未通过"（脚本已自动撤销）；密码在任何地方可见 |
| 2.4 | 在 UU远程 会话里重启机器。计时：从重启到 UU 设备列表里显示在线 | 无人接触机器的情况下恢复在线；记录用时（建议上限 5 分钟） | 15 分钟仍不在线：现场的人给屏幕拍照，停止 |
| 2.5 | 连接 | 能看到桌面，键盘鼠标可用 | 黑屏或无法操作 |
| 2.6 | 把 2.4、2.5 再做两遍 | 连续三次结果相同 | 任何一次失败 |
| 2.7 | 登录后立即锁屏：运行 `./auto-login.sh enable --lock-after-login`，重启。现场的人观察屏幕；从第二台设备连接，通过 UU远程 在锁屏界面输入密码 | 登录后显示器立即关闭并锁定；UU 显示在线；能通过 UU远程 解锁并操作桌面；连续三次相同 | 登录项没有执行、黑屏、或无法通过 UU远程 操作锁屏界面：运行 `./auto-login.sh enable`（不带参数）去掉锁屏，记录结果，由机主决定是否保留不锁屏的自动登录 |
| 2.8 | 客户保持连接，机主在机器上切换到自己的账户，再切换回来 | 记录客户看到什么；机主的会话不能被客户的 UU 账号看到或操作 | 客户能看到或操作机主的会话 |
| 2.9 | 在远程会话里选择「退出登录」 | 机器变为不可连接并保持如此（预期：自动登录只在开机时发生）；记录恢复方式（现场登录或重启） | 重启后也不恢复 |
| 2.10 | 在 `v2cc` 里修改它自己的密码（普通账户可以），重启 | 记录自动登录是否仍然有效；无效时重新运行 `./auto-login.sh enable`，再做一遍 2.4 | 重新运行时系统工具没有完成：以脚本最后一行为准，它会说明此前的自动登录是原样保留还是已经关闭 |
| 2.11 | 运行 `./verify.sh` | "验证通过" | 任何一项 ✗ |
| 2.12 | 回退演练：在 `v2ccops` 运行 `./auto-login.sh disable`，然后 `ls -l /etc/kcpassword`、`./auto-login.sh status`，重启 | "自动登录已关闭，保存的登录凭据已删除"；`/etc/kcpassword` 不存在；重启后停在登录窗口（预期）。之后按机主的决定重新开启，或修改密码并由机主重新开启 FileVault | 凭据文件仍在，或重启后仍然自动登录 |

### 阶段 3 - 断电

拔掉正在运行的电脑的电源总有一点风险，下面的条件把它降到最低。每次只拔一次。

| # | 操作 | 预期结果 | 停止条件 |
| --- | --- | --- | --- |
| 3.1 | 确认条件：没有部署或 `nix build` 在运行；软件更新里没有正在下载或安装的更新；没有远程会话；机器已闲置 2 分钟 | 全部满足 | 任何一条不满足：不要拔 |
| 3.2 | 现场的人拔掉运行中的机器的电源线，等 60 秒，再插上。不要按电源键 | 机器自己开机；阶段 2 已完成时，UU远程 恢复在线；记录用时 | 5 分钟内没有开机：按一次电源键，记录，停止。出现恢复或磁盘修复界面：拍照，停止 |
| 3.3 | `./verify.sh`；`sysctl -n kern.boottime` | "验证通过"；开机时间就是恢复供电的时间 | 任何一项 ✗ |

"先关机、再断电、再通电"的情况不在这次的范围内：断电后自动开机只在断电时机器
是开着的情况下起作用。

### 阶段 4 - 有待安装的系统更新

需要 Apple 发布了新的 macOS 更新才能做，等下一次更新时进行。

| # | 操作 | 预期结果 | 停止条件 |
| --- | --- | --- | --- |
| 4.1 | 打开「系统设置 > 通用 > 软件更新」 | 显示有可用更新；"安装 macOS 更新"是关闭的 | 开关又被打开了 |
| 4.2 | 机器照常使用 72 小时。每天记录 `sysctl -n kern.boottime` 和 `softwareupdate --history \| tail -3` | 没有重启，没有新的安装记录 | 更新自己安装了：记录时间和软件更新的各项开关，停止。说明这个开关在这个 macOS 版本上挡不住自动安装 |
| 4.3 | 运营方在提前通知的维护时段内，在 `v2ccops` 的会话里（D 节 D9 的方式，或在机器旁）在系统设置里安装更新。计时：到重新在线为止 | 阶段 2 已完成时自己恢复在线；记下任何需要点击的设置界面 | 30 分钟仍不在线：现场拍照 |
| 4.4 | `./verify.sh`；再检查 UU远程 的两项权限和「登录项与扩展」 | 全部仍然开启 | 有权限被更新重置 |

### 尚未在真实机器上验证

下面这些在桩测试里都用假的系统命令代替，脚本的提示里也照此说明。括号里是会
验证它的步骤。

- `defaults write` 写入的 `AutomaticallyInstallMacOSUpdates` 在 macOS 27 上确实
  阻止了自动安装（4.1、4.2）；自动退出登录的开关确实保存在
  `/Library/Preferences/.GlobalPreferences`（1.4）。
- 用 `defaults delete` 恢复之后，系统设置里的开关回到原来的状态（1.9）。
- 断电时间很短时的硬件行为（3.2）；带 UPS 或电池的机器上按电源来源分别记录和
  恢复（只在桩测试里验证过）。
- `sudo sysadminctl -autologin set -userName <账户> -password -` 在 macOS 27 上
  会自己在终端询问密码并完成设置；开启状态下 `sysadminctl -autologin status` 的
  回答是什么（2.3）。脚本不依赖这句回答，只看自动登录账户和凭据文件。
- `/etc/kcpassword` 的属主和权限是 root:600，以及 `sysadminctl -autologin off`
  会删除它（2.3、2.12）。没有删除时脚本会自己删。
- 修改账户密码后，系统是否自己更新已保存的密码（2.10）。
- "登录后立即锁屏"的登录项：`pmset displaysleepnow` 不用 root 能否执行，macOS 是否
  会为这个登录项弹出"后台项目"提示，显示器关闭后是否立即锁定（2.7）。
- UU远程：登录窗口下能否连接（2.2）；能否操作 Mac 的锁屏界面（2.7）；录屏授权
  是否需要定期重新确认（0.5）；切换用户时的表现（2.8）；系统更新后权限是否保留
  （4.4）；两项权限在重启后是否保留（2.4 到 2.6）。

## D. 客户的普通账户

只有 `v2cc` 是普通账户之后才有意义。D1 到 D7、D12 在 `v2cc` 里做，D10、D11 有一部分
在 `v2ccops` 里做，装的示例软件做完就删。D8、D9 需要机主在场。

| # | 操作 | 预期结果 | 停止条件 |
| --- | --- | --- | --- |
| D1 | `id -Gn`；`sudo -v`（出现密码提示时按 Control-C，不输入任何密码） | 没有 `admin`；`sudo` 报告 `v2cc` 不能运行 sudo | `v2cc` 能用 sudo |
| D2 | `brew install hello && hello && brew uninstall hello` | 成功，不要求密码 | 要求密码或权限不足 |
| D3 | `brew install --cask` 一个体积小、只含一个应用包的 cask，然后 `ls ~/Applications`，再卸载 | 应用装进 `~/Applications`，不要求密码；能打开 | 要求密码：记下这个 cask，说明它需要平台代装 |
| D4 | 找一个安装程序是 `.pkg` 的 cask 运行 `brew install --cask`（只看提示，不输入密码） | 要求 `sudo` 密码（预期：这类 cask 由平台代装） | 无（记录结果） |
| D5 | `npm install -g cowsay && cowsay ok && npm uninstall -g cowsay`；`npm config get prefix` | 成功，不要求密码；位置在 `v2cc` 的主目录里 | 要求密码，或写只读目录失败 |
| D6 | `python3 --version`、`uv --version`；`uv venv /tmp/v2cc-uv-check && uv pip install --python /tmp/v2cc-uv-check six`；`python3 -m venv /tmp/v2cc-venv-check && /tmp/v2cc-venv-check/bin/pip install six`；再删掉这两个目录 | 版本号来自系统配置（`command -v python3` 在 `/run/current-system/sw/bin`）；都成功，不要求密码 | 要求密码 |
| D7 | 在 Finder 里把 `/Applications` 里的 UU远程 拖进废纸篓（出现管理员认证框时取消） | 系统要求管理员的名字和密码，`v2cc` 自己删不掉 | 直接删掉了 |
| D8 | 记录 C 节阶段 2 开头 UU远程 的设置在 `v2cc` 里能否完成：授予「辅助功能」「录屏与系统录音」时系统是否要管理员的名字和密码；要的话，运维通过远程会话在系统的授权对话框里输入 `v2ccops` 的名字和密码（ONBOARDING「五个设置问题的默认做法」第 2 项），之后改一次 `v2ccops` 的密码 | 授权对话框接受 `v2ccops`；两项权限在 UU远程 重启后仍然开启 | 授权对话框不接受；权限没有保存 |
| D9 | 客户保持 UU远程 连接时，在远程会话里从菜单栏切换到 `v2ccops`（快速切换用户），在登录窗口输入 `v2ccops` 的密码。**只在机主同意、`v2ccops` 的密码之后会更换的前提下做**：这个密码是通过远程会话输入的 | 记录：远程画面是否跟到 `v2ccops` 的会话，能否操作；切回 `v2cc` 后客户的会话是否还在 | 远程画面断开且 15 分钟内不恢复：现场处理 |

| D10 | 在 `v2ccops` 按 ONBOARDING 6.5 用 `--user=v2cc` 安装 Docker Desktop；然后在 `v2cc` 里打开 Docker Desktop，接受协议，运行 `docker run --rm hello-world` | 安装成功；`v2cc` 打开时不要求管理员密码；容器运行成功 | 要求管理员密码（先按 6.5 的异常处理，仍然要求就停下）；安装失败 |
| D11 | `/opt/homebrew` 交给 `v2cc` 之后，在 `v2ccops` 里运行 `/opt/homebrew/bin/brew install hello`；再运行 `sudo -u v2cc -H /opt/homebrew/bin/brew install hello`，在 `v2cc` 里运行 `hello`，最后在 `v2cc` 里 `brew uninstall hello`；然后在 `v2cc` 里 `ls -l /opt/homebrew/bin/hello` 之前和之后都确认属主 | 第一条失败（没有写权限，这是有意的）；第二条成功；`hello` 能运行；之后 `ls -ld /opt/homebrew` 仍然属于 `v2cc`，`v2cc` 自己的 `brew` 仍然正常 | 第一条成功（说明别的账户能写客户的 Homebrew）；第二条之后出现不属于 `v2cc` 的文件 |
| D12 | 在 `v2cc` 里记下 `claude --version`，运行 `claude update`（或等 Claude Code 自己升级） | 升级成功或报告已是最新，不要求密码；`~/.local/bin/claude` 仍属于 `v2cc` | 要求密码，或升级写到别的位置失败 |

D9 不可行时，平台需要在「终端」里用 `sudo` 的维护只能由人在机器旁登录 `v2ccops` 完成
（docs/ONBOARDING.md「五个设置问题的默认做法」第 2 项）。

## E. 监测程序（docs/monitoring.md）

**全部尚未在真机上测过。只在测试机上做，开始前先备份（例如 Time Machine）。**
目标是 Captain 在测试机上一次跑通：A 节的系统部分跑完时，监测程序已经装好并在运行。
`D` 代表 `"/Library/Application Support/V2CC/monitor"`，在终端里先运行
`D="/Library/Application Support/V2CC/monitor"`。

| # | 账户 | 操作 | 预期结果 | 停止条件 |
| --- | --- | --- | --- | --- |
| E1 | `v2ccops` | A2 那条命令跑完后看 `[6/7]` | "监测程序已安装并启动"、"机器编号：mac-..."、"第一轮已完成"；提醒"没有配置上传目标" | 安装失败；1 分钟内没有第一轮 |
| E2 | `v2ccops` | `./verify.sh` | "监测程序在运行"、"最近一次记录在 0 分钟前"、"哈希链完整"；"上传目标没有配置"是 `!` 提醒 | 任何一项 ✗ |
| E3 | `v2ccops` | 等 10 分钟，`ls -l "$D/records"`；`tail -n 1 "$D/records/$(date -u +%F).jsonl" \| plutil -p -` | 文件属主 `root`、组 `admin`；最新一条是 `routine`，序号比 E1 大；内容里没有文件内容、网址、远端地址 | 没有新记录；看到文件内容或网址 |
| E4 | `v2ccops` | `/usr/bin/time -l /bin/bash "$D/v2cc-monitor" check "$D"/records/*.jsonl`；`sudo /usr/bin/time -l /bin/bash "$D/v2cc-monitor" run` | `check` 通过；一轮用时和内存记下来（预期几秒以内） | 一轮超过 1 分钟 |
| E5 | `v2cc` | `launchctl bootout system/com.v2cc.monitor`；`rm /Library/LaunchDaemons/com.v2cc.monitor.plist`；`ls "$D/records"`；`echo x >> "$D/config"`；`echo x >> "$D/v2cc-monitor"` | 全部被拒绝（Operation not permitted 或 Permission denied）；之后在 `v2ccops` 里 `./verify.sh` 仍显示在运行 | 任何一项成功 |
| E6 | `v2cc` | 运行 `python3 -m http.server 8765 --bind 0.0.0.0` 10 分钟后按 Control-C | 之后的记录里有 `"alert":"external_listen"`，程序名 `python3`（或解释器的名字）；没有任何东西被停止 | 没有告警；程序被结束 |
| E7 | 机主 | 按 docs/monitoring.md「要机主提供或决定的事」准备测试用的桶、桶锁、只给这个桶的令牌 | 拿到上传地址、桶名、Access Key ID、Secret Access Key | 无（没有时跳过 E8、E9） |
| E8 | `v2ccops` | `./monitor.sh configure --upload-endpoint https://<账号 ID>.r2.cloudflarestorage.com --upload-bucket <桶> --upload-credential`，按提示输入两行；2 分钟后 `./monitor.sh status`、`./verify.sh` | "记录已上传到机器外"；桶里出现 `<机器编号>/records/<日期>/<起止序号>.jsonl`，内容和本机文件对应部分一致；终端历史（`history`）里没有令牌 | 上传失败；令牌出现在任何输出、日志或历史里 |
| E9 | 机主 | 在 R2 网页上试着删除 E8 上传的对象 | 桶锁拒绝删除 | 能删掉 |
| E10 | `v2ccops` | `./monitor.sh configure --ots-url https://a.pool.opentimestamps.org --tsa-url https://freetsa.org/tsr`；第二天 `ls "$D/receipts"` | 有前一天的 `.ots` 和 `.tsr`，记录里有 `"kind":"daily"`，`"ots":"ok","tsa":"ok"` | 两项都是 `failed` |
| E11 | `v2ccops` | 重启测试机，登录后等 10 分钟，`./verify.sh` | 监测程序自己恢复运行；重启前后的记录序号连续；有一条 `heartbeat_gap` 告警（停机期间） | 重启后没有运行 |
| E12 | `v2ccops` | `./monitor.sh uninstall`，再 `./verify.sh` | 停止并删除，"本机的记录保留在..."；`verify` 报"监测程序没有安装"。恢复：`./monitor.sh install` | 删除后仍在运行 |

回退：`./monitor.sh uninstall`（保留本机记录）或 `./monitor.sh uninstall --delete-records`。
它不影响系统配置、自动登录和其他任何设置。
