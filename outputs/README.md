# tc 按端口限速

## 这版修正了什么

- 使用 `set -Eeuo pipefail`，变量未定义或命令失败时立即退出。
- 所有关键参数可通过 `/etc/default/limit-ports` 配置，不再硬编码 `eth0`。
- 增加 `1:1` 默认 class，未匹配流量不会落到不存在的 class。
- 每个端口仍然是独立 HTB class，`12mbit` 约等于 `1.5 MB/s`。
- 支持 `apply`、`stop`、`status`，可重复执行。
- 启动前校验 root、命令、网卡、端口和 class id 范围。
- 使用 TCP/UDP 源端口匹配服务的出口响应流量。

## 手动安装

```bash
install -m 0755 limit_ports.sh /usr/local/sbin/limit_ports.sh
install -m 0644 limit-ports.default /etc/default/limit-ports
/usr/local/sbin/limit_ports.sh apply
/usr/local/sbin/limit_ports.sh status
```

## systemd 开机自动恢复

```bash
install -m 0644 limit-ports.service /etc/systemd/system/limit-ports.service
systemctl daemon-reload
systemctl enable --now limit-ports.service
systemctl status limit-ports.service
```

## 重要边界

`tc` 的这个 HTB 根队列控制的是出口方向。对于服务器监听端口，源端口匹配通常正好对应服务返回流量；但它不会限制进入服务器的请求流量。若还要限制入口，需要用 IFB 把 ingress 重定向到一个虚拟设备，再在 IFB 上配置同类规则。

脚本会接管网卡的整个 root qdisc。如果该网卡已经被 Docker、Kubernetes、云厂商代理或其他 QoS 服务管理，请先确认不会互相覆盖。

