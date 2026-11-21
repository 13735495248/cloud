#!/usr/bin/env bash
#===============================================================================
# nginx_version_inventory.sh
# 用途：在目标 Linux 服务器上盘点 Nginx 版本
#       1) 物理机（裸装 / 系统包安装）的 Nginx 版本
#       2) Docker 正在运行的容器内的 Nginx 版本
#       3) 本地 Docker 镜像仓库中 nginx 相关镜像清单
# 说明：脚本在被连接的服务器上执行；本地只需通过 ssh 调用即可。
# 用法：
#   bash nginx_version_inventory.sh                 # 本机直接执行
#   DOCKER_CMD="sudo docker" bash nginx_version_inventory.sh
#===============================================================================

set -u

# ---- 基础配置 ----------------------------------------------------------------
# 若当前用户不在 docker 用户组，可通过环境变量指定带 sudo 的 docker 命令：
#   DOCKER_CMD="sudo docker" ./nginx_version_inventory.sh
DOCKER_CMD="${DOCKER_CMD:-docker}"

# ---- 输出颜色（非终端时自动关闭） --------------------------------------------
if [ -t 1 ]; then
    C_TITLE=$'\033[1;36m'
    C_OK=$'\033[1;32m'
    C_WARN=$'\033[1;33m'
    C_DIM=$'\033[2m'
    C_RST=$'\033[0m'
else
    C_TITLE=""; C_OK=""; C_WARN=""; C_DIM=""; C_RST=""
fi

hr() { printf '%s\n' "------------------------------------------------------------"; }
title() { printf '\n%s==== %s ====%s\n' "$C_TITLE" "$1" "$C_RST"; }

# ---- 1. 物理机（裸装）Nginx --------------------------------------------------
title "1. Linux 物理机（系统裸装）Nginx 版本"

if command -v nginx >/dev/null 2>&1; then
    NGINX_BIN="$(command -v nginx)"
    # nginx -v 将版本信息输出到 stderr，需 2>&1 合并
    NGINX_VER="$(nginx -v 2>&1 | tr -d '\r')"
    NGINX_CONF="$(nginx -t 2>&1 | grep -oE '/[^ ]+\.conf' | head -1 || true)"

    printf '%s二进制路径 :%s %s\n' "$C_OK" "$C_RST" "$NGINX_BIN"
    printf '%s版本信息 :%s %s\n' "$C_OK" "$C_RST" "$NGINX_VER"
    [ -n "$NGINX_CONF" ] && printf '%s配置文件 :%s %s\n' "$C_DIM" "$C_RST" "$NGINX_CONF"

    # 系统包管理器侧的安装信息（RPM / DEB）
    if command -v rpm >/dev/null 2>&1 && rpm -q nginx >/dev/null 2>&1; then
        printf '%s包管理器 :%s rpm\n' "$C_DIM" "$C_RST"
        rpm -qi nginx 2>/dev/null | grep -E '^(Name|Version|Release|Vendor|Install Date)' | sed 's/^/          /'
    elif command -v dpkg >/dev/null 2>&1 && dpkg -s nginx >/dev/null 2>&1; then
        printf '%s包管理器 :%s dpkg\n' "$C_DIM" "$C_RST"
        dpkg -s nginx 2>/dev/null | grep -E '^(Package|Version|Maintainer|Installed-Size)' | sed 's/^/          /'
    else
        printf '%s包管理器 :%s 未通过 rpm/dpkg 检测到 nginx 包（可能为源码编译安装）\n' "$C_DIM" "$C_RST"
    fi
else
    printf '%s未在宿主机 PATH 中检测到裸装 nginx（仅运行 Docker 内 Nginx，或未安装）。%s\n' "$C_WARN" "$C_RST"
fi

# ---- 2. Docker 运行中容器内 Nginx --------------------------------------------
title "2. Docker 运行中容器内的 Nginx 版本"

if ! command -v docker >/dev/null 2>&1; then
    printf '%s当前主机未安装 docker 命令，跳过容器盘点。%s\n' "$C_WARN" "$C_RST"
else
    # 校验 docker 是否可正常访问（权限 / 守护进程）
    if ! $DOCKER_CMD info >/dev/null 2>&1; then
        printf '%s无法访问 Docker 守护进程：%s\n请确认 docker 已启动，或使用 DOCKER_CMD="sudo docker" 执行。%s\n' \
            "$C_WARN" "$DOCKER_CMD" "$C_RST"
    else
        # 表头
        printf '%-24s %-32s %-10s %s\n' "容器名" "镜像" "状态" "容器内 Nginx 版本"
        hr

        # 取所有运行中容器：名称 / 镜像 / 状态
        while IFS='|' read -r C_NAME C_IMAGE C_STATUS; do
            [ -z "$C_NAME" ] && continue

            # 在容器内执行 nginx -v；非 nginx 容器会报错，被置为“未检测到”
            VER_RAW="$($DOCKER_CMD exec "$C_NAME" nginx -v 2>&1 | tr -d '\r' || true)"

            if printf '%s' "$VER_RAW" | grep -qi 'nginx/[0-9]'; then
                VER_SHOW="$VER_RAW"
            else
                VER_SHOW="未检测到 nginx（非 nginx 容器或镜像内无 nginx 二进制）"
            fi

            printf '%-24s %-32s %-10s %s\n' \
                "${C_NAME:0:24}" "${C_IMAGE:0:32}" "${C_STATUS:0:10}" "$VER_SHOW"
        done < <($DOCKER_CMD ps --format '{{.Names}}|{{.Image}}|{{.Status}}')

        # 顺便列出已停止的 nginx 相关容器（避免遗漏）
        STOPPED="$($DOCKER_CMD ps -a --filter 'status=exited' --format '{{.Names}}|{{.Image}}' \
            | grep -i nginx || true)"
        if [ -n "$STOPPED" ]; then
            printf '\n%s已停止的 nginx 相关容器：%s\n' "$C_DIM" "$C_RST"
            printf '%s\n' "$STOPPED" | sed 's/|/  ->  /' | sed 's/^/  - /'
        fi
    fi
fi

# ---- 3. Docker 镜像仓库中的 nginx 镜像 --------------------------------------
title "3. 本地 Docker 镜像仓库中的 nginx 相关镜像"

if command -v docker >/dev/null 2>&1 && $DOCKER_CMD info >/dev/null 2>&1; then
    IMG_LIST="$($DOCKER_CMD images --format '{{.Repository}}:{{.Tag}}|{{.ID}}|{{.Size}}|{{.CreatedSince}}' \
        | grep -i nginx || true)"
    if [ -n "$IMG_LIST" ]; then
        printf '%-40s %-16s %-10s %s\n' "镜像" "ID" "大小" "创建时间"
        hr
        printf '%s\n' "$IMG_LIST" | awk -F'|' \
            '{printf "%-40s %-16s %-10s %s\n", substr($1,1,40), substr($2,1,16), $3, $4}'
        cat <<'NOTE'

备注：镜像 Tag 中的版本号（如 nginx:1.25.4）为构建时标签；
如需确认镜像内二进制的精确版本，可对对应镜像执行：
  docker run --rm <镜像名> nginx -v
NOTE
    else
        printf '%s本地镜像仓库中未找到名称含 nginx 的镜像。%s\n' "$C_WARN" "$C_RST"
    fi
else
    printf '%s跳过镜像清单（Docker 不可用）。%s\n' "$C_DIM" "$C_RST"
fi

hr
printf '%s盘点完成。%s\n' "$C_OK" "$C_RST"
#（注：内容由AI生成）
