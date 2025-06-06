#!/bin/bash

# 设置最大重试次数
MAX_RETRIES=3
# 设置最大循环次数，防止死循环
MAX_LOOPS=20

# 已经成功编译的包列表，避免重复处理
SUCCESSFUL_PACKAGES=()

# 主编译函数
function main_build() {
    echo "开始执行主编译命令: make -j$(nproc) || make -j1 V=sc"
    
    # 先尝试使用所有核心进行并行编译
    make -j$(nproc) 2>&1 | tee -a build.log
    
    # 检查编译是否成功
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo "并行编译成功完成！"
        return 0
    else
        echo "并行编译失败，尝试单线程详细模式编译..."
        # 如果并行编译失败，尝试单线程详细模式
        make -j1 V=sc 2>&1 | tee -a build.log
        
        # 检查单线程编译是否成功
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            echo "单线程编译成功完成！"
            return 0
        else
            echo "编译失败，开始分析错误..."
            return 1
        fi
    fi
}

# 从日志中提取失败的包路径
function extract_failed_package() {
    # 使用 strings 命令处理可能的二进制文件，然后进行grep
    local failed_pkg=$(strings build.log | grep -E "\[package/Makefile:189: (.*)/compile\] Error 1" | tail -1)
    
    if [ -n "$failed_pkg" ]; then
        # 提取包路径 - 使用更宽松的正则表达式
        if [[ $failed_pkg =~ \[package/Makefile:189:\ (.+)/compile\]\ Error\ 1 ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    fi
    
    # 如果上面的方法失败，尝试另一种提取方式
    local error_line=$(strings build.log | grep "ERROR:" | tail -1)
    if [[ $error_line =~ ERROR:\ (.+)\ failed\ to\ build ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    
    echo "无法识别失败的包路径"
    return 1
}

# 检查包是否已经成功编译过
function is_package_successful() {
    local pkg_path=$1
    
    for successful_pkg in "${SUCCESSFUL_PACKAGES[@]}"; do
        if [ "$successful_pkg" == "$pkg_path" ]; then
            return 0
        fi
    done
    
    return 1
}

# 尝试单独编译特定包
function build_package() {
    local pkg_path=$1
    local retries=0
    
    # 检查包是否已经成功编译过
    if is_package_successful "$pkg_path"; then
        echo "包 $pkg_path 之前已经成功编译过，跳过重复编译"
        return 0
    fi
    
    echo "开始尝试单独编译包: $pkg_path"
    
    while [ $retries -lt $MAX_RETRIES ]; do
        retries=$((retries + 1))
        echo "第 $retries 次尝试编译 $pkg_path..."
        
        # 清空或备份之前的日志，避免混淆
        if [ -f "package_build.log" ]; then
            mv package_build.log package_build.log.old
        fi
        
        make $pkg_path/{clean,compile} V=sc 2>&1 | tee package_build.log
        
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            echo "包 $pkg_path 编译成功！"
            # 添加到成功列表中
            SUCCESSFUL_PACKAGES+=("$pkg_path")
            return 0
        else
            echo "包 $pkg_path 编译失败，尝试次数: $retries/$MAX_RETRIES"
            
            # 检查是否是网络问题
            if grep -q "Failed to connect\|Couldn't connect to server\|timeout" package_build.log; then
                echo "检测到网络连接问题，等待 30 秒后重试..."
                sleep 30
            fi
        fi
    done
    
    echo "包 $pkg_path 在 $MAX_RETRIES 次尝试后仍然编译失败"
    return 1
}

# 主程序
function run_build_process() {
    # 记录已经尝试过但失败的包
    declare -A FAILED_PACKAGES
    # 记录所有处理过的包，用于检测循环
    declare -A PROCESSED_PACKAGES
    # 循环计数器
    local loop_count=0
    # 连续失败计数
    local consecutive_failures=0
    
    # 确保日志文件存在且为空
    > build.log
    
    while true; do
        # 检查循环次数
        loop_count=$((loop_count + 1))
        if [ $loop_count -gt $MAX_LOOPS ]; then
            echo "警告: 已达到最大循环次数 ($MAX_LOOPS)，脚本将退出。"
            echo "请检查以下包是否存在依赖冲突或其他问题:"
            for pkg in "${!FAILED_PACKAGES[@]}"; do
                echo "  - $pkg (失败次数: ${FAILED_PACKAGES[$pkg]})"
            done
            exit 1
        fi
        
        echo "==== 编译循环 $loop_count/$MAX_LOOPS ===="
        
        # 执行主编译
        main_build
        
        # 如果编译成功，退出循环
        if [ $? -eq 0 ]; then
            echo "整体编译成功完成！"
            break
        fi
        
        # 提取失败的包路径
        failed_pkg=$(extract_failed_package)
        
        if [ $? -ne 0 ] || [ -z "$failed_pkg" ]; then
            echo "无法确定失败的包，请手动检查错误。"
            echo "最后 20 行错误日志："
            tail -n 20 build.log
            exit 1
        fi
        
        echo "检测到失败的包: $failed_pkg"
        
        # 检查是否处理过这个包
        if [ "${PROCESSED_PACKAGES[$failed_pkg]:-0}" -gt 0 ]; then
            consecutive_failures=$((consecutive_failures + 1))
            echo "警告: 包 $failed_pkg 之前已经处理过 ${PROCESSED_PACKAGES[$failed_pkg]} 次"
            
            # 如果连续失败次数过多，可能陷入循环
            if [ $consecutive_failures -ge 3 ]; then
                echo "警告: 检测到连续 $consecutive_failures 次处理相同的包，可能陷入循环"
                echo "请检查是否存在依赖冲突或其他问题。"
                exit 1
            fi
        else
            consecutive_failures=0
        fi
        
        # 更新处理次数
        PROCESSED_PACKAGES[$failed_pkg]=$((${PROCESSED_PACKAGES[$failed_pkg]:-0} + 1))
        
        # 检查这个包是否已经尝试过并失败了MAX_RETRIES次
        if [ "${FAILED_PACKAGES[$failed_pkg]:-0}" -ge $MAX_RETRIES ]; then
            echo "包 $failed_pkg 已经尝试了 $MAX_RETRIES 次仍然失败，停止编译。"
            exit 1
        fi
        
        # 尝试单独编译失败的包
        build_package "$failed_pkg"
        build_result=$?
        
        # 如果包编译失败，记录失败次数并立即退出
        if [ $build_result -ne 0 ]; then
            # 更新失败计数
            FAILED_PACKAGES[$failed_pkg]=$((${FAILED_PACKAGES[$failed_pkg]:-0} + 1))
            
            echo "包 $failed_pkg 编译失败 ${FAILED_PACKAGES[$failed_pkg]} 次，达到最大重试次数，停止编译。"
            echo "请手动解决此包的问题后再重新运行编译。"
            exit 1
        else
            echo "单独编译成功，继续主编译过程..."
        fi
    done
}

# 执行主程序
run_build_process
