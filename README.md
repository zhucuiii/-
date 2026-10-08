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
- `02` 系统信息
- `03` 服务管理
- `04` 防火墙规则
- `05` 日志中心
- `06` 从 GitHub 更新脚本
- `07` 卸载程序

后续要加新模块，直接在 `portctl.sh` 里写一个 `show_xxx_menu` 函数，再到 `draw_menu` 和 `main_menu` 里各加一行即可。

### 01 端口限速

进入 `01` 后可以看到当前的规则列表，并可以：

```text
1. 立即应用当前配置
2. 区间限速（批量端口）
3. 单端口限速
4. 统一修改全部规则速率
5. 删除限速规则
6. 清空全部规则
7. 查看 tc 规则统计
8. 端口实时流量（每端口=每用户）
9. 全部端口流量监控（实时刷新）
0. 返回主菜单
```

- 区间限速会让你输入起始端口、结束端口和速率，再选择「每端口独立」或「区间共享」。
- 单端口限速只输入一个端口和速率。
- 菜单写入的规则会保存回 `/etc/default/limit-ports`，原来的注释和 `NIC`、`DEFAULT_RATE` 等配置不变。
- 新规则如果和已有规则端口重叠，会提示将被替换的规则并要求确认。
- **`8` 端口实时流量**：采样 3 秒，按当前速率降序列出每个端口（也就是每个用户）的实时速度、累计流量和包数：

  ```text
    端口             限速       当前速率     累计流量      包数
    10090            50mbit     1.34 MB/s    49.97 MB      201184
    10081            12mbit     485.0 KB/s   6.75 MB       48210
    10099            12mbit     0 B/s        0 B           0

    端口总数 4   正在跑 3   累计 0 字节 1
    合计速率: 16.83 Mbit/s
  ```

  它同时也是**「限速到底有没有匹配上」的验证手段**：如果某个用户明明在传数据、这里却一直是 0 字节，说明这个端口的流量没被 filter 匹配到。
- **`9` 全部端口流量监控**：和 `8` 不是一回事。`8` 读的是 tc 的 class 计数，**只覆盖 `PORT_SPEC` 里的端口**；`9` 读的是内核连接跟踪表（`/proc/net/nf_conntrack`），**所有端口都在监控范围内**，包括没有被限速的：

  ```text
  [01-9] 全部端口实时流量   20:53:57   每 2 秒刷新，Ctrl+C 返回

    端口         协议     当前速率       连接数     限速
    10123        tcp      51.8 KB/s      1          12mbit
    10086        tcp      8.3 KB/s       1          12mbit
    443          tcp      820 KB/s       5          —
    22           tcp      2.1 KB/s       1          —

    活跃端口 4   合计 0.91 MB/s
  ```

  - **只显示这段时间里真的有流量经过的端口**，没流量的直接不出现
  - 最右边标出这个端口有没有被限速（对应 `PORT_SPEC`），所以它同时是一个**「谁在偷跑」检测器**：右侧是 `—` 却在大流量跑，就是没被限速的端口
  - `Ctrl+C` 返回菜单，不会退出整个控制台
  - 只统计**本机作为服务端**的连接（原始方向的目的地址是本机），所以不会把 docker-proxy 到容器的那一段重复计算

  注意它的边界：**实时速率可靠，但"累计流量"不可靠** —— 连接跟踪表里的计数会随连接超时被回收。要看累计流量用 `8`（tc 计数是内核持久计数）。

  不开菜单也能取快照：`portctl.sh traffic`
- 速率输入是纯数字，单位单独选择：

  ```text
  1. Mbit/s
  2. MB/s
  3. Gbit/s
  4. GB/s
  ```

### 04 防火墙规则

`04` 用一个声明式规则文件管理防火墙，规则保存在 `/etc/default/portctl-firewall.conf`：

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
1. 立即应用当前配置
2. 添加端口规则（放行 / 封禁）
3. 添加来源 IP 规则（放行 / 封禁）
4. 删除规则
5. 清空全部规则
6. 查看系统实际规则
7. 后端与开机自启设置
0. 返回主菜单
```

几个关键设计：

- **后端自动探测**：按 `iptables → nftables → ufw` 的顺序选择，也可以在 `7` 里固定。
- **规则只影响新建连接**（`ct state new`）：下发规则不会中断已经建立的会话，包括你正在使用的 SSH。
- **独占自己的链/表**：iptables 用 `PORTCTL` 链，nftables 用 `inet portctl` 表。删除和清空是精确操作，不会误删你原有的规则。
  链会被插到 `INPUT` 的第一位，所以放行规则才能生效；不匹配的流量原样穿过，继续走你原有的规则。
- **只有链不碰策略**：脚本不会修改 `INPUT` 的默认策略，也不会关闭你的防火墙。
- **SSH 防锁死**：下发前会检查规则是否封禁了 SSH 端口（端口从 `SSH_CONNECTION`、`sshd -T`、`sshd_config` 依次探测），
  有风险时会告警并要求输入 `FORCE` 才继续，还会主动提出加一条「允许当前 IP 访问 SSH 端口」的临时保护规则
  （只在下发时生效，不写入配置文件）。
- **开机自动恢复**：`7` 里开启后会生成 `portctl-firewall.service`（`ExecStart` 调 `portctl.sh firewall-apply`，
  `ExecStop` 调 `firewall-clear`），不依赖 `iptables-persistent` 之类的额外软件包。

不开菜单也可以直接用命令行：

```bash
sudo /usr/local/sbin/portctl.sh firewall-apply     # 按配置下发（systemd 调用的就是它）
sudo /usr/local/sbin/portctl.sh firewall-status    # 只看解析结果，不需要 root
sudo /usr/local/sbin/portctl.sh firewall-clear     # 移除本程序创建的链/表
```

### 05 日志中心

`05` 汇总了排查这套工具需要的所有日志：

```text
[05] 日志中心
来源: journald    持久化: 是    占用: 88.0M

1. 限速服务日志          2. 防火墙服务日志
3. 系统错误日志          4. 登录记录（成功 / 失败）
5. 内核日志              6. 全部系统日志
7. 实时跟踪（Ctrl+C 返回）  8. 导出诊断日志到文件
9. 清理日志              0. 返回主菜单
```

- 每个视图都会先问 `显示条数 [40]`，直接回车用 40 条，也可以输入任意条数（上限 5000）。
- `4` 同时给出 `last`（成功登录）、`lastb`（失败登录）和 SSH 认证日志里的 `accepted / failed / invalid` 记录。
- `7` 实时跟踪时父进程会忽略 `SIGINT`，所以按 `Ctrl+C` 只结束 `journalctl`，会回到菜单而不是退出整个控制台。
- `8` 导出的是**诊断包**，不只是日志：两个服务的日志、系统错误、`tc` 规则与统计、防火墙规则、端口监听、
  本程序的两份配置、两个服务的状态，一次性打包成 `/root/portctl-diag-<时间戳>.txt`，方便贴给别人看。
- `9` 可以按时间（保留 7 天 / 3 天）或按大小（200M / 500M）清理 journal，需要输入 `YES` 确认。
  顶部会显示日志是否持久化 —— 如果显示「否」，说明日志只在内存里，重启就丢，
  可以在 `/etc/systemd/journald.conf` 里设置 `Storage=persistent`。
- 系统没有 `journald` 时会自动回退到 `/var/log/syslog` 或 `/var/log/messages`（按关键字过滤），
  两者都没有就明确提示找不到日志来源。

## 限速实现细节

`limit_ports.sh` 的工作原理，以及几条容易被忽略的边界：

- **分类器用 `flower`，同时覆盖 IPv4 和 IPv6**。旧版用 `u32` + `protocol ip`，**IPv6 包不匹配任何 filter，会落到默认队列，等于完全绕过了限速**（实测 IPv6 能跑满链路）。
  `flower` 还支持端口区间，`@shared` 模式下整个区间只需要一条 filter。内核没有 `flower` 时自动回退到 `u32`（此时只有 IPv4 受控，日志里会明确提示）。
- **IPv4 和 IPv6 必须用不同的 filter `prio`**。同一个 parent 下两个协议族共用一个 prio，内核会返回
  `Filter with specified priority/protocol not found`。默认 `FILTER_PRIO=10`（IPv4）、`FILTER_PRIO6=11`（IPv6）。
- **默认 class 只保证很小的带宽**（`DEFAULT_GUARANTEE`，默认 `1mbit`），`ceil` 才是链路容量（`DEFAULT_RATE`）。
  HTB 的 `rate` 是**保证**带宽而不是上限，所以旧写法把 `rate` 和 `ceil` 都设成链路容量是不准确的；
  空闲时默认 class 仍然可以 burst 到 `DEFAULT_RATE`。
- **每个限速 class 下面挂 `fq_codel`**。否则叶子队列是纯 FIFO，限速一开延迟就飙（bufferbloat）。
- **显式设置 `burst`/`cburst`**。不设置时 tc 用的是刚好卡在最小值的默认值，实测速率会略低于配置值；
  留空则按 `rate` 自动计算（一个调度 tick 的发送量），也可以用 `BURST`/`CBURST` 覆盖。
- **整批命令用一次 `tc -batch` 下发**。旧版是每端口、每规则各调一次 `tc`（200 个端口约 600~1000 次进程调用），
  现在是 1 次。失败时会**删除 root qdisc 回滚**，回到"不限速"而不是留下半套规则。
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
