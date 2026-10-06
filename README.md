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

## 控制台界面

仓库内的 `ui/` 是一个可扩展的终端风格控制台原型。它不依赖第三方前端框架：

```bash
node ui/server.mjs
```

然后打开 `http://127.0.0.1:4173`。当前已接入菜单切换、编号输入、方向键导航、状态指标和活动日志，后续可以把“应用规则”按钮接到真实脚本或 API。

