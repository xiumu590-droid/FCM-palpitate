SCRIPT_NAME="${0##*/}"

FCM_palpitate() {
    script_name="$SCRIPT_NAME"
    current_pid=$$
    
    echo "[$(date '+%F %T')] 检查脚本 [$script_name] 运行状态..."
    
    # 查找其他实例（排除当前进程$$）
    old_pids=$(pgrep -f "$script_name" | grep -v "^${current_pid}$")
    
    if [ -n "$old_pids" ]; then
        echo "发现已有实例运行 [危险]"
        echo "旧进程PID: $old_pids"
        echo "当前PID: $current_pid"
        echo "正在终止旧进程..."
        
        # 逐个终止，避免误杀
        for pid in $old_pids; do
            kill -9 "$pid" 2>/dev/null && echo "  ✓ 已终止 PID:$pid"
        done
        
        sleep 1
        echo "旧进程清理完成 [安全]"
    else
        echo "未发现其他实例 [安全] PID: $current_pid"
    fi
    echo "等待5秒缓冲"
    sleep 5
    taskset -p 2 $$
    echo ""
}

FCM_palpitate

LOG_MAIN="/sdcard/应用白名单移除.log"
LOG_FCM="/sdcard/fcm广播.log"
LOG_ADD="/sdcard/FCM核心服务白名单添加.log"
MAX_SIZE_KB=50
MAX_SIZE=$((MAX_SIZE_KB * 1024))
PKG_QQ="com.tencent.mobileqq"
FCM_CHECK_INTERVAL=35
FCM_MAX_CONNECTION_DURATION=120

# 兜底检测配置（单向：上次 - 这次）
SAFEGUARD_MIN_DIFF=-20     # 最小差值（负数表示这次比上次长）
SAFEGUARD_MAX_DIFF=30     # 最大差值（这次比上次短30秒内）
SAFEGUARD_MIN_DURATION=1 # 最小时长过滤(不建议改)

# FCM核心服务包（需要保持白名单以确保FCM稳定）
FCM_CORE_PKGS="com.google.android.gms com.google.android.gsf"

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

batch_check_whitelist() {
    local pkgs="$1"
    [ -z "$pkgs" ] && return
    
    # 构建单行查询指令
    local cmd="dumpsys deviceidle whitelist"
    for pkg in $pkgs; do
        cmd="$cmd =$pkg"
    done
    
    # 执行查询，将结果保存到临时文件（POSIX兼容）
    local tmp_file="/tmp/whitelist_check_$$.tmp"
    $cmd 2>/dev/null > "$tmp_file"
    
    # 逐行读取结果并输出（与输入顺序对应）
    local i=0
    while IFS= read -r line; do
        # 获取第i个包名
        local pkg=$(echo "$pkgs" | cut -d' ' -f$((i+1)))
        [ -z "$pkg" ] && break
        
        echo "${pkg}:${line:-false}"
        i=$((i+1))
    done < "$tmp_file"
    
    # 清理临时文件
    rm -f "$tmp_file"
}

batch_remove_whitelist() {
    local pkgs="$1"
    [ -z "$pkgs" ] && return
    
    echo "# $(date '+%F %T') - 批量白名单检测与移除"
    echo "检测应用数: $(echo "$pkgs" | wc -w)"
    echo "---"
    
    # 步骤1: 批量检测所有包的白名单状态
    local check_results=$(batch_check_whitelist "$pkgs")
    
    # 步骤2: 分类处理
    local need_remove_pkgs=""  # 需要移除的（状态为true，表示当前在白名单中）
    local skip_pkgs=""         # 不需要移除的（状态为false，表示不在白名单中）
    
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local pkg=$(echo "$line" | cut -d: -f1)
        local status=$(echo "$line" | cut -d: -f2)
        local app_name=$(get_app_name "$pkg")
        
        if [ "$status" = "true" ]; then
            need_remove_pkgs="$need_remove_pkgs $pkg"
            echo "[${app_name}]: 包名: ${pkg} | 状态: ✓ 在白名单中，待移除"
        else
            skip_pkgs="$skip_pkgs $pkg"
            echo "[${app_name}]: 包名: ${pkg} | 状态: - 不在白名单中，跳过"
        fi
    done <<< "$check_results"
    
    echo ""
    
    # 步骤3: 如果有需要移除的包，执行批量移除
    if [ -n "$need_remove_pkgs" ]; then
        # 构建单行移除指令: dumpsys deviceidle whitelist -pkg1 -pkg2 -pkg3
        local remove_cmd="dumpsys deviceidle whitelist"
        for pkg in $need_remove_pkgs; do
            remove_cmd="$remove_cmd -$pkg"
        done
        
        echo "执行批量移除: $(echo "$need_remove_pkgs" | wc -w) 个应用"
        echo "指令: $remove_cmd"
        echo ""
        
        # 执行批量移除
        local remove_output=$($remove_cmd 2>&1)
        local remove_exit_code=$?
        
        # 解析移除结果（按顺序对应）
        local i=0
        for pkg in $need_remove_pkgs; do
            local app_name=$(get_app_name "$pkg")
            # 获取第i行结果（与输入顺序对应）
            local result=$(echo "$remove_output" | sed -n "$((i+1))p")
            
            if [ "$result" = "true" ] || [ -z "$result" ]; then
                # 如果返回true或空，认为移除成功（有些系统不返回具体结果）
                echo "[${app_name}]: ✓ 已移除白名单"
            else
                echo "[${app_name}]: ✗ 移除失败 (返回: ${result})"
            fi
            ((i++))
        done
        
        if [ $remove_exit_code -ne 0 ]; then
            echo "警告: 批量移除指令返回非零退出码: $remove_exit_code"
        fi
    else
        echo "没有应用需要从白名单中移除"
    fi
    
    echo "---"
    echo "完成时间: $(date '+%F %T')"
    echo ""
}

batch_add_whitelist() {
    local pkgs="$1"
    [ -z "$pkgs" ] && return
    
    echo "# $(date '+%F %T') - FCM核心服务白名单检测与添加"
    echo "检测应用数: $(echo "$pkgs" | wc -w)"
    echo "目标: 确保FCM核心服务在电池白名单中，防止断连"
    echo "---"
    
    # 步骤1: 批量检测所有包的白名单状态
    local check_results=$(batch_check_whitelist "$pkgs")
    
    # 步骤2: 分类处理（与移除相反）
    local need_add_pkgs=""     # 需要添加的（状态为false，表示当前不在白名单中）
    local skip_pkgs=""         # 不需要添加的（状态为true，表示已在白名单中）
    
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local pkg=$(echo "$line" | cut -d: -f1)
        local status=$(echo "$line" | cut -d: -f2)
        local app_name=$(get_app_name "$pkg")
        
        if [ "$status" = "false" ]; then
            # 不在白名单中，需要添加（与移除逻辑相反）
            need_add_pkgs="$need_add_pkgs $pkg"
            echo "[${app_name}]: 包名: ${pkg} | 状态: ✗ 不在白名单中，待添加"
        else
            # 已在白名单中，跳过
            skip_pkgs="$skip_pkgs $pkg"
            echo "[${app_name}]: 包名: ${pkg} | 状态: ✓ 已在白名单中，跳过"
        fi
    done <<< "$check_results"
    
    echo ""
    
    # 步骤3: 如果有需要添加的包，执行批量添加
    if [ -n "$need_add_pkgs" ]; then
        # 构建单行添加指令: dumpsys deviceidle whitelist +pkg1 +pkg2 +pkg3
        local add_cmd="dumpsys deviceidle whitelist"
        for pkg in $need_add_pkgs; do
            add_cmd="$add_cmd +$pkg"
        done
        
        echo "执行批量添加: $(echo "$need_add_pkgs" | wc -w) 个应用"
        echo "指令: $add_cmd"
        echo ""
        
        # 执行批量添加
        local add_output=$($add_cmd 2>&1)
        local add_exit_code=$?
        
        # 解析添加结果（按顺序对应）
        local i=0
        for pkg in $need_add_pkgs; do
            local app_name=$(get_app_name "$pkg")
            # 获取第i行结果（与输入顺序对应）
            local result=$(echo "$add_output" | sed -n "$((i+1))p")
            
            if [ "$result" = "true" ] || [ -z "$result" ]; then
                # 如果返回true或空，认为添加成功
                echo "[${app_name}]: ✓ 已添加至白名单"
            else
                echo "[${app_name}]: ✗ 添加失败 (返回: ${result})"
            fi
            ((i++))
        done
        
        if [ $add_exit_code -ne 0 ]; then
            echo "警告: 批量添加指令返回非零退出码: $add_exit_code"
        fi
    else
        echo "所有FCM核心服务已在白名单中，无需添加"
    fi
    
    echo "---"
    echo "完成时间: $(date '+%F %T')"
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
            
            # 获取所有FCM应用
            fcm_apps=$(get_fcm_packages)
            
            if [ -z "$fcm_apps" ]; then
                echo "未检测到FCM应用"
                echo ""
                echo "---"
                echo "完成时间: $(date '+%F %T')"
                echo ""
            else
                app_count=$(echo "$fcm_apps" | wc -l)
                echo "检测到 ${app_count} 个FCM应用"
                echo ""
                
                # 将所有包名转换为单行空格分隔格式
                local pkg_list=$(echo "$fcm_apps" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/ $//')
                
                # 调用批量移除函数（内部先检测，后移除）
                batch_remove_whitelist "$pkg_list"
            fi
        } >> "$LOG_MAIN"
        
        sleep 1800
    done
}

# ============================================
# FCM核心服务白名单维护循环（新增）
# 确保Google服务和GSF框架始终在电池白名单中
# ============================================
fcm_core_whitelist_loop() {
    while true; do
        check_and_clean_log "$LOG_ADD"
        
        {
            # 直接对固定的FCM核心服务包进行检测和添加
            batch_add_whitelist "$FCM_CORE_PKGS"
        } >> "$LOG_ADD"
        
        # 每30分钟检查一次（比移除循环更频繁，确保核心服务不被系统清理）
        sleep 1800
    done
}

echo "[$(date '+%F %T')] 初始化：检查并清理历史日志..."
[ -f "$LOG_MAIN" ] && rm -f "$LOG_MAIN" && echo "✓ 已删除旧日志: $LOG_MAIN"
[ -f "$LOG_FCM" ] && rm -f "$LOG_FCM" && echo "✓ 已删除旧日志: $LOG_FCM"
[ -f "$LOG_ADD" ] && rm -f "$LOG_ADD" && echo "✓ 已删除旧日志: $LOG_ADD"
echo "[$(date '+%F %T')] 初始化完成"
echo ""

echo "[$(date '+%F %T')] 启动三循环守护进程..."
echo "兜底检测: 上次-这次 在 [${SAFEGUARD_MIN_DIFF}, ${SAFEGUARD_MAX_DIFF}] 范围内时触发"
fcm_loop &
PID_FCM=$!
echo "智能FCM监控循环已启动 (PID: $PID_FCM) - 检查间隔: ${FCM_CHECK_INTERVAL}秒, 强制心跳阈值: ${FCM_MAX_CONNECTION_DURATION}秒"

main_loop &
PID_MAIN=$!
echo "FCM应用白名单移除循环已启动 (PID: $PID_MAIN) - 间隔: 2700秒"

fcm_core_whitelist_loop &
PID_ADD=$!
echo "FCM核心服务白名单维护循环已启动 (PID: $PID_ADD) - 目标: ${FCM_CORE_PKGS}"

echo "脚本运行中，按 Ctrl+C 或执行 'kill $PID_FCM $PID_MAIN $PID_ADD' 停止"

echo ""
echo ""
echo ""
wait
