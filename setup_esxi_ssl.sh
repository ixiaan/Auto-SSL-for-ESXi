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