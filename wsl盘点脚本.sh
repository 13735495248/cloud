#!/usr/bin/env bash
#===============================================================================
# nginx_version_inventory.sh
# 用途：在目标 Linux 服务器上盘点 Nginx 版本，并判断是否需要更新
#     1) 物理机（裸装 / 系统包安装）的 Nginx 版本
#     2) Docker 正在运行的容器内的 Nginx 版本
#     3) 本地 Docker 镜像仓库中 nginx 相关镜像及镜像内真实版本
#
# 更新判定规则：
#     物理机：版本 < 1.30.7 -> 需要更新
#     容器/镜像：
#         1.30.xx 线，基准 1.30.7；1.31.xx 线，基准 1.31.9
#         低于对应基准 -> 需要更新；
#         不属于 1.30.xx、1.31.xx 的所有版本，统一目标升级到 1.30.7
#
# 用法：
#  本地执行（默认生成csv在脚本同目录）：
#       bash nginx_version_inventory.sh
#  docker需要sudo：
#       DOCKER_CMD="sudo docker" bash nginx_version_inventory.sh
#  指定输出路径：
#       CSV_OUT=/tmp/nginx.csv bash nginx_version_inventory.sh
#  纯净CSV输出（ssh远程采集）：
#       CSV_STDOUT=1 bash nginx_version_inventory.sh
#===============================================================================

# 必须bash，拒绝sh
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERROR: 请使用 bash 执行，不要 sh $0" >&2
    exit 1
fi

set -u

DOCKER_CMD="${DOCKER_CMD:-docker}"
CSV_STDOUT="${CSV_STDOUT:-0}"

# 定位脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
CSV_DIR="${CSV_DIR:-$SCRIPT_DIR}"

sanitize_ip() {
    local v="$1"
    v="${v##*@}"
    v="${v%%:*}"
    printf '%s' "$v"
}

detect_server_ip() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then printf '%s' "$ip"; return; fi
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip -4 -o addr show 2>/dev/null | awk '$2!="lo" {split($4,a,"/"); print a[1]; exit}')"
        [ -n "$ip" ] && { printf '%s' "$ip"; return; }
    fi
    ip="$(ifconfig 2>/dev/null | awk '/inet / && $2!="127.0.0.1" {split($2,a,":"); print a[2]; exit}')"
    [ -n "$ip" ] && { printf '%s' "$ip"; return; }
    printf ''
}

if [ -n "${LOGIN_IP:-}" ]; then
    SERVER_IP="$(sanitize_ip "$LOGIN_IP")"
else
    SERVER_IP="$(detect_server_ip)"
fi
if [ -n "$SERVER_IP" ]; then
    CSV_OUT="${CSV_OUT:-$CSV_DIR/$SERVER_IP.csv}"
else
    CSV_OUT="${CSV_OUT:-$CSV_DIR/nginx_inventory.csv}"
fi

# 颜色
if [ -t 1 ]; then
    C_TITLE=$'\033[1;36m'
    C_OK=$'\033[1;32m'
    C_WARN=$'\033[1;33m'
    C_DIM=$'\033[2m'
    C_RST=$'\033[0m'
else
    C_TITLE=""; C_OK=""; C_WARN=""; C_DIM=""; C_RST=""
fi

say() {
    local fmt="$1"; shift
    if [ "$CSV_STDOUT" = "1" ]; then
        printf "$fmt" "$@" >&2
    else
        printf "$fmt" "$@"
    fi
}

print_table() {
    local input="$1"
    if command -v column >/dev/null 2>&1; then
        printf '%s' "$input" | column -t -s '|'
    else
        printf '%s' "$input"
    fi
}

hr()  { say '%s\n' "------------------------------------------------------------"; }
title() { say '\n%s==== %s ====%s\n' "$C_TITLE" "$1" "$C_RST"; }

declare -A RUNNING_VER=()

extract_version() {
    printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

ver_compare() {
    local v1="$1" v2="$2" a1 b1 c1 a2 b2 c2
    IFS='.' read -r a1 b1 c1 <<< "$v1"
    IFS='.' read -r a2 b2 c2 <<< "$v2"
    [ -z "$c1" ] && c1=0
    [ -z "$c2" ] && c2=0
    if   [ "$a1" -ne "$a2" ]; then [ "$a1" -lt "$a2" ] && echo -1 || echo 1
    elif [ "$b1" -ne "$b2" ]; then [ "$b1" -lt "$b2" ] && echo -1 || echo 1
    elif [ "$c1" -ne "$c2" ]; then [ "$c1" -lt "$c2" ] && echo -1 || echo 1
    else echo 0
    fi
}

check_host_update() {
    local v; v="$(extract_version "$1")"
    if [ -z "$v" ]; then
        echo "无法判断（未识别版本）"
        return
    fi
    local cmp; cmp="$(ver_compare "$v" "1.30.7")"
    if [ "$cmp" -lt 0 ]; then
        echo "需要更新（当前 $v，基准 1.30.7）"
    else
        echo "无需更新（$v）"
    fi
}

check_docker_update() {
    local v; v="$(extract_version "$1")"
    if [ -z "$v" ]; then
        echo "无法判断（未识别版本）"
        return
    fi
    local major minor patch base cmp
    IFS='.' read -r major minor patch <<< "$v"
    case "$minor" in
        30) base="1.30.7" ;;
        31) base="1.31.9" ;;
        *)
            echo "需要更新（当前 $v，建议升级到 1.30.7）"
            return ;;
    esac
    cmp="$(ver_compare "$v" "$base")"
    if [ "$cmp" -lt 0 ]; then
        echo "需要更新（当前 $v，基准 $base）"
    else
        echo "无需更新（$v）"
    fi
}

judge_short() {
    case "$1" in
        需要更新*) echo "需要更新" ;;
        无需更新*) echo "无需更新" ;;
        *) echo "无法判断" ;;
    esac
}

plain_version() {
    local v; v="$(extract_version "$1")"
    [ -z "$v" ] && echo "未检测到" || echo "$v"
}

target_version() {
    local v; v="$(extract_version "$1")"
    [ -z "$v" ] && { echo ""; return; }
    local minor; minor="$(printf '%s' "$v" | cut -d. -f2)"
    case "$minor" in
        30) echo "1.30.7" ;;
        31) echo "1.31.9" ;;
        *)  echo "1.30.7" ;;
    esac
}

csv_escape() {
    local s="$1"
    case "$s" in
        *,*|*\"*|*$'\n'*) printf '"%s"' "${s//\"/\"\"}" ;;
        *) printf '%s' "$s" ;;
    esac
}

HOST_NOTE=""
CONTAINER_NOTE=""
IMAGE_NOTE=""

CSV_HOST=""
CSV_CONTAINERS=""
CSV_IMAGES=""

# ---- 1. 物理机 Nginx --------------------------------------------------
title "1. Linux 物理机（系统裸装）Nginx 版本"

if command -v nginx >/dev/null 2>&1; then
    NGINX_BIN="$(command -v nginx)"
    NGINX_VER="$(nginx -v 2>&1 | tr -d '\r')"

    if command -v systemctl >/dev/null 2>&1 && systemctl status nginx >/dev/null 2>&1; then
        NGINX_RUN="$(systemctl is-active nginx 2>/dev/null)"
    elif pgrep -x nginx >/dev/null 2>&1; then
        NGINX_RUN="running（进程存在，非 systemd 管理）"
    else
        NGINX_RUN="inactive（未运行）"
    fi

    NGINX_UPD="$(check_host_update "$NGINX_VER")"

    say '%s二进制路径 :%s %s\n' "$C_OK" "$C_RST" "$NGINX_BIN"
    say '%s版本信息 :%s %s\n' "$C_OK" "$C_RST" "$NGINX_VER"
    say '%s运行状态 :%s %s\n' "$C_DIM" "$C_RST" "$NGINX_RUN"
    say '%s是否需要更新 :%s %s\n' "$C_WARN" "$C_RST" "$NGINX_UPD"

    _HOST_NAME="$(hostname 2>/dev/null || echo unknown)"
    CSV_HOST="$(printf '%s,%s,%s,%s,%s,%s' \
        "$(csv_escape "$_HOST_NAME")" \
        "$(csv_escape "$NGINX_BIN")" \
        "$(csv_escape "$NGINX_RUN")" \
        "$(csv_escape "$(plain_version "$NGINX_VER")")" \
        "$(csv_escape "$(judge_short "$NGINX_UPD")")" \
        "$(csv_escape '1.30.7')")"
else
    say '%s未在宿主机 PATH 中检测到裸装 nginx（仅运行 Docker 内 Nginx，或未安装）。%s\n' "$C_WARN" "$C_RST"
    HOST_NOTE="未在宿主机 PATH 中检测到裸装 nginx（仅运行 Docker 内 Nginx，或未安装）。"
fi

# ---- 2. Docker 运行中容器 Nginx --------------------------------------------
title "2. Docker 运行中容器内的 Nginx 版本"

DOCKER_AVAILABLE=0
if ! command -v docker >/dev/null 2>&1; then
    say '%s当前主机未安装 docker 命令，跳过容器盘点。%s\n' "$C_WARN" "$C_RST"
    CONTAINER_NOTE="当前主机未安装 docker 命令，跳过容器盘点。"
else
    if ! $DOCKER_CMD info >/dev/null 2>&1; then
        say '%s无法访问 Docker 守护进程：%s\n请确认 docker 已启动，或使用 DOCKER_CMD="sudo docker" 执行。%s\n' \
            "$C_WARN" "$DOCKER_CMD" "$C_RST"
        CONTAINER_NOTE="无法访问 Docker 守护进程（$DOCKER_CMD），请确认 docker 已启动或使用 DOCKER_CMD=\"sudo docker\"。"
    else
        DOCKER_AVAILABLE=1
        table_data=""
        table_data+="容器名|镜像|状态|容器内 Nginx 版本|是否需要更新"$'\n'

        while IFS='|' read -r C_NAME C_IMAGE C_STATUS; do
            [ -z "$C_NAME" ] && continue

            VER_RAW="$($DOCKER_CMD exec "$C_NAME" nginx -v 2>&1 | tr -d '\r' || true)"

            if printf '%s' "$VER_RAW" | grep -qi 'nginx/[0-9]'; then
                VER_SHOW="$VER_RAW"
                RUNNING_VER["$C_IMAGE"]="$VER_SHOW"
                VER_UPD="$(check_docker_update "$VER_RAW")"
            else
                VER_SHOW="未检测到 nginx（非 nginx 容器或镜像内无 nginx 二进制）"
                VER_UPD="无法判断（未检测到 nginx）"
            fi

            table_data+="${C_NAME}|${C_IMAGE}|${C_STATUS}|${VER_SHOW}|${VER_UPD}"$'\n'

            CSV_CONTAINERS="$CSV_CONTAINERS$(printf '%s,%s,%s,%s,%s,%s\n' \
                "$(csv_escape "$C_NAME")" \
                "$(csv_escape "$C_IMAGE")" \
                "$(csv_escape "$C_STATUS")" \
                "$(csv_escape "$(plain_version "$VER_SHOW")")" \
                "$(csv_escape "$(judge_short "$VER_UPD")")" \
                "$(csv_escape "$(target_version "$VER_SHOW")")")"
        done < <($DOCKER_CMD ps --format '{{.Names}}|{{.Image}}|{{.Status}}')

        say "$(print_table "$table_data")"$'\n'

        STOPPED="$($DOCKER_CMD ps -a --filter 'status=exited' --format '{{.Names}}|{{.Image}}' \
            | grep -i nginx || true)"
        if [ -n "$STOPPED" ]; then
            say '\n%s已停止的 nginx 相关容器：%s\n' "$C_DIM" "$C_RST"
            say '%s\n' "$(printf '%s\n' "$STOPPED" | sed 's/|/  ->  /' | sed 's/^/  - /')"
        fi

        if [ -z "$CSV_CONTAINERS" ]; then
            CONTAINER_NOTE="当前没有运行中的容器。"
        fi
    fi
fi

# ---- 3. Docker 镜像 Nginx --------------------------------------
title "3. 本地 Docker 镜像仓库中的 nginx 相关镜像"

if [ "$DOCKER_AVAILABLE" -eq 1 ]; then
    detect_image_version() {
        local ref="$1" img_id="$2" raw
        if [ -n "${RUNNING_VER[$ref]:-}" ]; then
            printf '%s' "${RUNNING_VER[$ref]}"
            return 0
        fi
        raw="$($DOCKER_CMD run --rm --entrypoint sh "$ref" -c 'nginx -v 2>&1' 2>/dev/null || true)"
        if printf '%s' "$raw" | grep -qi 'nginx/[0-9]'; then
            printf '%s' "$(printf '%s' "$raw" | grep -oiE 'nginx/[0-9][^ ]*' | head -1)"
            return 0
        fi
        if [ -n "$img_id" ] && [ "$img_id" != "$ref" ]; then
            raw="$($DOCKER_CMD run --rm --entrypoint sh "$img_id" -c 'nginx -v 2>&1' 2>/dev/null || true)"
            if printf '%s' "$raw" | grep -qi 'nginx/[0-9]'; then
                printf '%s' "$(printf '%s' "$raw" | grep -oiE 'nginx/[0-9][^ ]*' | head -1)"
                return 0
            fi
        fi
        raw="$($DOCKER_CMD run --rm --entrypoint nginx "$ref" -v 2>&1 || true)"
        if printf '%s' "$raw" | grep -qi 'nginx/[0-9]'; then
            printf '%s' "$(printf '%s' "$raw" | grep -oiE 'nginx/[0-9][^ ]*' | head -1)"
            return 0
        fi
        printf '获取失败（可手动执行: docker run --rm %s nginx -v）' "$ref"
        return 1
    }

    IMG_LIST="$($DOCKER_CMD images --format '{{.Repository}}:{{.Tag}}|{{.ID}}|{{.Size}}|{{.CreatedSince}}' \
        | grep -i nginx || true)"

    if [ -n "$IMG_LIST" ]; then
        img_table=""
        img_table+="镜像|镜像ID|大小|创建时间|镜像内真实 Nginx 版本|是否需要更新"$'\n'

        while IFS='|' read -r IMG_NAME IMG_ID IMG_SIZE IMG_TIME; do
            [ -z "$IMG_NAME" ] && continue
            IMG_VER="$(detect_image_version "$IMG_NAME" "$IMG_ID")"
            if printf '%s' "$IMG_VER" | grep -qi 'nginx/[0-9]'; then
                IMG_UPD="$(check_docker_update "$IMG_VER")"
            else
                IMG_UPD="无法判断（版本获取失败）"
            fi

            img_table+="${IMG_NAME}|${IMG_ID}|${IMG_SIZE}|${IMG_TIME}|${IMG_VER}|${IMG_UPD}"$'\n'

            CSV_IMAGES="$CSV_IMAGES$(printf '%s,%s,%s,%s,%s,%s,%s\n' \
                "$(csv_escape "$IMG_NAME")" \
                "$(csv_escape "$IMG_ID")" \
                "$(csv_escape "$IMG_SIZE")" \
                "$(csv_escape "$IMG_TIME")" \
                "$(csv_escape "$(plain_version "$IMG_VER")")" \
                "$(csv_escape "$(judge_short "$IMG_UPD")")" \
                "$(csv_escape "$(target_version "$IMG_VER")")")"
        done <<< "$IMG_LIST"

        say "$(print_table "$img_table")"$'\n'
    else
        say '%s本地镜像仓库中未找到名称含 nginx 的镜像。%s\n' "$C_WARN" "$C_RST"
        IMAGE_NOTE="本地镜像仓库中未找到名称含 nginx 的镜像。"
    fi
else
    say '%s跳过镜像清单（Docker 不可用）。%s\n' "$C_DIM" "$C_RST"
    IMAGE_NOTE="跳过镜像清单（Docker 不可用）。"
fi

# ---- 组装CSV ------------------------------------------------
CSV_BODY="$(
    printf '# 一、物理机 Nginx\n'
    printf '主机名,二进制路径,运行状态,Nginx版本,是否需要更新,需要升级至指定版本\n'
    if [ -n "$CSV_HOST" ]; then
        printf '%s\n' "$CSV_HOST"
    else
        printf '%s\n' "$(csv_escape "${HOST_NOTE:-未检测到裸装 nginx。}")"
    fi
    printf '\n'

    printf '# 二、运行中容器\n'
    printf '容器名,镜像,状态,Nginx版本,是否需要更新,需要升级至指定版本\n'
    if [ -n "$CSV_CONTAINERS" ]; then
        printf '%s' "$CSV_CONTAINERS"
    else
        printf '%s\n' "$(csv_escape "${CONTAINER_NOTE:-无运行中容器。}")"
    fi
    printf '\n'

    printf '# 三、本地镜像\n'
    printf '镜像名,镜像ID,大小,创建时间,Nginx版本,是否需要更新,需要升级至指定版本\n'
    if [ -n "$CSV_IMAGES" ]; then
        printf '%s' "$CSV_IMAGES"
    else
        printf '%s\n' "$(csv_escape "${IMAGE_NOTE:-未找到 nginx 相关镜像。}")"
    fi
)"

if [ "$CSV_STDOUT" = "1" ]; then
    printf '\xEF\xBB\xBF'
    printf '%s' "$CSV_BODY"
    say '%s盘点完成。%s\n' "$C_OK" "$C_RST"
else
    OUT_DIR="$(dirname "$CSV_OUT")"
    if ! mkdir -p "$OUT_DIR" 2>/dev/null; then
        say '%s错误：无法创建目录 %s，请检查权限。%s\n' "$C_WARN" "$OUT_DIR" >&2
        exit 1
    fi
    if [ ! -d "$OUT_DIR" ] || [ ! -w "$OUT_DIR" ]; then
        say '%s错误：目录 %s 无写权限，CSV未落盘。%s\n' "$C_WARN" "$OUT_DIR" >&2
        exit 1
    fi
    {
        printf '\xEF\xBB\xBF'
        printf '%s' "$CSV_BODY"
    } > "$CSV_OUT"
    hr
    say '%s盘点完成，CSV台账：%s%s\n' "$C_OK" "$C_RST" "$CSV_OUT"
fi
