# 酷安:@裘穆 @陌问花
# 初始版本
LOG_MAIN="/sdcard/应用白名单移除.log"
LOG_FCM="/sdcard/fcm广播.log"
MAX_SIZE_KB=50
MAX_SIZE=$((MAX_SIZE_KB * 1024))

# 目标应用包名
PKG_WECHAT="com.tencent.mm"
PKG_QQ="com.tencent.mobileqq"

check_and_clean_log() {
    local log_file="$1"
    if [ -f "$log_file" ]; then
        local cur_size
        cur_size=$(stat -c%s "$log_file" 2>/dev/null || busybox stat -c%s "$log_file" 2>/dev/null || ls -l "$log_file" | awk '{print $5}')
        
        if [ "$cur_size" -gt "$MAX_SIZE" ]; then
            rm -f "$log_file"
            echo "# [$(date '+%F %T')] 日志超过 ${MAX_SIZE_KB}KB，已自动清理" >> "$log_file"
            echo "" >> "$log_file"
        fi
    fi
}

fcm_loop() {
    sleep 2
    
    while true; do
        check_and_clean_log "$LOG_FCM"
        
        {
            echo "# $(date '+%F %T') - FCM心跳广播"
            
            echo ">>> [1/2] GTALK_HEARTBEAT"
            result1=$(am broadcast -a com.google.android.intent.action.GTALK_HEARTBEAT 2>&1)
            if [ $? -eq 0 ] && ! echo "$result1" | grep -qi "failure\|failed"; then
                echo "状态: 成功 - $result1"
            else
                echo "状态: 失败 - $result1"
            fi
            
            echo ">>> [2/2] MCS_HEARTBEAT"
            result2=$(am broadcast -a com.google.android.intent.action.MCS_HEARTBEAT 2>&1)
            if [ $? -eq 0 ] && ! echo "$result2" | grep -qi "failure\|failed"; then
                echo "状态: 成功 - $result2"
            else
                echo "状态: 失败 - $result2"
            fi
            
            echo "----------------------------------------"
            echo ""
        } >> "$LOG_FCM"
        
        sleep 300
    done
}

# ==========================================
# 子函数：移除单个应用的白名单（修复版）
# ==========================================
remove_whitelist() {
    local pkg_name="$1"
    local app_name="$2"
    
    echo "[$app_name]: "
    
    # 步骤1：先检查当前是否在白名单（用于日志区分状态）
    # 注意：dumpsys deviceidle whitelist 列出的是完整包名，加^防止部分匹配
    local is_whitelisted
    is_whitelisted=$(dumpsys deviceidle whitelist | grep "^${pkg_name}$")
    
    if [ -z "$is_whitelisted" ]; then
        echo "○ 本来就不在白名单中（无需处理）"
        return 0
    fi
    
    # 步骤2：执行移除（静默执行，不依赖输出内容判断）
    dumpsys deviceidle whitelist -"${pkg_name}" >/dev/null 2>&1
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        echo "✓ 已移除白名单（操作成功）"
    else
        echo "✗ 操作失败，退出码: $exit_code"
    fi
    echo ""
}


main_loop() {
    while true; do
        CURRENT_TIME=$(date '+%F %T')
        
        check_and_clean_log "$LOG_MAIN"
        
        {
            echo "# $CURRENT_TIME - 开始移除应用电池白名单"
            echo "---"
            
            # 移除微信
            remove_whitelist "$PKG_WECHAT" "微信"
            
            # 移除QQ
            remove_whitelist "$PKG_QQ" "QQ"
            
            echo "---"
            echo "完成时间: $(date '+%F %T')"
            echo ""
        } >> "$LOG_MAIN"
        
        sleep 2700
    done
}


echo "[$(date '+%F %T')] 初始化：检查并清理历史日志..."

if [ -f "$LOG_MAIN" ]; then
    rm -f "$LOG_MAIN"
    echo "✓ 已删除旧日志: $LOG_MAIN"
fi

if [ -f "$LOG_FCM" ]; then
    rm -f "$LOG_FCM"
    echo "✓ 已删除旧日志: $LOG_FCM"
fi

echo "[$(date '+%F %T')] 初始化完成，准备启动守护进程..."
echo ""


echo "[$(date '+%F %T')] 启动双循环守护进程..."

fcm_loop &
PID_FCM=$!
echo "FCM广播循环已启动 (PID: $PID_FCM) - 间隔: 300秒"

main_loop &
PID_MAIN=$!
echo "微信+QQ白名单管理循环已启动 (PID: $PID_MAIN) - 间隔: 2700秒 (45分钟)"

echo "脚本运行中，按 Ctrl+C 或执行 'kill $PID_FCM $PID_MAIN' 停止"
wait
