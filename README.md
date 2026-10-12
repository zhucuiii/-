# tc Limit Ports

使用 Linux `tc`/HTB 为一组 TCP/UDP 服务端口分别设置出口限速。

支持三种限速方式：

- **单端口限速**：只限制一个端口，例如 `8080=20mbit`
- **端口区间限速**：限制一段端口，区间内每个端口各自限速，例如 `10001-10200=12mbit`
- **区间共享限速**：一段端口合计共享一个速率，例如 `20000-20100=100mbit@shared`

## 快速使用

```bash
git clone https://github.com/zhucuiii/-.git
cd ./-

sudo install -m 0755 limit_ports.sh /usr/local/sbin/limit_ports.sh
sudo install -m 0644 config/limit-ports.example /etc/default/limit-ports
sudo install -m 0644 systemd/limit-ports.service /etc/systemd/system/limit-ports.service
sudo systemctl daemon-reload
sudo systemctl enable --now limit-ports.service
```

也可以像常见的一键脚本一样直接部署：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/zhucuiii/-/main/install.sh)
```

或者：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhucuiii/-/main/install.sh)
```

上面两条命令功能相同，选择其中一条执行即可。

安装后运行 SSH 菜单：

```bash
sudo /usr/local/sbin/portctl.sh
```

安装器会先把分支解析为一个固定提交，再从该提交下载全部组件，并检查 Bash 语法。
替换文件时保留原文件备份；安装失败会恢复安装前的文件，已有配置继续保留。
指定版本可设置 `INSTALL_REF`（分支、标签或完整提交 SHA）；设置 `RAW_BASE` 时由调用方确保组件版本一致。

如果希望安装后自动启用 systemd：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/zhucuiii/-/main/install.sh) --enable
```

安装脚本默认会在完成后自动打开 SSH 菜单，并创建快捷命令：

```bash
zc
```

如果只想安装、不自动打开菜单：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/zhucuiii/-/main/install.sh) --no-menu
```

## 配置需要限速的端口

编辑 `/etc/default/limit-ports` 里的 `PORT_SPEC`，一条规则的语法是：

```text
PORT[-END][=RATE][@per-port|@shared]
```

| 写法 | 含义 |
| --- | --- |
| `8080` | 单端口，使用 `SPEED` |
| `8080=20mbit` | 单端口，速率 20mbit |
| `10001-10200=12mbit` | 端口区间，区间内**每个端口各自** 12mbit |
| `20000-20100=100mbit@shared` | 端口区间，整个区间**合计** 100mbit |
| `443 8443=50mbit` | 多条规则用空格分隔 |

完整示例：

```bash
NIC="eth0"
SPEED="12mbit"
DEFAULT_RATE="1000mbit"
PORT_SPEC="10001-10200=12mbit 8080=20mbit 20000-20100=100mbit@shared"
```

`12mbit` 约等于 `1.5 MB/s`。规则之间不能有端口重叠，重叠会直接报错退出。

## 命令行用法

```bash
sudo /usr/local/sbin/limit_ports.sh apply
sudo /usr/local/sbin/limit_ports.sh apply --spec "8080=20mbit 10001-10100=8mbit"
sudo /usr/local/sbin/limit_ports.sh apply --start-port 10001 --end-port 10100 --speed 8mbit
sudo /usr/local/sbin/limit_ports.sh rules          # 打印解析后的规则
sudo /usr/local/sbin/limit_ports.sh stats          # 每个端口的字节/包计数（只读）
sudo /usr/local/sbin/limit_ports.sh plan -v        # 只打印将要执行的 tc 命令
sudo /usr/local/sbin/limit_ports.sh status
sudo /usr/local/sbin/limit_ports.sh stop
sudo /usr/local/sbin/limit_ports.sh config-state     # applied / pending / unknown
sudo /usr/local/sbin/limit_ports.sh effective-rates  # 从实际队列读取生效速率
sudo /usr/local/sbin/limit_ports.sh capacity         # 队列和统计容量
sudo /usr/local/sbin/limit_ports.sh coverage         # IPv4/IPv6 覆盖检查
sudo /usr/local/sbin/limit_ports.sh check            # 校验配置
```

`rules`、`stats` 和 `plan` 是只读动作，不需要 root，可以用来确认配置是否正确。

## SSH 终端控制台

仓库内的 `portctl.sh` 是纯 Bash 的 SSH 交互菜单，不需要网页、Node 或 Python：

```bash
chmod +x portctl.sh
sudo ./portctl.sh
```

菜单支持编号输入，当前已接入：

- `01` 端口限速
- `02` 防火墙规则
- `03` 限速服务
- `04` 日志中心
- `05` 系统与维护（系统信息、更新、卸载）
- `06` 用量与时段策略

后续要加新模块，直接在 `portctl.sh` 里写一个 `show_xxx_menu` 函数，再到 `draw_menu` 和 `main_menu` 里各加一行即可。

### 01 端口限速

进入 `01` 后可以看到当前的规则列表，并可以：

```text
1. 添加限速规则
2. 修改规则速率
3. 删除限速规则
4. 应用当前配置
5. 高级与排障
6. 用量与时段策略
0. 返回主菜单
```

- 添加规则统一接收单端口（`8080`）或区间（`10001-10200`），区间可以选择「每端口独立」或「区间共享」。
- 修改速率支持按编号修改单条规则，也可以统一修改全部规则；保留原有端口范围和共享方式。
- 高级与排障包含 tc 队列统计、只读执行计划、清空全部规则。清空必须输入 `YES` 确认。
- 菜单写入的规则会保存回 `/etc/default/limit-ports`，原来的注释和 `NIC`、`DEFAULT_RATE` 等配置不变。
- 新规则如果和已有规则端口重叠，会提示将被替换的规则并要求确认。
- 保存规则使用配置锁、原版本校验和同目录原子替换。其他 SSH 会话修改过配置时，
  本次保存会拒绝覆盖并提示刷新；无效候选配置不会替换旧文件。
- 主菜单显示配置是否已应用，规则表分别显示基础速率和从内核读取的生效速率。
  生效版本保存在 `/var/lib/portctl/limits/`；保存了新规则但尚未应用时，策略不会把新端口映射到旧队列。
- 限速默认最多 4096 个队列，逐端口统计默认最多 512 个端口（`MAX_CLASSES` / `ACCT_MAX_PORTS`）。
  超过统计容量的大区间仍可限速和使用时段策略，月额度与用量降速会提前提示不可用。

- 速率输入是纯数字，单位单独选择：

  ```text
  1. Mbit/s
  2. MB/s
  3. Gbit/s
  4. GB/s
  ```

### 流量统计命令

主菜单和「端口限速」子菜单已移除「流量查看」选项。底层统计和命令行仍然保留，
供月度流量额度、用量触发降速及排障使用，不影响已有统计数据或策略。

```bash
sudo portctl.sh traffic       # 全部端口流量快照
sudo portctl.sh acct-setup    # 建立 / 重建端口双向统计
sudo portctl.sh acct-sample   # 保存一次累计快照
sudo portctl.sh acct-show     # 查看累计用量
sudo portctl.sh acct-reset    # 清零保存的累计用量
sudo portctl.sh acct-remove   # 移除统计规则
```

- 统计需要 nftables 命名计数器和 map 支持（内核 4.10+ / nftables 0.8+）。
  首次使用先配置端口规则，再执行 `sudo portctl.sh acct-setup`；用量策略开启自动执行时会启用统计恢复和采样。
- 上行按目标端口 `dport`、下行按源端口 `sport` 计数，包含 IP 层开销，不是应用净载荷。
- `ACCT_SCOPE` 在 `/etc/default/limit-ports` 中指定统计范围，默认 `all`：
  `all` 包含本机、转发、回环及容器路径；`local` 仅统计当前网络命名空间的本机收发；
  `forward` 仅统计路由转发。`all` 入站在 DNAT 前计数，`local` 入站和 `forward` 在 DNAT 后计数，
  使用 NAT / 容器时应检查实际匹配端口，用户态代理可能重复匹配。
- 更改范围后执行 `sudo portctl.sh acct-setup`。重建保留历史总量，跨范围累计标记为 `mixed`；
  需要单一口径时再显式执行 `acct-reset`，并检查已有额度策略。`acct-show` 的 `#SCOPE` 行显示历史范围。
- 累计快照保存在 `/var/lib/portctl/traffic.tsv`。采样不会清零内核计数器，
  用量和原始计数基线一起原子保存；失败保留旧数据，后续采样可补记。
- 建立 / 重建统计先执行 `nft -c` 校验。端口配置或统计范围改变导致采样失败时，执行 `acct-setup` 重建。
  重建或移除统计表的切换期间仍可能漏计少量流量；自动采样跨重启最多丢失最后一分钟。
- `acct-reset` 只更新累计值和基线，不清零内核计数器；`acct-show` 只读，统计表不存在时显示已保存累计，
  真正的计数器读取故障返回非零退出码，不会当作零流量。

### 02 防火墙规则

`02` 用一个声明式规则文件管理防火墙，规则保存在 `/etc/default/portctl-firewall.conf`：

```text
backend auto
ssh-protect yes

allow tcp 22
allow tcp 10001-10200
deny tcp 3306
allow tcp 8080 from 1.2.3.4
deny all all from 198.51.100.0/24
```

一条规则的语法是：

```text
<allow|deny> <tcp|udp|all> <端口|起始-结束|all> [from <IP|CIDR>]
```

菜单里可以：

```text
1. 添加防火墙规则
2. 删除防火墙规则
3. 应用当前配置
4. 高级与排障
0. 返回主菜单
```

几个关键设计：

- 添加规则时再选择端口或来源 IP；系统实际规则、后端设置、清空操作统一放到高级与排障。
- **后端自动探测**：按 `iptables → nftables → ufw` 的顺序选择，也可以在「高级与排障 > 后端与开机自启设置」里固定。
- **规则只影响新建连接**（`ct state new`）：下发规则不会中断已经建立的会话，包括你正在使用的 SSH。
- **独占自己的链/表**：iptables 用 `PORTCTL` 链，nftables 用 `inet portctl` 表。删除和清空是精确操作，不会误删你原有的规则。
  链会被插到 `INPUT` 的第一位，所以放行规则才能生效；不匹配的流量原样穿过，继续走你原有的规则。
- **只有链不碰策略**：脚本不会修改 `INPUT` 的默认策略，也不会关闭你的防火墙。
- **批量替换与失败恢复**：nft 后端先校验，再在同一事务里替换专属表；
  iptables 后端使用 `iptables-restore --noflush` / `ip6tables-restore --noflush`，
  先校验两个协议族，只更新专属链和对应入口。如果第二个协议族提交失败，会恢复第一个协议族的旧专属规则。
- **SSH 防锁死**：下发前会检查规则是否封禁了 SSH 端口（端口从 `SSH_CONNECTION`、`sshd -T`、`sshd_config` 依次探测），
  有风险时会告警并要求输入 `FORCE` 才继续，还会主动提出加一条「允许当前 IP 访问 SSH 端口」的临时保护规则
  （只在下发时生效，不写入配置文件）。
- **开机自动恢复**：在后端与开机自启设置里开启后会生成 `portctl-firewall.service`（`ExecStart` 调 `portctl.sh firewall-apply`，
  `ExecStop` 调 `firewall-clear`），不依赖 `iptables-persistent` 之类的额外软件包。
- **整份校验**：错误端口、缺失字段、额外字段和错误后端设置会拒绝整份配置，不再忽略错误行后部分下发。
  防火墙保存也会检查原版本并原子替换，菜单确认后配置发生变化会拒绝下发。
- **统一 SSH 防护**：菜单、命令行和开机恢复都经过同一个下发检查。
  命令行确实需要覆盖 SSH 防护时使用 `firewall-apply --force`；持久配置可显式设为 `ssh-protect no`。
  开机时没有当前客户端 IP，来源受限的临时 SSH 放行规则不能视为永久保护。

不开菜单也可以直接用命令行：

```bash
sudo /usr/local/sbin/portctl.sh firewall-apply     # 按配置下发（systemd 调用的就是它）
sudo /usr/local/sbin/portctl.sh firewall-status    # 只看解析结果，不需要 root
sudo /usr/local/sbin/portctl.sh firewall-clear     # 移除本程序创建的链/表
```

### 03 限速服务

顶部显示 `limit-ports.service` 的运行与自启状态。启动、重启、停止、开启自启、关闭自启、详细状态分别操作。
启动不会自动开启自启，关闭自启不会自动停止当前服务。无 `systemctl` 时明确提示不可用。

### 04 日志中心

`04` 汇总了排查这套工具需要的所有日志：

```text
[04] 日志中心
来源: journald    持久化: 是    占用: 88.0M

1. 服务日志
2. 系统错误日志
3. 登录记录（成功 / 失败）
4. 实时跟踪
5. 导出诊断日志
6. 高级与清理
0. 返回主菜单
```

- 每个视图都会先问 `显示条数 [40]`，直接回车用 40 条，也可以输入任意条数（上限 5000）。
- 服务日志内选择限速服务或防火墙服务；高级与清理内查看内核、全部系统日志，或清理日志。
- `3` 同时给出 `last`（成功登录）、`lastb`（失败登录）和 SSH 认证日志里的 `accepted / failed / invalid` 记录。
- `4` 实时跟踪时父进程会忽略 `SIGINT`，所以按 `Ctrl+C` 只结束 `journalctl`，会回到菜单而不是退出整个控制台。
- `5` 导出的是**诊断包**，不只是日志：两个服务的日志、系统错误、`tc` 规则与统计、防火墙规则、端口监听、
  本程序的两份配置、两个服务的状态，一次性打包成 `/root/portctl-diag-<时间戳>.txt`，方便贴给别人看。
- 高级与清理内可以按时间（保留 7 天 / 3 天）或按大小（200M / 500M）清理 journal，需要输入 `YES` 确认。
  顶部会显示日志是否持久化 —— 如果显示「否」，说明日志只在内存里，重启就丢，
  可以在 `/etc/systemd/journald.conf` 里设置 `Storage=persistent`。
- 系统没有 `journald` 时会自动回退到 `/var/log/syslog` 或 `/var/log/messages`（按关键字过滤），
  两者都没有就明确提示找不到日志来源。

### 05 系统与维护

包含系统信息、从 GitHub 更新脚本和卸载程序。卸载不再作为主菜单的独立入口，仍需要输入 `YES` 确认。
更新保留已有配置，安装失败会显示错误；更新成功后重新打开 `zc` 使用新版本。

### 06 用量与时段策略

策略绑定到已有的限速规则，不改写基础配置；多条策略同时命中时取更低速率。
需要先建立端口规则和流量统计，再开启每分钟自动执行。

```text
1. 添加月度流量额度
2. 添加用量触发降速
3. 添加每日时段限速
4. 手动解除用量降速
5. 删除策略
6. 开启自动执行
7. 关闭自动执行并恢复基础速率
8. 立即执行 / 刷新
```

- **月度流量额度**：上传+下载合计达到额度后进入策略速率，每月 1 日重新计量；手动解除后本月豁免。新建策略从创建时开始计量，不追溯之前的流量。
- **用量触发降速**：达到指定 GB 后降速，可选择持续小时数、指定解除日期时间或仅手动解除；解除后重新开始下一轮计量。
- **每日时段限速**：按服务器时区每天生效，支持跨午夜，例如 `23:00` 到 `07:00`。
- 策略只绑定基础规则的完整端口范围；基础规则范围变化后会提示重新设置策略。
- 独立区间策略会更新区间内的每个队列，共享区间更新一个队列；有效速率未变化时不重复调用 `tc -batch`。
- `apply`、`rate-set` 和 `stop` 使用同一网卡锁，菜单操作与定时策略不会同时修改该网卡。
- 速率换算、队列比较及 burst 计算按批次处理并缓存相同速率；
  200 个速率未变化的独立队列检查只需常数次数的 `awk` 调用。
- 开启用量策略自动执行时，会启用基础限速服务和流量统计恢复，生成
  `limit-ports.service → portctl-accounting.service → portctl-policy.service` 的依赖顺序。
  纯时段策略只依赖基础限速服务，不受流量统计容量限制。
- 策略执行会恢复缺失的统计表；查看状态不会自动改动内核规则。
  页面显示实际生效速率、剩余额度、解除时间和最近执行结果，执行记录保存在
  `/var/lib/portctl/policy/last-run.tsv`。
- 配置保存在 `/etc/default/portctl-policy.tsv`，运行状态保存在 `/var/lib/portctl/policy/state.tsv`。
- `portctl-policy.timer` 每分钟执行一次，也可以手动执行刷新。

从旧版升级后，请先在「端口限速」中应用一次当前配置，以建立生效版本记录；
已经开启策略自启的用户，再选择一次「开启自动执行」，更新 systemd 依赖。

## 回归测试

在 Bash 环境下运行，无需 root，不会修改系统限速或防火墙：

```bash
bash -n portctl.sh
bash tests/accounting.sh
bash tests/menus.sh
bash tests/policy.sh
bash tests/reliability.sh
bash tests/install.sh
bash tests/optimizations.sh
```

菜单测试使用模拟命令检查导航、服务操作和日志入口，并在临时目录验证规则编辑及危险操作取消。
它不替代真实 Linux 内核上的 tc/nftables 集成测试。

GitHub Actions 还会在隔离的 Linux 网络命名空间中运行真实内核测试，
覆盖 IPv4/IPv6 分类器、独立/共享区间降速、流量快照及防火墙失败保留。
本地 Linux 上可使用以下命令（需要 `iproute2`、`nftables`、`iptables`）：

```bash
sudo unshare -n env PORTCTL_TEST_NETNS=1 bash tests/integration.sh
```

## 限速实现细节

`limit_ports.sh` 的工作原理，以及几条容易被忽略的边界：

- **分类器用 `flower`，同时覆盖 IPv4 和 IPv6**。旧版用 `u32` + `protocol ip`，**IPv6 包不匹配任何 filter，会落到默认队列，等于完全绕过了限速**（实测 IPv6 能跑满链路）。
  `flower` 还支持端口区间，`@shared` 模式下整个区间只需要一条 filter。默认 `IPV6_STRICT=yes`：检测到网卡有 IPv6 但只能使用 `u32` 时拒绝应用，避免误以为 IPv6 也受控；只有明确设置 `IPV6_STRICT=no` 才允许 IPv4-only 降级。

- `IPV6_MODE=yes` 始终生成 IPv6 规则；`auto` 按网卡全局 IPv6 地址判断，地址出现或消失会使 `config-state` 变为 `pending`，需要重新应用。只读 `coverage` / `status` 检查内核过滤器是否覆盖全部计划队列；`filters-present` 表示已发现对应过滤器，并不代表已经做过实际吞吐测试。`IPV6_MODE=no` 是显式关闭，严格模式不会替用户重新打开。该检查不是后台地址监控；需要预防后来分配的 IPv6 时建议使用 `yes`。
- **IPv4 和 IPv6 必须用不同的 filter `prio`**。同一个 parent 下两个协议族共用一个 prio，内核会返回
  `Filter with specified priority/protocol not found`。默认 `FILTER_PRIO=10`（IPv4）、`FILTER_PRIO6=11`（IPv6）。
- **默认 class 只保证很小的带宽**（`DEFAULT_GUARANTEE`，默认 `1mbit`），`ceil` 才是链路容量（`DEFAULT_RATE`）。
  HTB 的 `rate` 是**保证**带宽而不是上限，所以旧写法把 `rate` 和 `ceil` 都设成链路容量是不准确的；
  空闲时默认 class 仍然可以 burst 到 `DEFAULT_RATE`。
- **每个限速 class 下面挂 `fq_codel`**。否则叶子队列是纯 FIFO，限速一开延迟就飙（bufferbloat）。
- **显式设置 `burst`/`cburst`**。不设置时 tc 用的是刚好卡在最小值的默认值，实测速率会略低于配置值；
  留空则按 `rate` 自动计算（一个调度 tick 的发送量），也可以用 `BURST`/`CBURST` 覆盖。
- **整批命令用一次 `tc -batch` 下发**。旧版是每端口、每规则各调一次 `tc`（200 个端口约 600~1000 次进程调用），
  现在是 1 次。成功应用后，将批次与配置签名原子保存到 `/var/lib/portctl/limits/<NIC>.batch`。
  下次替换前读取实时队列速率；失败时重建上一套端口规则，并恢复当时的策略速率。
  速率批量更新部分失败也会反向恢复旧 rate/ceil。恢复失败会明确报错；首次应用或从旧版升级尚无快照时，只能清理半套规则并回到不限速。
  这是失败后的尽力恢复，不是内核原子切换：切换期间有短暂空窗，重建会重置 tc 队列计数和排队状态，不影响独立的 nft 累计统计。快照仅用于本脚本拥有的 root qdisc，不会备份其他工具创建的队列。
- **下发前先在临时 `dummy` 网卡上试跑同一批命令**（`PRECHECK`，默认 `auto`）。预检不通过就直接放弃，
  真实网卡**完全不会被碰**，现有队列保持原样。
- **端口区间不要和内核临时端口范围重叠**。服务器自己的出站连接源端口取自
  `net.ipv4.ip_local_port_range`，如果和限速区间重叠，这些无关连接会被一起限速。
  脚本检测到重叠时会打印提示，建议收窄为 `32768 60999`：

  ```bash
  sysctl -w net.ipv4.ip_local_port_range="32768 60999"
  ```

## 说明

- 当前规则塑形的是出口流量，使用服务端 TCP/UDP 源端口匹配。
- 若要限制进入服务器的请求流量，需要增加 IFB ingress 规则。
- 脚本会接管网卡的整个 root qdisc，不能与其他 QoS、Docker 或 Kubernetes 流量控制直接叠加。
- `DEFAULT_RATE` 应设置为服务器实际链路速率，用于承载未匹配的流量。
- 区间共享（`@shared`）会让整段端口共用一条 HTB 队列，端口很多时建议用它，减少 `tc` 队列数量。
- 防火墙规则按文件里的顺序匹配，所以「先放行某个 IP，再封禁整段」的白名单写法是有效的；但 `ufw` 后端由 ufw 自己排列规则顺序，这种写法不保证生效，需要严格顺序时请用 `iptables` 或 `nftables` 后端。
- 本程序不会接管或清空系统已有的防火墙规则，卸载时也不会主动撤销已下发的规则（`sudo portctl.sh firewall-clear` 可以手动清掉）。
