# 监测程序（最小版）

`bootstrap.sh` 的第 6 步（`[6/7]`）装好并启动它，新机跑一次就就绪。只用 macOS
自带的命令，不装第三方软件，不用系统扩展，不注册设备管理。

**状态：只在桩测试（`tests/monitor.sh`）里验证过，没有在任何真机上运行过。**
实测步骤在 [test-plan.md](test-plan.md) E 节，只在测试机上做。

## 它是什么

- 一个以 root 运行的 LaunchDaemon（`com.v2cc.monitor`），每 5 分钟运行一轮。程序在
  `/Library/Application Support/V2CC/monitor/v2cc-monitor`，归 root 所有。客户的普通
  账户停不掉、改不了它，也读不到记录。
- 每轮写一份运行摘要；每小时加一份系统事件摘录，并把新记录上传到机器外（配置了
  上传目标时）；每天给前一天的记录文件算一个指纹，交给时间戳服务（配置了时）。
- 发现可疑情况时写一条告警记录，并立即上传。告警只提醒人去看：不停止、不拦截、
  不改动任何东西。
- 每条记录在写入前按 [monitor/schema.txt](../monitor/schema.txt) 检查，有清单以外的
  字段就不写入，改写一条"记录被拒绝"的说明。测试用另一个解析器再查一遍。

## 网站上的那句话和实际记录的对照

网站的句子：「我们记录机器的运行情况（在线状态、资源占用、网络连接摘要、自动启动项
和已安装组件是否完整），不读取您的文件内容，不记录网址、屏幕和键盘输入，只用于维护
和核查。」

| 网站的说法 | 记录项 | 默认 |
| --- | --- | --- |
| 在线状态 | S1 | 开 |
| 资源占用 | S2、S3 | 开 |
| 网络连接摘要 | S4、S5 | 开 |
| 自动启动项 | S6 | 开 |
| 已安装组件是否完整 | S7（含系统代理、系统扩展、设备管理状态） | 开 |
| 网站句子没有提到 | S9 系统事件（登录、远程登录、开关机、管理员授权） | 开（按 2026-11-27 的指示） |
| 网站句子没有提到 | 可疑程序连接的具体地址 `DETAIL_ADDRESSES` | **关** |
| 网站句子没有提到 | 可疑程序的文件指纹 `DETAIL_FINGERPRINT` | **关** |
| 网站句子没有提到 | S8 出口地址（只能在接收端记，机器上不做） | 未实现 |

两个"关"的选项超出网站那句话，开启前要机主决定：
`./monitor.sh configure --detail-addresses on`、`--detail-fingerprint on`。开启后
`./verify.sh` 和 `./monitor.sh status` 都会提示。

## 逐项记录了什么

每条记录都有：版本 `v`、序号 `seq`、机器编号 `machine`（内部编号，不是序列号）、UTC
时间 `ts`、前一条记录的 SHA-256 `prev`、种类 `kind`。

**每 5 分钟（`routine`）**

| 项 | 字段 | 来源 |
| --- | --- | --- |
| S1 在线 | 开机时间、当前在屏幕前登录的账户名 | `sysctl`、`stat /dev/console` |
| S2 整机资源 | CPU、负载、内存、磁盘、GPU 利用率、网络收发总字节 | `top`、`vm_stat`、`df`、`ioreg`、`netstat` |
| S3 前 10 个程序 | 程序名（只取可执行文件的名字）、所属账户、CPU、内存、收发字节 | `ps -o comm`、`nettop` |
| S4 接收连接的程序 | 程序名、账户、协议、端口、只限本机还是对外 | `lsof` |
| S5 连接摘要 | 每个程序：连接数、不同远端的数量、半开连接数、端口分布、连向 AI 服务商接口地址段的连接数；对后者记程序的代码签名（开发者编号）和是否在允许名单里。**不记远端地址** | `lsof`、`codesign` |
| S6 自动启动项 | 客户 `~/Library/LaunchAgents`、`/Library/LaunchAgents`、`/Library/LaunchDaemons` 里的文件名；系统的登录和后台项目清单（名称、开发者编号、类型、是否启用，不记路径） | `ls`、`sfltool dumpbtm` |
| S7 组件 | UU远程 两个服务是否加载、Claude Code 是否存在且由 Anthropic 签名（只查签名，不运行它）、`CHECK_APPS` 里的应用签名、系统配置版本、系统扩展清单、是否注册设备管理、系统代理开关；失败项的名字 | `launchctl`、`codesign`、`systemextensionsctl`、`profiles`、`scutil` |
| | 是否配置了上传目标 | 配置 |

**每小时（`events`，S9）**：时间、事件类型、账户名、授权项名称，没有别的。事件类型：
控制台登录和注销、重启、关机（`last`，终端窗口不算）；睡眠、唤醒、开机
（`pmset -g log` 只取这几类行）；macOS 自带远程登录和屏幕共享的成功与失败；管理员
授权的成功与失败。来源是 `log show` 加固定过滤，原始日志行一条都不保存，格式认不出
的只计数。

**告警（`alert`）**：告警名、出现或解除、类别、程序名、账户、数值。

| 告警 | 条件 | 类别 |
| --- | --- | --- |
| `cpu_sustained` | 一个程序 CPU 超过 80% 持续 2 小时，常见开发工具除外 | F |
| `gpu_sustained` | 整机 GPU 超过 80% 持续 2 小时 | F |
| `external_listen` | 客户账户的程序在对外地址上接收连接 | H |
| `name_list` | 程序名符合挖矿、穿透、代理、带宽共享名单 | F、H |
| `api_direct` | 不在允许名单里的程序连续 1 小时直连 AI 服务商接口（只提醒，单独不算证据） | C |
| `api_direct_exposure` | 上一条和对外接收连接或穿透、代理程序在 24 小时内都出现 | C、H |
| `connection_burst` | 一个程序 5 分钟内连了 500 个以上不同远端 | A2 |
| `component_failed`、`component_changed` | S7 某项失败或发生变化 | G |
| `heartbeat_gap` | 距上一条记录超过 15 分钟 | 停机 |

允许名单按代码签名认，不按程序名：Apple 自己的程序，以及开发者编号 `Q6L2SF6YDW`
（Anthropic）、`EQHXZ8M8AV`（Google Chrome）、`KL8N8XSYF4`（Brave）。其他编辑器和浏览器
核对签名后加进配置的 `ALLOW_SIGNERS`。AI 服务商的接口地址段在 `API_RANGES`，默认
`160.79.104.0/23 153.61.224.0/22 2607:6bc0::/48`。

**每天（`daily`）**：前一天记录文件的 SHA-256、行数、两个时间戳服务的结果。

## 不记录什么

文件内容；文件名（自动启动项的文件名除外）；命令行参数和环境变量；网址、域名、DNS
查询；屏幕；键盘输入；剪贴板；Claude Code 的对话（`~/.claude`）；完整的系统日志包；
日志原文里的应用名、路径、地址；硬件地址；默认情况下任何远端地址。`tests/monitor.sh`
用带标记的假数据检查这些东西没有进入记录。

## 存放、防篡改和保存期限

- 本机：`/Library/Application Support/V2CC/monitor/records/<日期>.jsonl`，每行一条
  JSON。目录 `root:admin 750`，管理员能读，客户的普通账户读不到。
- 哈希链：每条带前一条的 SHA-256，跨天连续。改动或删除任何一条，后面就对不上。
  `./verify.sh` 每次都检查今天和昨天的文件。
- 上传：每小时把新记录作为一个新对象上传，对象名是机器编号、日期和起止序号，从不
  覆盖（请求带 `If-None-Match: *`）。上传失败下一轮重试，不丢。
- 时间戳：每天只发出一个 32 字节的指纹，记录本身不发出。回执存在
  `receipts/` 并一起上传。
- 保存 90 天（`RETENTION_DAYS`），本机到期自动删除。机器外的保存期由存储一侧的
  规则决定（见下）。
- 本机副本管理员能改，所以真正的防篡改靠"上传之后改不了"和时间戳。

## 要机主提供或决定的事

没有这些，监测照样运行，只在本机记录；`./verify.sh` 会提醒"上传目标没有配置"。
本仓库没有创建任何存储、账号或付费资源。

1. **存储服务**：任何支持 S3 接口的存储都行。建议 Cloudflare R2，理由是有免费额度、
   不收下载流量费，并且有"桶锁"防止删除和覆盖。2026-11-27 读取的官方价格页：标准
   存储每月 10 GB 免费，超出每 GB 每月 $0.015；写入类请求每月 100 万次免费；下载
   流量免费。官方说明要先在账号里开通 R2 才能生成 API 令牌。估算（推断，要在测试机
   上量）：每台每天约 1.5 MB、90 天约 130 MB，每月约 800 次写入，30 台都在免费额度内。
2. **一个桶**，例如 `v2cc-records`，加一条桶锁规则，锁定 90 天；再加一条 90 天后删除
   的生命周期规则。桶锁规则能被有"编辑桶配置"权限的令牌去掉，这个权限不要给机器。
3. **一个只给这个桶的 API 令牌**，权限选 "Object Read & Write"，限定到这个桶。需要的
   是它的 Access Key ID 和 Secret Access Key，以及账号 ID（拼成上传地址
   `https://<账号 ID>.r2.cloudflarestorage.com`）。
4. **令牌怎样放到机器上**：运维在机器的 `v2ccops` 终端里运行下面的命令，按提示输入
   两行，输入时不显示。凭证存在只有 root 能读的文件里（`upload-credential`，
   `root:600`），不进仓库、不进日志、不出现在命令行：

   ```sh
   ./monitor.sh configure --upload-endpoint https://<账号 ID>.r2.cloudflarestorage.com \
     --upload-bucket v2cc-records --upload-credential
   ```

5. **时间戳服务**：建议两个都用，都免费、不用注册（2026-11-27 读取的官方页面）：

   ```sh
   ./monitor.sh configure --ots-url https://a.pool.opentimestamps.org --tsa-url https://freetsa.org/tsr
   ```

6. **`/Applications` 里要检查签名的应用**（例如 UU远程 的实际路径，测试机上确认）：
   `./monitor.sh configure --check-apps "/Applications/<名字>.app"`。
7. **两个默认关闭的选项**是否开启（上一节）。

## 怎样看记录

在 `v2ccops` 里（或把上传的文件下载到自己的 Mac 上）：

```sh
D="/Library/Application Support/V2CC/monitor/records"
tail -n 1 "$D/$(date -u +%F).jsonl" | plutil -p -                       # 最新一条，易读格式
grep '"kind":"alert"' "$D"/*.jsonl                                        # 所有告警
/bin/bash "/Library/Application Support/V2CC/monitor/v2cc-monitor" check "$D"/*.jsonl   # 字段和哈希链
./monitor.sh status                                                       # 最近一次运行、上传
```

`check` 不需要 root，也可以在别的 Mac 上对下载的文件运行（用仓库里的
`monitor/v2cc-monitor.sh check`）。OpenTimestamps 回执（`.ots`）要过几小时后用
OpenTimestamps 的客户端补全和核对；RFC 3161 回执（`.tsr`）用 `openssl ts -verify`
和服务商的证书核对。

## 命令

```sh
./monitor.sh status                    # 任何账户
./monitor.sh install [--machine-id 编号] # bootstrap.sh 第 6 步已经做了
./monitor.sh configure ...             # 见上
./monitor.sh uninstall                 # 停止并删除，本机记录保留
./monitor.sh uninstall --delete-records
```

## 已知的不足

- GPU 只看整机利用率，不能对到具体程序（各程序的 GPU 时间要 `powermetrics`，格式没有
  在真机上核对，没有做）。
- UU远程 的连接不经过 macOS 自带的远程登录和屏幕共享，S9 看不到；只能从 S3、S5 里
  UU远程 进程的连接和流量看出有没有连接。锁屏和解锁事件没有取。
- S8（出口地址）要在接收端记录，机器上不做；直接上传到 R2 时没有这一项。
- `sfltool dumpbtm`、`log show` 里 `sshd`、`screensharingd`、`authd` 的消息格式，
  以及 R2 对 `If-None-Match` 的处理，只按文档和本机非 root 的输出写，没有在测试机上
  以 root 核对。
- 程序名名单和开发工具名单是起步名单，要按实际误报调整（配置项 `NAME_LIST`、
  `CPU_EXEMPT`）。
- 本机记录在上传前的一小时内，管理员能改。
