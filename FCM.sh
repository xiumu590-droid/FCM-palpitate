LOG_MAIN="/sdcard/应用白名单移除.log"
LOG_FCM="/sdcard/fcm广播.log"
MAX_SIZE_KB=50
MAX_SIZE=$((MAX_SIZE_KB * 1024))
PKG_QQ="com.tencent.mobileqq"
FCM_CHECK_INTERVAL=35
FCM_MAX_CONNECTION_DURATION=120

# 兜底检测配置（单向：上次 - 这次）
SAFEGUARD_MIN_DIFF=-20     # 最小差值（负数表示这次比上次长）
SAFEGUARD_MAX_DIFF=30     # 最大差值（这次比上次短30秒内）
SAFEGUARD_MIN_DURATION=1 # 最小时长过滤(不建议改)
taskset -p 2 $$

get_app_name() {
    local pkg="$1"
    case "$pkg" in
        "com.tencent.mm") echo "微信" ;;
        "com.tencent.mobileqq") echo "QQ" ;;
        "com.zhiliaoapp.musically") echo "TikTok" ;;
        "com.ss.android.ugc.aweme") echo "抖音" ;;
        "com.github.android") echo "GitHub" ;;
        "com.google.android.youtube") echo "YouTube" ;;
        "com.microsoft.office.outlook") echo "Outlook" ;;
        "com.android.vending") echo "Google Play" ;;
        "com.google.android.gms") echo "Google服务" ;;
        "com.google.android.gsf") echo "Google服务框架" ;;
        "com.roblox.client") echo "Roblox" ;;
        "nu.gpu.nagram") echo "Nagram" ;;
        "com.okinc.okex.gp") echo "欧易OKX" ;;
        "com.alibaba.aliyun") echo "阿里云" ;;
        "com.axlebolt.standoff2") echo "对峙2" ;;
        "com.whatsapp") echo "WhatsApp" ;;
        "com.facebook.katana") echo "Facebook" ;;
        "com.instagram.android") echo "Instagram" ;;
        "com.twitter.android") echo "Twitter" ;;
        "org.telegram.messenger"|"telegram") echo "Telegram" ;;
        "com.discord") echo "Discord" ;;
        "com.spotify.music") echo "Spotify" ;;
        "com.valvesoftware.android.steam.community") echo "Steam" ;;
        "com.rezvorck.tiktokplugin") echo "TikTok插件" ;;
        *) local short=$(echo "$pkg" | sed 's/.*\.//'); echo "$short" ;;
    esac
}

check_and_clean_log() {
    local log_file="$1"
    if [ -f "$log_file" ]; then
        local cur_size=$(stat -c%s "$log_file" 2>/dev/null || busybox stat -c%s "$log_file" 2>/dev/null || ls -l "$log_file" | awk '{print $5}')
        if [ "$cur_size" -gt "$MAX_SIZE" ]; then
            rm -f "$log_file"
            echo "# [$(date '+%F %T')] 日志超过 ${MAX_SIZE_KB}KB，已自动清理" >> "$log_file"
            echo "" >> "$log_file"
        fi
    fi
}

get_fcm_packages() {
    for pkg in $(pm list packages -3 | cut -d: -f2); do 
        if dumpsys package "$pkg" 2>/dev/null | grep -q "com.google.android.c2dm.permission.RECEIVE"; then 
            echo "$pkg"
        fi
    done | sort -u
}

remove_whitelist() {
    local pkg_name="$1" app_name="$2"
    
    # 检查当前白名单状态
    local whitelist_status=$(dumpsys deviceidle whitelist 2>/dev/null | grep -q "^${pkg_name}$" && echo "true" || echo "false")
    
    echo "[${app_name}]: "
    echo "  包名: ${pkg_name}"
    
    if [ "$whitelist_status" = "true" ]; then
        # 在白名单中，执行移除操作
        dumpsys deviceidle whitelist -"${pkg_name}" >/dev/null 2>&1
        local exit_code=$?
        if [ $exit_code -eq 0 ]; then
            echo "  状态: ✓ 已在白名单中，已移除白名单"
        else
            echo "  状态: ✗ 已在白名单中，但移除失败(码:$exit_code)"
        fi
    else
        # 不在白名单中，跳过
        echo "  状态: - 不在白名单中，跳过"
    fi
    echo ""
}

check_fcm_connection() {
    local gcm_info=$(dumpsys activity service com.google.android.gms/.gcm.GcmService 2>/dev/null)
    
    local connected_line=$(echo "$gcm_info" | grep "connected=" | head -1)
    local connected_addr=$(echo "$connected_line" | grep -o "connected=[^ ,]*" | cut -d= -f2)
    
    if [ -z "$connected_addr" ] || [ "$connected_addr" = "null" ] || [ "$connected_addr" = "false" ]; then
        echo "断开连接:0:::0"
        return 1
    fi
    
    local ip_port=$(echo "$connected_line" | grep -o "connected=[^ ,]*" | cut -d= -f2)
    local last_ping=$(echo "$gcm_info" | grep "Last ping:" | grep -o "[0-9]*" | head -1)
    [ -z "$last_ping" ] && last_ping="0"
    
    local heartbeat_line=$(echo "$gcm_info" | grep "Heartbeat: alarm(" | head -1)
    
    if [ -z "$heartbeat_line" ]; then
        local duration=$(echo "$gcm_info" | grep "lastConnectionDurationS=" | grep -o "[0-9]*" | head -1)
        [ -z "$duration" ] && duration=0
        echo "已连接:$duration:$ip_port:$last_ping"
        return 0
    fi
    
    local total_seconds=$(echo "$heartbeat_line" | grep -o "initial: [0-9]*s" | grep -o "[0-9]*" | head -1)
    local remaining_time=$(echo "$heartbeat_line" | grep -o "alarm([0-9]*:[0-9]*" | grep -o "[0-9]*:[0-9]*" | head -1)
    
    if [ -z "$total_seconds" ] || [ -z "$remaining_time" ]; then
        echo "未知:0:$ip_port:$last_ping"
        return 1
    fi
    
    local remaining_min=$(echo "$remaining_time" | cut -d: -f1)
    local remaining_sec=$(echo "$remaining_time" | cut -d: -f2)
    remaining_min=$((10#$remaining_min))
    remaining_sec=$((10#$remaining_sec))
    local remaining_total=$((remaining_min * 60 + remaining_sec))
    local connected_duration=$((total_seconds - remaining_total))
    
    [ "$connected_duration" -lt 0 ] && connected_duration=0
    
    echo "已连接:$connected_duration:$ip_port:$last_ping"
    return 0
}

get_fcm_details() {
    local gcm_info=$(dumpsys activity service com.google.android.gms/.gcm.GcmService 2>/dev/null)
    local ip_port=$(echo "$gcm_info" | grep "connected=" | head -1 | grep -o "connected=[^ ,]*" | cut -d= -f2)
    local last_ping=$(echo "$gcm_info" | grep "Last ping:" | grep -o "[0-9]*" | head -1)
    [ -z "$last_ping" ] && last_ping="N/A"
    echo "$ip_port:$last_ping"
}

send_fcm_heartbeat() {
    local reason="$1" 
    local prev_duration="$2"
    local is_safeguard="$3"
    local timestamp=$(date '+%F %T')
    local result1="" 
    local result2=""
    local status1="失败" 
    local status2="失败"
    
    result1=$(am broadcast -a com.google.android.intent.action.GTALK_HEARTBEAT 2>&1)
    if [ $? -eq 0 ] && ! echo "$result1" | grep -qi "failure\|failed\|error"; then
        status1="成功"
    fi
    
    result2=$(am broadcast -a com.google.android.intent.action.MCS_HEARTBEAT 2>&1)
    if [ $? -eq 0 ] && ! echo "$result2" | grep -qi "failure\|failed\|error"; then
        status2="成功"
    fi
    
    local type="心跳广播"
    [ "$is_safeguard" = "true" ] && type="兜底心跳广播"
    
    cat >> "$LOG_FCM" << EOF
# $timestamp - $type [$reason]
$(if [ -n "$prev_duration" ]; then echo "上一连接持续时间: ${prev_duration}秒"; fi)
>>> [1/2] GTALK_HEARTBEAT
状态: $status1
$(if [ "$status1" = "失败" ]; then echo "详情: $result1"; fi)
>>> [2/2] MCS_HEARTBEAT
状态: $status2
$(if [ "$status2" = "失败" ]; then echo "详情: $result2"; fi)
----------------------------------------

EOF
}

# ============================================
# 核心：fcm_loop 带新版兜底检测（单向差值 -10~30）
# ============================================
fcm_loop() {
    sleep 2
    
    local is_first_run=true
    local prev_duration=0      # 上次连接时长
    
    while true; do
        check_and_clean_log "$LOG_FCM"
        
        # 首次运行
        if [ "$is_first_run" = true ]; then
            send_fcm_heartbeat "首次启动，初始化心跳" "" "false"
            
            sleep 2
            local details=$(get_fcm_details)
            local ip_port=$(echo "$details" | cut -d: -f1)
            local ping=$(echo "$details" | cut -d: -f2)
            
            cat >> "$LOG_FCM" << EOF
# $(date '+%F %T') - 初始化后连接详情
服务器: ${ip_port}
延迟: ${ping}ms
----------------------------------------

EOF
            
            # 初始化上次时长
            local conn_result=$(check_fcm_connection)
            prev_duration=$(echo "$conn_result" | cut -d: -f2)
            
            is_first_run=false
            sleep "${FCM_CHECK_INTERVAL}"
            continue
        fi
        
        # 获取当前状态
        local conn_result=$(check_fcm_connection)
        local conn_status=$(echo "$conn_result" | cut -d: -f1)
        local conn_duration=$(echo "$conn_result" | cut -d: -f2)
        local conn_ip=$(echo "$conn_result" | cut -d: -f3)
        local conn_ping=$(echo "$conn_result" | cut -d: -f4)
        
        local need_heartbeat=false
        local heartbeat_reason=""
        local is_safeguard="false"
        
        # 场景1：断开连接
        if [ "$conn_status" = "断开连接" ]; then
            need_heartbeat=true
            heartbeat_reason="连接已断开"
        
        # 场景2：达到阈值
        elif [ -n "$conn_duration" ] && [ "$conn_duration" -ge "$FCM_MAX_CONNECTION_DURATION" ] 2>/dev/null; then
            need_heartbeat=true
            heartbeat_reason="强制心跳[当前链接持续${conn_duration}秒]"
        
        # 场景3：兜底检测
        elif [ "$conn_duration" -ge "$SAFEGUARD_MIN_DURATION" ] 2>/dev/null; then
            # 计算差值：上次 - 这次
            local diff=$((prev_duration - conn_duration))
            
            # 判断是否在兜底范围
            if [ "$diff" -ge "$SAFEGUARD_MIN_DIFF" ] && [ "$diff" -le "$SAFEGUARD_MAX_DIFF" ]; then
                need_heartbeat=true
                heartbeat_reason="兜底检测[连接重置 suspected: ${prev_duration}s -> ${conn_duration}s, diff=${diff}s, range(${SAFEGUARD_MIN_DIFF}~${SAFEGUARD_MAX_DIFF})]"
                is_safeguard="true"
            fi
        fi
        
        # 更新上次时长（无论是否触发兜底都更新）
        prev_duration=$conn_duration
        
        # 执行心跳（如果需要）
        if [ "$need_heartbeat" = true ]; then
            send_fcm_heartbeat "$heartbeat_reason" "$conn_duration" "$is_safeguard"
            
            sleep 1
            local details=$(get_fcm_details)
            local new_ip=$(echo "$details" | cut -d: -f1)
            local new_ping=$(echo "$details" | cut -d: -f2)
            
            local detail_type="心跳后连接详情"
            [ "$is_safeguard" = "true" ] && detail_type="兜底后连接详情"
            
            cat >> "$LOG_FCM" << EOF
# $(date '+%F %T') - $detail_type
服务器: ${new_ip}
延迟: ${new_ping}ms
----------------------------------------

EOF
        else
            # 正常状态日志（显示差值便于调试）
            local diff=$((prev_duration - conn_duration))
            cat >> "$LOG_FCM" << EOF
# $(date '+%F %T') - FCM状态检查 [正常]
连接状态: 已连接
连接持续时间: ${conn_duration}秒
上次差值: ${diff}s (范围${SAFEGUARD_MIN_DIFF}~${SAFEGUARD_MAX_DIFF})
服务器: ${conn_ip}
延迟: ${conn_ping}ms
距离强制心跳阈值: $((FCM_MAX_CONNECTION_DURATION - conn_duration))秒
----------------------------------------

EOF
        fi
        
        sleep "${FCM_CHECK_INTERVAL}"
    done
}

main_loop() {
    while true; do
        CURRENT_TIME=$(date '+%F %T')
        check_and_clean_log "$LOG_MAIN"
        {
            echo "# $CURRENT_TIME - 开始移除应用电池白名单"
            echo "---"
            echo "# 正在扫描支持FCM推送的应用（包含QQ）..."
            fcm_apps=$(get_fcm_packages)
            if [ -z "$fcm_apps" ]; then
                echo "未检测到FCM应用"
                echo ""
            else
                app_count=$(echo "$fcm_apps" | wc -l)
                echo "检测到 ${app_count} 个FCM应用"
                echo ""
                echo "$fcm_apps" | while read pkg; do
                    app_name=$(get_app_name "$pkg")
                    remove_whitelist "$pkg" "$app_name"
                done
            fi
            echo "---"
            echo "完成时间: $(date '+%F %T')"
            echo ""
        } >> "$LOG_MAIN"
        sleep 1350
    done
}

echo "[$(date '+%F %T')] 初始化：检查并清理历史日志..."
[ -f "$LOG_MAIN" ] && rm -f "$LOG_MAIN" && echo "✓ 已删除旧日志: $LOG_MAIN"
[ -f "$LOG_FCM" ] && rm -f "$LOG_FCM" && echo "✓ 已删除旧日志: $LOG_FCM"
echo "[$(date '+%F %T')] 初始化完成"
echo ""

echo "[$(date '+%F %T')] 启动双循环守护进程..."
echo "兜底检测: 上次-这次 在 [${SAFEGUARD_MIN_DIFF}, ${SAFEGUARD_MAX_DIFF}] 范围内时触发"
fcm_loop &
PID_FCM=$!
echo "智能FCM监控循环已启动 (PID: $PID_FCM) - 检查间隔: ${FCM_CHECK_INTERVAL}秒, 强制心跳阈值: ${FCM_MAX_CONNECTION_DURATION}秒"
main_loop &
PID_MAIN=$!
echo "FCM应用白名单管理循环已启动 (PID: $PID_MAIN) - 间隔: 2700秒"
echo "脚本运行中，按 Ctrl+C 或执行 'kill $PID_FCM $PID_MAIN' 停止"
wait
