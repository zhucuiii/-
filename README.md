# tc Limit Ports

使用 Linux `tc`/HTB 为一组 TCP/UDP 服务端口分别设置出口限速。

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

## 自定义限速

`12mbit` 约等于 `1.5 MB/s`。可以修改 `/etc/default/limit-ports`：

```bash
SPEED="20mbit"
PORT_START="10001"
PORT_END="10200"
NIC="ens3"
```

也可以每次执行时临时覆盖：

```bash
sudo /usr/local/sbin/limit_ports.sh apply --speed 20mbit
sudo /usr/local/sbin/limit_ports.sh apply --speed 8mbit --start-port 10001 --end-port 10100
sudo /usr/local/sbin/limit_ports.sh status
sudo /usr/local/sbin/limit_ports.sh stop
```

## 说明

- 当前规则塑形的是出口流量，使用服务端 TCP/UDP 源端口匹配。
- 若要限制进入服务器的请求流量，需要增加 IFB ingress 规则。
- 脚本会接管网卡的整个 root qdisc，不能与其他 QoS、Docker 或 Kubernetes 流量控制直接叠加。
- `DEFAULT_RATE` 应设置为服务器实际链路速率，用于承载未匹配的流量。

## SSH 终端控制台

仓库内的 `portctl.sh` 是纯 Bash 的 SSH 交互菜单，不需要网页、Node 或 Python：

```bash
chmod +x portctl.sh
sudo ./portctl.sh
```

菜单支持编号输入，当前已接入：

- `01` 端口限速：应用当前配置、临时修改速率、查看 `tc` 统计
- `02` 系统信息
- `03` 服务管理
- `05` 日志中心
- `06` 从 GitHub 更新脚本

其余菜单已经预留，后续功能可以直接添加到 `portctl.sh`。

