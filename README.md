# V2CC Mac mini 标准部署

在一台 Apple Silicon Mac 上，为客户的普通账户（标准用户，例如 `v2cc`）装好
Xcode Command Line Tools、Determinate Nix、Homebrew、nix-darwin 系统配置和
Claude Code。客户账户没有管理员权限；需要管理员权限的部分由平台维护管理员账户
完成。本机其他账户已有的 Nix / Home Manager 配置不会被改动。

从新机到手到交付验收的完整操作顺序见 [docs/ONBOARDING.md](docs/ONBOARDING.md)。

## 三个账户

| 账户 | 类型 | 做什么 |
| --- | --- | --- |
| 机主自己的账户 | 管理员 | 机主自用，部署和日常维护都不需要它。机主在这里新建另外两个账户、关闭 FileVault；docs/ONBOARDING.md 第 15 节「迁移」里有几步要机主同意 |
| 平台维护管理员（建议账户名 `v2ccadmin`，待定） | 管理员 | 运行 `bootstrap.sh`（部署、7×24 在线设置）、`auto-login.sh enable/disable`、`rollback.sh`，以及客户提出的需要管理员权限的安装 |
| 客户账户（`v2cc`） | 普通账户（标准用户） | 客户使用的账户。运行 `customer-setup.sh`，开机自动登录进入它，UU远程 在它的会话里运行 |

客户账户不能用 `sudo`。需要管理员权限的脚本在客户账户里运行时，会在做任何事之前
停下并说明原因。

## 部署分两步

1. 机主在「系统设置 > 用户与群组」里新建平台维护管理员账户（类型「管理员」）和
   客户账户（类型「普通」），都在现场由人输入密码。
2. V2CC 运营方在自己已登录 GitHub 的电脑上生成两条入口命令：

   ```sh
   tools/make-entry-command.sh --customer v2cc            # 系统部分，部署 main
   tools/make-entry-command.sh --customer v2cc --dry-run  # 只检查、不改动的演练命令
   tools/make-entry-command.sh --customer-setup           # 客户账户部分
   ```

3. 系统部分的那一行在平台维护管理员账户的「终端」里粘贴运行；完成后，客户账户
   部分的那一行在客户账户的「终端」里粘贴运行。

每一行命令都会下载部署包、校验 SHA-256、解压到当前账户的 `~/v2cc-mac-setup`，
然后运行其中的脚本。

系统部分 `bootstrap.sh --customer v2cc`（平台维护管理员账户）：

| 步骤 | 内容 | 已具备时 |
| --- | --- | --- |
| 1 | 检查机型、系统版本、磁盘空间；运行的账户是管理员；客户账户存在、不是运行的账户、是普通账户 | 不满足则停止 |
| 2 | Xcode Command Line Tools | 跳过 |
| 3 | Determinate Nix（固定版本，校验 SHA-256） | 跳过 |
| 4 | Homebrew（固定版本的官方安装脚本，校验 SHA-256），然后交给客户账户 | 已属于客户账户则跳过 |
| 5 | 构建系统配置（含 7×24 在线设置和客户账户的登记）、检查不影响现有账户、切换 | 已是当前系统则跳过 |
| 6 | 部署后验证（整机部分），包括检查这个账户没有遗留 GitHub 凭据 | 每次都做 |

客户账户部分 `customer-setup.sh`（客户账户，不用 `sudo`，不要求任何密码）：

| 步骤 | 内容 | 已具备时 |
| --- | --- | --- |
| 1 | 确认这是系统登记的客户账户、是普通账户，Homebrew 属于它 | 不满足则停止（Homebrew 不属于它时只提醒） |
| 2 | 在 `~/.zprofile` 里加入 Homebrew 的命令路径、`HOMEBREW_CASK_OPTS="--appdir=$HOME/Applications"`、`~/.npm-global/bin`；在 `~/.npmrc` 里把 npm 的安装位置设为 `~/.npm-global` | 已有的行不重复加；`~/.npmrc` 已经设了安装位置时不改动 |
| 3 | Claude Code（官方安装脚本），装在 `~/.local/bin` | 跳过 |
| 4 | 部署后验证（整机部分和客户账户部分），包括检查这个账户没有遗留 GitHub 凭据 | 每次都做 |

部署前就开着的终端窗口保留着旧的 PATH，在里面找不到 `claude`、`brew`：新开一个
终端窗口，或在原窗口运行 `exec zsh -l`。脚本结尾会按实际情况提示，`verify.sh`
检查的也是新开的登录 zsh 能否找到这些命令，而不是按绝对路径调用。

需要人工参与的只有 macOS 自身要求的环节：系统部分要输入平台维护管理员账户的登录
密码（管理员授权，可能不止一次），以及在本机已有 nix-darwin 系统时确认一次整机
切换。这不是完全无人值守的安装。客户账户部分不要求输入任何密码。

任何一步失败后，修复原因再运行同一条命令（或该账户里的
`~/v2cc-mac-setup/bootstrap.sh`、`~/v2cc-mac-setup/customer-setup.sh`）即可，已完成
的步骤会被跳过。系统部分重跑时不必再写 `--customer`：系统配置里登记了客户账户。
入口命令里的下载链接约 5 分钟后失效，过期后需要运营方重新生成；本机的脚本不需要
链接，可随时重跑。它们重跑的是已经下载到本机的那一版，不会获取新版本，见下一节。

## 客户账户里能做什么、不能做什么

客户账户是普通账户，下面这些不需要管理员密码。这是设计：桩测试覆盖了设置和检查，
真机上尚未验证（[docs/test-plan.md](docs/test-plan.md) D 节）。

| 操作 | 为什么可以 |
| --- | --- |
| 使用预装的 `git`、`node`、`npm`、`claude`，以及 Xcode Command Line Tools 带的 `clang`、`make`、`python3`、`pip3` | 都在客户账户能执行的位置 |
| `brew install <软件包>`、`brew upgrade`、`brew uninstall` | `/opt/homebrew` 属于客户账户（只有它能写） |
| `brew install --cask <应用>`，应用装进 `~/Applications` | `HOMEBREW_CASK_OPTS` 把应用目录设在客户自己的主目录 |
| `npm install -g <包>`，装进 `~/.npm-global` | 预装的 `node` 在只读的 Nix 目录里，`~/.npmrc` 把全局安装位置改到客户自己的主目录 |
| `pip3 install <包>`、`python3 -m venv` | Xcode Command Line Tools 的 `python3` 的系统目录不可写，`pip3` 自动改为装进 `~/Library/Python/`；在虚拟环境里装不涉及系统目录。Homebrew 装的 `python3` 不允许直接 `pip install`（PEP 668），要用虚拟环境 |
| Claude Code 自己升级 | 装在 `~/.local/bin` |

下面这些需要管理员权限，由平台在平台维护管理员账户里按客户的申请完成：

- 安装程序是 `.pkg` 的 cask，或者要写 `/Applications`、`/Library` 的 cask（Homebrew
  会要求 `sudo` 密码）；`~/Applications` 不起作用的应用。
- 少数在安装过程中要求 `sudo` 的软件包。
- 系统设置里需要解锁的项目，包括电源、网络、共享、软件更新、隐私与安全性。
- macOS 更新。
- 自动登录、FileVault、系统配置的部署和回退。

已知的不足：

- 客户能卸载、删除自己账户里的一切，包括 Homebrew 里的软件包（`/opt/homebrew`
  属于客户账户，这是 `brew install` 不需要密码的前提）、Claude Code 和
  `~/.zprofile` 里的设置，也能在自己的会话里退出 UU远程 或关掉它的设置。"不删除
  平台安装的组件"对这些只能是使用规则，脚本拦不住；`./verify.sh` 能发现其中一部分。
  归 root 所有、或放在只有管理员能写的位置的部分（Nix、nix-darwin 系统配置、Xcode
  Command Line Tools、`/Applications` 里的应用、UU远程 的系统服务、锁屏登录项）普通
  账户删不掉。
- Homebrew 只能属于一个账户。机主自己早已在用 `/opt/homebrew` 的机器上，部署不会
  去改它，`./verify.sh` 会报告客户不能 `brew install`，要不要交给客户由机主决定
  （docs/ONBOARDING.md 第 15 节的 M5）。
- 预装的开发工具只有上面表里这些。要别的工具，客户自己 `brew install`。

## 升级已经部署过的机器

部署过的机器不会自己更新。`~/v2cc-mac-setup` 是当时下载的那一版的副本，里面没有
`.git`，也不会去下载：**重跑 `~/v2cc-mac-setup/bootstrap.sh` 部署的仍是旧版本。**
升级和首次部署用同一个入口，只是先演练一次：

1. 运营方重新生成两条入口命令：

   ```sh
   tools/make-entry-command.sh --dry-run  # 演练命令
   tools/make-entry-command.sh            # 正式命令
   ```

2. 在这台机器的平台维护管理员账户的「终端」里粘贴运行演练命令。它下载新版本，
   替换 `~/v2cc-mac-setup`，构建新配置并和正在运行的系统逐项比较，然后停下，不
   切换系统。应当看到"当前系统管理的账户、服务和命令在新配置中全部保留"和
   "[演练] 将把系统切换到 ...（未执行）"。出现任何 ✗ 就停下，把
   `~/.local/state/v2cc/guard-report.txt` 发给运营方。
3. 获得批准后粘贴运行正式命令。它会要求输入登录密码，并问一次是否切换整机的系统
   配置（y/N）；新版本第一次带来 7×24 在线设置时，会先把这五项列出来。结尾应当是
   "验证通过"。
4. 新版本改变了客户账户部分时，再在客户账户里运行一次客户入口命令
   （`tools/make-entry-command.sh --customer-setup`）。

客户还在用管理员账户 `v2cc` 的机器（本仓库此前的做法），升级之前先按
docs/ONBOARDING.md 第 15 节「迁移」处理。

- 新版本只增加内容时可以直接升级。新版本改变或去掉了本机已有的内容时，部署会
  在切换前被拦下，系统没有任何改动；是否用 `V2CC_ALLOW_SYSTEM_CHANGES=1` 放行
  由运营方决定（见「多账户共存」）。
- 演练命令已经把 `~/v2cc-mac-setup` 换成了新版本（只换这个目录，不动系统）。此后
  在本机运行 `./bootstrap.sh`，部署的就是新版本。
- 升级后想回到升级前的系统配置：`./rollback.sh`（见「失败与回退」）。
- 真实机器上的验收步骤见 [docs/test-plan.md](docs/test-plan.md) C 节阶段 1 的 1.1 和
  1.2。

## 多账户共存

nix-darwin 的系统配置是整机唯一的一份，不属于某个账户。如果新配置只声明了
正在部署的账户，切换后其他账户的 Home Manager 配置就不再受管理。因此：

- `prepare.sh` 根据正在运行的系统生成 `machine.nix`：受管理的账户 = 当前系统
  已管理的账户 + 客户账户，只增不减。运行部署的平台维护管理员账户不加进去，它
  不需要自己的 Home Manager 配置。
- 客户账户记在系统配置里（`/etc/v2cc/customer`）。`auto-login.sh` 只为它开启自动
  登录，`verify.sh` 和 `customer-setup.sh` 都按它检查。换成另一个客户账户和下面
  "改变"一样默认拒绝。
- `system.primaryUser` 只能是一个账户。它是 nix-darwin 的过渡选项，决定
  Homebrew、用户级默认设置和 launchd 用户服务归谁，不是"受管理账户的列表"。
  本机已有系统时沿用原值，否则取正在部署的账户（平台维护管理员）。本仓库没有
  用到依赖它的设置。
- `homebrew.user` 取 `/opt/homebrew` 的实际属主，部署之后就是客户账户。
- `deploy.sh` 在切换前把新配置和正在运行的系统逐项比较，只允许"增加"：

  | 情况 | 处理 |
  | --- | --- |
  | 主用户改变、某个账户不再被管理、账户的软件包环境、launchd 服务或系统命令减少 | 一律拒绝 |
  | 登记的客户账户改变、某个账户的 Home Manager 配置内容改变、当前系统闭包里的任何内容被移除或改变、激活步骤有任何一行被移除或改变（例如 Homebrew 换了属主） | 默认拒绝；整机有意升级时用 `V2CC_ALLOW_SYSTEM_CHANGES=1` 放行 |

  被拒绝时系统没有任何改动，诊断信息写入平台维护管理员账户的
  `~/.local/state/v2cc/guard-report.txt`，发给运营方即可。

如果机主有自己的 nix-darwin 配置（不是本仓库生成的），部署会在这一步被拒绝。
本仓库不会用标准配置替换机主的配置。

## 7×24 在线设置

系统配置在激活时（平台维护管理员账户运行部署时）写入下面五项，让机器保持在线。
它们是 macOS 的整机设置，**对本机所有账户生效，包括机主的账户**：

| 设置 | 值 | 方式 |
| --- | --- | --- |
| 系统空闲时自动睡眠 | 关闭（显示器仍按原设置自动关闭） | `pmset -a sleep 0` |
| 断电后恢复供电时自动开机 | 开启（本机没有这项设置时跳过） | `pmset -a autorestart 1` |
| 唤醒以供网络访问 | 开启（本机没有这项设置时跳过） | `pmset -a womp 1` |
| 闲置后自动退出登录 | 关闭 | `AutoLogOutDelay = 0` |
| 自动安装 macOS 更新 | 关闭 | `AutomaticallyInstallMacOSUpdates = false` |

- 关闭自动安装更新是为了不让更新在无人确认时重启机器，代价是安全修复不会自己
  装上：**必须有人在提前通知的维护时段里定期安装更新**。检查更新、更新通知、
  安全数据和后台安全更新的自动安装都没有动。脚本能确认的只是这个开关已经关闭；
  它在 macOS 27 上能否挡住更新自动安装和重启，尚未在真实机器上验证
  （[docs/test-plan.md](docs/test-plan.md) C 节阶段 4 的 4.2）。
- 改动之前，激活脚本先把原值记到 `/var/db/v2cc/always-on-before.txt`，只记一次。
  本机支持的电源设置里只要有一项的原值读不出来，就在这里停止，一项都不改。
- 设置只在部署激活时写入，不在每次开机时重写。之后有人在系统设置里改了某一项，
  脚本不会改回去，`./verify.sh` 会报告出来。
- 在已经部署过的机器上，这是一次"只增加"的部署，不需要
  `V2CC_ALLOW_SYSTEM_CHANGES`。以后改变其中某个值或去掉它们，会被共存检查拦下。
- 设置的内容在 [modules/always-on.sh](modules/always-on.sh)，每个值单独一行写明。

这些设置不保证机器永不重启，也不保证停电后一定能远程连接：停电期间、网络或路由器
故障、需要重启的更新、硬件故障、以及有人选择关机、睡眠或退出登录，都会造成中断。

### 重启之后能不能自己恢复远程连接

取决于 FileVault 和自动登录，`./verify.sh` 每次都会报告本机属于哪一种：

| 本机状态 | 重启后 |
| --- | --- |
| FileVault 开启 | 停在磁盘解锁界面，要有人在机器旁输入密码。在此之前任何远程软件都连不上，也无法自动登录 |
| FileVault 关闭，没有自动登录 | 停在登录窗口，要有人登录后才有用户会话 |
| FileVault 关闭，已开启自动登录 | 直接进入客户账户的桌面 |

UU远程 这类远程桌面软件在用户会话里运行。要让它在重启后自己回来，需要 FileVault
关闭并且自动登录。自动登录进入的是客户账户，所以远程会话到达的就是客户账户的
桌面。在平台维护管理员账户里运行（`status` 任何账户都能运行）：

```sh
./auto-login.sh status                      # 只读：本机现在的状态
./auto-login.sh enable                      # 为系统登记的客户账户开启自动登录
./auto-login.sh enable --lock-after-login   # 同上，并在客户每次登录后立即关闭显示器、锁屏
./auto-login.sh disable                     # 关闭，并删除系统保存的登录凭据
```

- **脚本不会关闭 FileVault。** 关闭它会降低本机所有账户（包括机主账户）的磁盘
  保护，必须由机主在知情同意后，自己在「系统设置 > 隐私与安全性 > FileVault」里
  关闭。FileVault 没有关闭时脚本直接停止。
- **脚本接触不到密码。** 密码由 macOS 自带的 `sysadminctl` 在终端里询问并保存，
  不会出现在命令参数、环境变量、脚本、仓库或命令历史里。
- 开启前脚本会用大白话列出后果，并要求输入账户名确认；`V2CC_ASSUME_YES` 跳不过
  这一步。主要后果：任何能接触到这台机器的人开机就能进入客户账户；账户密码以
  可还原的形式保存在 `/etc/kcpassword`，所以这个密码不能在别处使用；修改密码后
  要重新运行 `enable`。
- 只为系统登记的客户账户开启，而且只在它是普通账户时开启；要求 7×24 在线设置
  已经生效。机主和平台维护管理员这样的管理员账户永远不会被设成自动登录：开机就
  进入一个管理员账户，等于把整台机器交给能接触到它的人。`sysadminctl` 询问的是
  客户账户的密码。设置完会读回检查，读回不符就自动撤销。
- 客户自己修改了密码之后，要由平台维护管理员重新运行 `enable`，否则下次重启可能
  停在登录窗口。
- 平台维护管理员账户的密码不要在客户账户的桌面里输入（包括通过远程会话）：那个
  会话里的软件由客户控制。
- 在已经开启的机器上重新运行 `enable`（例如改了密码之后）而系统工具没有完成时，
  此前的自动登录原样保留；只有确认不了它是否完好时才撤销，并明确说明自动登录
  已经关闭、下次重启会停在登录窗口。
- `disable` 之后请修改该账户的密码（它曾以可还原的形式保存过），并由机主重新开启
  FileVault。
- UU远程 本身由人设置：用管理员账户安装；在客户账户里登录账号，打开「允许本设备
  被控」「开机自动启动」「防止电脑休眠」，授予「辅助功能」和「录屏与系统录音」
  （普通账户授予这些权限时，系统可能要求管理员的名字和密码，由平台维护管理员或机主
  在机器旁输入；是否需要尚未在真机验证）。脚本做不了，也读不到这些。
- "登录后立即锁屏"的登录项装在 `/Library/LaunchAgents/com.v2cc.lock-after-login.plist`，
  归 root 所有，只在客户账户的会话里起作用。旧版本把它放在客户的
  `~/Library/LaunchAgents` 里，重新运行 `enable --lock-after-login` 或 `disable` 时
  会删掉旧的那份。

**尚未在真实机器上验证：** 自动登录后、锁屏状态下或登录窗口下，UU远程 能否无人
值守连接；"登录后立即锁屏"的登录项在 macOS 27 上能否生效。在
[docs/test-plan.md](docs/test-plan.md) 的 C 节阶段 2 逐项验证通过之前，不能认为
某台机器重启后可以自己恢复远程连接。

## 常用命令

在 `~/v2cc-mac-setup` 目录下。平台维护管理员账户：

```sh
./bootstrap.sh --customer v2cc --dry-run  # 演练：只报告将要做什么
./bootstrap.sh --customer v2cc            # 检查、安装缺失项、部署、验证
./bootstrap.sh                            # 重跑：客户账户取系统配置里登记的
./rollback.sh              # 回退到上次部署之前的系统配置
./rollback.sh --settings   # 只把 7×24 在线设置恢复为启用前的原值
./auto-login.sh enable     # 为客户账户开启自动登录（见上）
./auto-login.sh disable    # 关闭自动登录
```

客户账户：

```sh
./customer-setup.sh --dry-run  # 演练
./customer-setup.sh            # Claude Code 和 brew、npm、应用安装位置的设置，然后验证
```

任何账户：

```sh
./verify.sh                # 只做部署后验证（只读）；客户账户里的检查只在客户账户里做
./verify.sh --credentials  # 只检查运行它的账户是否遗留 GitHub 凭据
./rollback.sh --list       # 查看系统配置的历史版本
./auto-login.sh status     # 只读：FileVault 和自动登录的状态
```

| 环境变量 | 作用 |
| --- | --- |
| `V2CC_DRY_RUN=1` | 同 `--dry-run` |
| `V2CC_CUSTOMER=<账户>` | 同 `bootstrap.sh --customer`；直接运行 `deploy.sh` 时用 |
| `V2CC_ASSUME_YES=1` | 对脚本自己的确认问题回答"是"。不能跳过 macOS 的授权，也不能跳过任何安全拦截 |
| `V2CC_ALLOW_SYSTEM_CHANGES=1` | 允许改变（但不允许移除）现有账户和系统内容，用于整机有意升级 |

## 失败与回退

- 激活失败且本机此前有系统配置：`deploy.sh` 自动把系统配置指回原版本并重新
  激活它，然后以失败退出。
- 部署成功后想撤销：在运行部署的平台维护管理员账户里运行 `./rollback.sh`（上次
  部署的记录在这个账户的 `~/.local/state/v2cc/last-deploy`）。它重新激活上次部署
  前的系统配置，不删除任何账户主目录里的文件。
- Homebrew 交给客户账户这一步不随系统配置回退。
- 7×24 在线设置保存在 macOS 里，不在 Nix 里，重新激活旧的系统配置并不会撤销
  它们。所以当回退的目标配置不包含这些设置时，`rollback.sh`（包括激活失败时的
  自动回退）会接着按 `/var/db/v2cc/always-on-before.txt` 把它们逐项恢复并读回
  检查，原来没有的设置会被删除，然后把记录改名为 `.restored`。有设置恢复不了时
  记录保留，处理后运行 `./rollback.sh --settings` 重试。
- 本机没有更早的系统配置（这次部署就是首次部署）时，用 `./rollback.sh --settings`
  只恢复这些设置。当前系统配置仍然包含它们，所以之后重跑 `./bootstrap.sh` 会再次
  启用。
- 自动登录不随系统配置回退，用 `./auto-login.sh disable` 单独关闭。
- 首次部署失败：此前没有系统配置可回退，修复原因后重跑即可。
- 彻底移除 Nix：`/nix/nix-installer uninstall`（Determinate Nix 自带）。

## 凭据

客户账户和平台维护管理员账户上都不需要、也不应留下任何 GitHub 凭据：

- 运营方的 GitHub 令牌只在运营方的电脑上使用，用来向 GitHub 换取一个约 5 分钟
  有效、只能下载这一个部署包的链接。
- 部署包不含 `.git`，没有远程地址，也不调用 `git` 或 `gh` 登录。
- `verify.sh` 会检查 Git 配置、`~/.git-credentials`、`~/.netrc`、GitHub CLI
  登录信息、命令历史、shell 启动文件、部署目录、环境变量和登录钥匙串；发现时
  只报告位置，不输出凭据内容。它只检查运行它的账户，所以两个账户里都要运行。

命令历史里会留下已失效的下载链接，它不能再下载任何内容。

## 开发与测试

```sh
tests/run.sh        # 桩测试：全新机器、部分安装、失败重跑、机主共存、账户角色、Homebrew 交接、客户账户、回退、凭据、入口命令、7×24 在线设置、迁移、自动登录
tests/closures.sh   # 用真实构建的 nix-darwin 闭包检验共存检查（只构建，不激活）
shellcheck -x *.sh lib/*.sh tools/*.sh tests/*.sh modules/*.sh
```

桩测试里 `sudo`、`pmset`、`defaults`、`sysadminctl`、`fdesetup`、`chown` 等全部是只碰
沙盒的替身，不读也不改真实机器；需要管理员权限的替身在没有经过 `sudo` 时会拒绝
执行，`sudo` 的替身对普通账户拒绝执行。沙盒里有三个账户（机主 `howard`、客户
`v2cc`、平台维护管理员 `v2ccadmin`），各有自己的主目录。
`modules/always-on.sh` 就是进入激活脚本的那一段，桩测试直接运行它，闭包测试确认
真实构建的激活脚本里逐行包含它。自动登录里必须由人确认的步骤，用系统自带的
`expect` 在真实的终端里驱动。

脚本必须兼容 macOS 自带的 `/bin/bash` 3.2（空白机器上只有它）。变量后面紧跟中文
时要写成 `${var}`，否则 bash 3.2 会把中文的首字节当成变量名的一部分。

真实机器上的验收步骤见 [docs/test-plan.md](docs/test-plan.md)。
