# Hermes 自动更新

（英文名：Hermes Auto-Update）

简体中文 · [English](README.en.md)

让 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 自己更新自己：一条系统 cron 定时跑更新脚本，跑在 gateway 进程树之外，只在发生真实结果时才发 Telegram 通知。

当前版本：**updater v5.15**（这是更新器自身的版本号，和它安装的 Hermes 版本是两回事；变更见下文“v5.15 变更说明”）。

## 支持边界 / 免责声明

会 hard-reset 一个 git 检出、并以 root 无人值守地重启 gateway。仅适用 Linux + systemd + git 安装。尽力支持。

## 为什么是系统 cron，不是 hermes cron

<p align="center"><img src="assets/in-tree-deadlock.png" width="720" alt="死锁成因：hermes cron 作业在 gateway 进程树内启动更新器，更新器等待 gateway 重启，而 gateway 是更新器的父进程——更新器不退出，gateway 不能重启"></p>

hermes cron 作业活在 gateway 进程树里——这是所有更新竞态的根源：更新器只能在自己退出后通知重启，在脚本内等待重启必然死锁，fleet 检查必然报 STALE。放到进程树外，更新器可以自己排空 gateway、用 systemd 重启、退出前亲自验证 fleet，于是脚本可以同步验证。

<p align="center"><img src="assets/out-of-tree-flow.png" width="520" alt="修复后的流程：系统 cron 触发 → flock 加锁 → 检查更新 → AU_APPLY 闸门 → 更新 → 排空 → systemd 重启 → 自己验证 fleet → 三分支通知"></p>

（图源：`assets/src/in-tree-deadlock.puml`、`assets/src/out-of-tree-flow.puml`，用 `plantuml -tpng` 重新生成。）

## 安装

```bash
bash install.sh    # 只做前置检查——绝不运行更新器
```

推荐调度（install.sh 会打印，crontab.txt 里也有）：

```cron
23 3 * * * set -a; [ -f $HOME/.hermes/scripts/auto_update.env ] && . $HOME/.hermes/scripts/auto_update.env; set +a; AU_APPLY=1 $HOME/.hermes/scripts/auto_update.sh >> $HOME/.hermes/logs/auto_update_cron.log 2>&1
```

`set -a` 不是摆设：没有它，env 文件对脚本**什么都没传**（裸 `. file` 只把变量设在调度器 shell 里，它立刻退出，而更新器自己从不 source 这个文件）。`[ -f ]` 守卫防止 env 文件还没建时整行在 `AU_APPLY=1` 送达之前就中止。`scripts/schedule_delivery.sh` 在 bash/dash/sh 下各跑一遍这个调度形状（env 文件在/不在两种情况），报告子进程实际继承了什么。

## 各主机的变量

| 变量 | 作用 |
|---|---|
| `AU_APPLY=1` | 调度命令里**必须**带——不带 = 只报告、永不安装 |
| `TG_PROXY=""`（空值） | Telegram 直连。**必须放在 `~/.hermes/scripts/auto_update.env`** ——调度器 source 的那个文件。放 `~/.hermes/.env` 的副本永远到不了脚本（脚本读那个文件只为取 bot token + chat id）。空值是有效配置，别删这个变量。 |
| `AU_REPO_DIR` / `AU_HERMES_BIN` | 非默认检出 / 二进制路径 |
| `AU_GATEWAY_STATE` / `AU_GATEWAY_UNIT` / `AU_CRON_UNIT` | systemd 细节 |
| `AU_CHECK_ALERT_INTERVAL` | 检查失败告警的重发间隔（秒，默认 `86400`）。必须是正整数秒；非法值、空值或 `0` 都回退到默认值 |
| `AU_REALERT_SECS` | 真实安装失败、通知送达失败的重发间隔（秒，默认 `255600` = 3 天 − 1 小时）。规则同上 |
| `AU_ROLLBACK_REMIND_SECS` | “检出比所选正式版新”的提醒间隔（秒，默认 `601200` = 7 天 − 1 小时）。规则同上 |

完整清单见 SKILL.md 和 references/wsl-deployment.md。

## 通知设计

已是最新时静默。安装成功发 `✓`（标题写 Hermes 版本，注明 updater 版本），失败发 `✗`。

### `update --check` 怎么判

上游 `hermes update --check` **没有机器可读输出**：`--check` 只是一个布尔参数（`hermes_cli/subcommands/update.py:18-20`），每种结论都是一行 `print()` 然后退出码 0（`hermes_cli/update_cmd_check.py:97-125`、`:191-228`；该文件在 v0.23.1 / v0.23.2 / 上游 main 67e4d22 字节一致）。所以文字就是契约，按**整行**匹配上游原句（去掉行首尾空白和一个行尾 CR）：

| 结论 | 上游原句（`update_cmd_check.py`） | 动作 |
|---|---|---|
| 已是最新 | `:110` `✓ No newer release: {label}.`、`:112` `✓ Up to date with the latest release ({label}).`、`:200/:208/:222` `✓ Already up to date.` | 静默，不安装，不算检查失败 |
| 暂缓（hold） | `:115` `→ Holding at this build: {label} predates the gateway runtime your sessions use.` | 同上，记一行日志 |
| 检出比所选正式版新 | `:119` `→ This checkout is newer than the selected release: {label}.` | **绝不**自动 `--yes`（会降级）；不算检查失败；按 `AU_ROLLBACK_REMIND_SECS` 低频提醒人工处理 |
| 有更新 | `:123` `→ Selected release available: {label}`、`:212/:225` `⚕ Update available: N commit(s) behind <ref>.`、`:214` `⚕ Update available (behind <ref>).` | 只进入 `AU_APPLY` 闸门；版本号从更新完成行取（新格式 `旧 → 新` 取后者，旧格式单一版本），不从检查行取 |
| 未知 | 其它一切 | 不安装，计入检查失败，连续第 3 次告警 |

- `{label}` 形如 `stable v0.23.2 (ae2a81ccc00e)`（`source_releases.py:61-65`）；`No newer release` 还有“检出更新、等下一个正式版”的长形式，也认。
- 旧版 main 通道的同两句曾用 `☤` 字形（v2026.9.24），再早是 `⚕`；没有任何发布版打印过**无字形**的 `--check` 结论，所以无字形行不认。
- 只作上下文、不带结论的已知行：`:97` 通道横幅、`:108` retired 行、`:116-117/:120-121/:124/:215/:228` 提示行、`:143/:164` `→ Fetching from …...`、`:49/:52/:62/:65/:180/:183` 的 `  (…)` 清理日志行。
- **否决**：任何含 `✗` 的行、任何含 `error` / `failed` / `timed out`（不分大小写）的行、任何其它不认识的非空行、或出现两种不同结论 → 整体判为未知。宁可报警，不当“无更新”，更不安装。

### `--yes` 的“无事可做”

`--yes` 退出码 0 但本轮没有自己的收据时，只有在输出里有“无事可做”行（如 `update_cmd.py:1726` 的 `✓ Already up to date!`、`:1911` 的 `✓ Holding at this build until a newer … release ships.`）**并且**同一输出没有被否决（`✗` 行、含 error/failed/timed out 的行、或一行“有更新”/“检出更新”结论）时，才当作无事可做；被否决 → 按真实失败处理（计数、告警、退出 1）。合法的无事可做（检查期与 `--yes` 期都算）在 drain 复核之后把 `consec_real_fails` 清零，旧故障不会吞掉下一次新故障的首次告警。

### 告警节奏（全部按墙钟）

| 告警 | 首次 | 之后 | 变量（秒） | 默认值与理由 |
|---|---|---|---|---|
| 检查失败 / 未知（`⚠`） | 连续第 3 次 | 每 `AU_CHECK_ALERT_INTERVAL` | `AU_CHECK_ALERT_INTERVAL` | `86400`：流水线卡住每天提醒一次。时间戳记的是**本次 tick 的启动时刻**，每日 cron 的相邻两次 tick 正好相差 86400 秒（启动延迟是毫秒级），所以检查本身耗时 1 秒还是 300 秒都不会让重报顺延一天 |
| 真实安装失败（`✗`） | 第 1 次立即 | 每 `AU_REALERT_SECS` | `AU_REALERT_SECS` | `255600`（3 天 − 1 小时）：每日重试的同一个坏安装是同一事件，每第 3 个每日 tick 提醒一次；减 1 小时是给调度抖动的余量，避免顺延到第 4 天 |
| 通知送达失败（死信 + 附加告警） | 连续第 3 次 | 每 `AU_REALERT_SECS` | 同上 | 本地死信 `notify_dead_letter.log` 就是“已送达”的产物，所以与死信同时写时间戳 |
| 检出比所选正式版新（`→`） | 进入该状态时 | 每 `AU_ROLLBACK_REMIND_SECS` | `AU_ROLLBACK_REMIND_SECS` | `604800 − 3600`（7 天 − 1 小时）：需要人做决定，不是紧急事件，每周提醒一次 |

- 所有时间戳（`check_alert_last_ts`、`real_alert_last_ts`、`notify_alert_last_ts`、`rollback_remind_ts`）都经同一个读取器：空、乱码、超长、负号、或比现在晚 300 秒以上 → 视为“没有时间戳”，立即告警，送达后覆盖（自愈），不会让 `set -u` 崩溃，也不会永久静默。
- 时间戳**只在送达后**写入（死信例外，见上）。送达失败时，下一次 tick 重试。
- 变量非法、为空、为 `0` 或超过 9 位 → 回退默认值；`00060` 解析为 60。
- 迁移：旧版本留下的计数如果已经大于阈值、又没有时间戳，下一次会告警一次；旧的一次性标记 `rollback_notified` 不再让提醒永久静默。

### 告警内容

检查失败告警带连续失败次数、上次成功安装时间（在首次经证明的安装之前显示“unknown”）、以及真实错误摘要：先选含 `✗` / error / failed / timed out 的行（各带下一行作上下文），剩余名额再按顺序补其它行，最后才限长（6 行、每行 200 字节、总计 1000 字节）。错误排在一屏清理日志之后也不会被截掉。

只有绑定到本次调用的安装证明才能证明一次安装：一份新鲜的、不可变的本次运行收据，加上肯定的完成结果或代码变动。过期的、缺失的、属于其他操作（如 `kind=plugin-check`）的或无变化的收据都不能证明安装。

## v5.15 变更说明

- `--check` 结论按上游整行原句匹配并加否决（见上），未知输出一律报警、不安装。
- `--yes` 无事可做先过否决再接受；被否决按真实失败处理。所有合法无事可做出口都会清零真实失败计数。
- 真实失败、通知送达失败、“检出更新”提醒都改为按墙钟节奏（新变量 `AU_REALERT_SECS`、`AU_ROLLBACK_REMIND_SECS`），不再按 tick 次数（每日调度下“每 12 次”= 12 天）。
- 检查失败告警摘要优先选错误行。
- **行为变化**：`--yes` 退出码 0 但本轮没有自己的新鲜收据时，**不再当作成功**——有完成行 → “安装未经证明”告警、设 `drain_pending`、退出 1；输出不认识 → 告警、退出 1。不写更新收据的 Hermes 构建因此每次安装都会告警；请确认目标 Hermes 版本会写 `~/.hermes/logs/update_receipts/latest.json`。

## 文件

- `auto_update.sh` —— 更新器本体（UPDATER_VERSION 5.15）
- `LICENSE` —— MIT
- `scripts/release_gate.sh` —— 发布前必跑：文档指针 + 测试矩阵 + 探针 + 破坏性验证（teeth）
- `scripts/schedule_delivery.sh` —— 验证推荐调度形状是否真的送达 env 和 flag
- `scripts/marker_lifecycle_sweep.sh`、`scripts/counter_sanity.sh` —— 配套探针
- `scripts/check_compat_sanity.py` —— `--check` 结果兼容性检查，运行方式为 `python3 scripts/check_compat_sanity.py auto_update.sh`，属于发布闸门的一部分
- `verify/` —— 全封闭测试具（stub hermes/curl/systemctl）；矩阵即契约的可执行形式
- `references/` —— 收据字段契约、WSL 部署、打包验证、健康夹具

## 验证

从解压后的目录跑：

```bash
bash scripts/release_gate.sh
```

要求 PASS。闸门包含 `python3 scripts/check_compat_sanity.py auto_update.sh`。矩阵和兼容探针是脚本行为的可执行契约（场景数以它们自己打印的统计为准，不在文档里抄写）；验收点与测试的对应关系见 `verify/README.md`。

sha256（auto_update.sh，updater v5.15）: `bacbf28e4ca0fe35a547988f2810b22d82cc9c5016dfd2cb5cb2b8e49d0500d3`
_重新打包前用 `sha256sum auto_update.sh` 重新生成。_
