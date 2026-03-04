# Auto-SSL-for-ESXi
# ESXi 证书全自动续期与替换教程 (基于 acme.sh)
本方案通过 Debian (或其他 Linux) 环境下的 acme.sh 工具，利用阿里云 DNS 验证申请 Let's Encrypt 证书，并精准推送到 ESXi 主机，解决手动替换繁琐及 no healthy upstream 报错问题。
---
## 核心逻辑

- **RSA 2048 位加密**：确保与各版本 ESXi 组件的最佳兼容性。
- **单段证书提取**：通过 `sed` 过滤掉证书链，只保留服务器证书，防止 ESXi 无法识别多段证书导致服务崩溃。
- **强制切换 CA**：脚本会自动将 CA 切换为 Let's Encrypt，避免默认 ZeroSSL 导致的申请超时。
- **精准服务重启**：采用 `stop -> restart -> start` 序列，确保管理服务与反向代理同步，彻底解决 `no healthy upstream`。

---

## 第一阶段：建立 SSH 免密登录

为了让脚本能够自动登录 ESXi 推送文件并执行重启命令，必须配置 SSH 密钥对。

### 1. 在 Debian 上生成密钥（如已有则跳过）


`ssh-keygen -t rsa -b 2048`
获取公钥内容：

`cat ~/.ssh/id_rsa.pub`
复制输出的以 ssh-rsa 开头的整行内容。

在 ESXi 上注入公钥：
SSH 登录 ESXi 后执行：
`vi /etc/ssh/keys-root/authorized_keys`
按 G 跳到行尾，按 o 新起一行。

粘贴刚才复制的公钥。

按 Esc 退出编辑模式，输入 `:wq` 保存并退出。

#### 测试免密：
在 Debian 执行 `ssh root@你的ESXi_IP`，若无需密码直接进入，则配置成功。

### 第二阶段：创建自动化脚本
在 Debian 上创建脚本文件：`nano /root/setup_esxi_ssl.sh`

完整脚本代码
```
#!/bin/bash

# ================= 配置区 (请根据实际情况修改) =================
DOMAIN="你的域名"                            # 示例: esxi.example.com
ESXI_IP="你的ESXi_IP"                       # 示例: 192.168.1.10
ALI_KEY="你的阿里云AccessKey"                # 阿里云后台获取
ALI_SECRET="你的阿里云AccessSecret"          # 阿里云后台获取
DAYS_LIMIT=10                               # 剩余 10 天时触发自动更新
# =============================================================

echo "[$(date)] >>> 启动证书巡检..."

# 1. 模拟浏览器访问，获取当前在线证书的剩余天数 (最真实的检测方式)
EXPIRY_DATE_STR=$(echo | openssl s_client -connect ${DOMAIN}:443 2>/dev/null | openssl x509 -noout -enddate | cut -d= -f2)

if [ -z "$EXPIRY_DATE_STR" ]; then
    echo "❌ 无法通过 HTTPS 访问 ${DOMAIN}，请检查 ESXi 网络或域名解析。"
    exit 1
fi

EXPIRY_TIME=$(date -d "${EXPIRY_DATE_STR}" +%s)
NOW_TIME=$(date +%s)
DIFF_DAYS=$(( (EXPIRY_TIME - NOW_TIME) / 86400 ))

echo ">>> 浏览器检测到证书有效期剩余: ${DIFF_DAYS} 天"

# 2. 判断是否需要更新
if [ $DIFF_DAYS -le $DAYS_LIMIT ]; then
    echo "⚠️ 证书即将过期，开始自动化替换流程..."

    # 设置阿里云 API 环境
    export Ali_Key="$ALI_KEY"
    export Ali_Secret="$ALI_SECRET"

    # 3. 申请 RSA 2048 位证书
    # 强制切换 CA 为 Let's Encrypt，解决默认 ZeroSSL 超时问题
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue --dns dns_ali -d "$DOMAIN" --keylength 2048 --force

    CERT_PATH="$HOME/.acme.sh/${DOMAIN}"

    if [ -s "${CERT_PATH}/${DOMAIN}.cer" ]; then
        echo "✅ 证书申请成功，执行格式兼容性处理并推送..."

        # 4. 精准推送：提取第一段证书，防止证书链干扰 ESXi (解决 no healthy upstream 关键)
        sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "${CERT_PATH}/${DOMAIN}.cer" | head -n 50 | ssh root@${ESXI_IP} "cat > /etc/vmware/ssl/rui.crt"
        cat "${CERT_PATH}/${DOMAIN}.key" | ssh root@${ESXI_IP} "cat > /etc/vmware/ssl/rui.key"

        # 5. 远程重启 ESXi 管理服务
        echo ">>> 正在按顺序重启 ESXi 管理服务..."
        ssh root@${ESXI_IP} << EOF
            # 权限修正
            chmod 644 /etc/vmware/ssl/rui.crt
            chmod 600 /etc/vmware/ssl/rui.key
            chown root:root /etc/vmware/ssl/rui.*
            
            # 精准重启组合：先停入口代理，重启后端服务，最后起入口
            /etc/init.d/rhttpproxy stop
            /etc/init.d/hostd restart
            /etc/init.d/vpxa restart
            sleep 5
            /etc/init.d/rhttpproxy start

            # 状态检查
            /etc/init.d/rhttpproxy status
EOF
        echo "🚀 [$(date)] 证书替换完成，ESXi 网页已焕然一新！"
    else
        echo "❌ 错误：acme.sh 证书文件生成异常。"
        exit 1
    fi
else
    echo "✅ 证书尚在有效期内，跳过更新。"
fi
```


### 第三阶段：配置自动定时执行
#### 赋予执行权限：


`chmod +x /root/setup_esxi_ssl.sh`

#### 测试执行
`/root/setup_esxi_ssl.sh`
#### 添加定时任务：
执行 `crontab -e`，在末尾添加以下内容（建议每天凌晨 4:30 执行一次）：

`30 4 * * * /bin/bash /root/setup_esxi_ssl.sh >> /var/log/esxi_ssl_cron.log 2>&1`
## 常见问题排查
脚本报错 `unexpected end of file：`
请检查脚本末尾的 EOF。它必须顶格编写，左侧不能有空格或缩进，且其下方建议留一行空行。

网页显示 `no healthy upstream：`
这说明网页代理起太快了，而后端服务还没缓过来。脚本中已添加 `sleep 5`。如果硬件性能较弱（如 J1900 等老 CPU），建议将脚本中的 `sleep 5` 改为 `sleep 15`。

CA 依然超时：
如果 Let's Encrypt 也超时，说明服务器所在的网络环境彻底屏蔽了外网。可以尝试在脚本中添加代理配置或检查 DNS 设置。
