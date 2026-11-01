#!/bin/bash
# fail2ban 批量解封工具 - 按时间段解封 IP
# 用法: bash unban_timerange.sh [开始时间] [结束时间] [日期]
# 示例: bash unban_timerange.sh "17:45" "22:00" "2026-02-19"

START_TIME="${1:-17:45}"
END_TIME="${2:-22:00}"
DATE="${3:-$(date +%Y-%m-%d)}"

echo "=== fail2ban 批量解封工具 ==="
echo "时间范围: $DATE $START_TIME:00 - $END_TIME:00"
echo ""

# 提取指定时间段内所有被封禁的 IP
echo "正在从 /var/log/fail2ban.log 提取封禁 IP..."

BANNED_IPS=$(grep "$DATE" /var/log/fail2ban.log 2>/dev/null | \
  awk -v start="$START_TIME:00" -v end="$END_TIME:00" '
  $2 >= start && $2 <= end && /Ban / {
    for(i=1;i<=NF;i++) {
      if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
        print $i
      }
    }
  }' | sort -u)

if [ -z "$BANNED_IPS" ]; then
    echo "未找到在该时间段内封禁的 IP"
    echo ""
    echo "提示: 如果日志不在本机，请手动执行以下命令："
    echo "  fail2ban-client unban <IP地址>"
    echo "  或清空所有封禁: fail2ban-client unban --all"
    exit 0
fi

echo "找到以下 IP:"
echo "$BANNED_IPS" | nl
echo ""

IP_COUNT=$(echo "$BANNED_IPS" | wc -l)
echo "共 $IP_COUNT 个 IP"
echo ""

read -p "是否解封这些 IP? (y/N): " confirm

if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "已取消"
    exit 0
fi

echo ""
echo "开始解封..."
echo ""

SUCCESS=0
FAILED=0
NOT_BANNED=0

for ip in $BANNED_IPS; do
    echo -n "解封 $ip ... "
    result=$(fail2ban-client unban $ip 2>&1)
    
    if echo "$result" | grep -q "is not banned"; then
        echo "未被封禁（可能已过期）"
        ((NOT_BANNED++))
    elif echo "$result" | grep -q "error\|Error\|ERROR"; then
        echo "失败: $result"
        ((FAILED++))
    else
        echo "成功"
        ((SUCCESS++))
    fi
done

echo ""
echo "=== 解封统计 ==="
echo "成功: $SUCCESS"
echo "未被封禁: $NOT_BANNED"
echo "失败: $FAILED"
echo ""
echo "完成！"
