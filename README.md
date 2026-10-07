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
sudo /usr/local/sbin/limit_ports.sh plan -v        # 只打印将要执行的 tc 命令
sudo /usr/local/sbin/limit_ports.sh status
sudo /usr/local/sbin/limit_ports.sh stop
```

`rules` 和 `plan` 是只读动作，不需要 root，可以用来确认配置是否正确。

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
- `05` 日志中心
- `06` 从 GitHub 更新脚本
- `07` 卸载程序

其余菜单已经预留，后续功能可以直接添加到 `portctl.sh`。

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
0. 返回主菜单
```

- 区间限速会让你输入起始端口、结束端口和速率，再选择「每端口独立」或「区间共享」。
- 单端口限速只输入一个端口和速率。
- 菜单写入的规则会保存回 `/etc/default/limit-ports`，原来的注释和 `NIC`、`DEFAULT_RATE` 等配置不变。
- 新规则如果和已有规则端口重叠，会提示将被替换的规则并要求确认。
- 速率输入是纯数字，单位单独选择：

  ```text
  1. Mbit/s
  2. MB/s
  3. Gbit/s
  4. GB/s
  ```

## 说明

- 当前规则塑形的是出口流量，使用服务端 TCP/UDP 源端口匹配。
- 若要限制进入服务器的请求流量，需要增加 IFB ingress 规则。
- 脚本会接管网卡的整个 root qdisc，不能与其他 QoS、Docker 或 Kubernetes 流量控制直接叠加。
- `DEFAULT_RATE` 应设置为服务器实际链路速率，用于承载未匹配的流量。
- 区间共享（`@shared`）会让整段端口共用一条 HTB 队列，端口很多时建议用它，减少 `tc` 队列数量。
