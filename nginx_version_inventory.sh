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
# 输出模式：
#     CSV_STDOUT=1（默认使用，本地映射盘场景）：远端只把纯净 CSV 输出到 stdout，控制台
#           提示走 stderr；由本地 ssh 客户端重定向保存到本地映射盘。脚本在远端
#           无法访问本地映射盘，落盘路径/文件名由本地命令的重定向决定。
#     文件模式（不带 CSV_STDOUT）：在远端服务器本机执行时，CSV 写到脚本所在目录（或
#           CSV_DIR/CSV_OUT 指定路径），文件名 <登录IP>.csv。
#     CSV 内分三段独立小节：①物理机 ②运行中容器 ③本地镜像，各带独立标题与表头。
#
# 用法（Windows cmd，脚本与 CSV 同在本地映射盘，如 Z:\nginx）：
#     ssh root@101.201.236.30 "CSV_STDOUT=1 bash -s" < "Z:\nginx\nginx_version_inventory.sh" > "Z:\nginx\101.201.236.30.csv"
#     说明：ssh 目标 IP 与输出文件名保持一致；路径含空格/中文时用英文双引号包裹。
#
# 纯远端服务器本机执行（文件模式）：
#     bash nginx_version_inventory.sh
#     自定义落盘目录 / 文件路径：
#       CSV_DIR=/mnt/share/nginx CSV_OUT=/tmp/nginx.csv DOCKER_CMD="sudo docker" bash nginx_version_inventory.sh
#===============================================================================

set -u

DOCKER_CMD="${DOCKER_CMD:-docker}"
CSV_STDOUT="${CSV_STDOUT:-0}"

# 定位脚本所在目录：脚本放哪，CSV 默认落哪；bash -s（stdin 管道）执行时回退当前工作目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
# CSV 落盘目录，默认与脚本同目录；可用 CSV_DIR 环境变量覆盖
CSV_DIR="${CSV_DIR:-$SCRIPT_DIR}"

# 清洗传入的登录地址：去掉 user@ 前缀和 :端口，只保留 IP
sanitize_ip() {
    local v="$1"
    v="${v##*@}"
    v="${v%%:*}"
    printf '%s' "$v"
}

# 探测服务器首个非回环 IPv4 地址（兜底用）
detect_server_ip() {
    local ip
    # ① hostname -I（Debian/RHEL 通用，输出多个 IP 时取第一个）
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ]; then printf '%s' "$ip"; return; fi
    # ② iproute2：取非 lo 网卡的首个 IPv4
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip -4 -o addr show 2>/dev/null | awk '$2!="lo" {split($4,a,"/"); print a[1]; exit}')"
        [ -n "$ip" ] && { printf '%s' "$ip"; return; }
    fi
    # ③ ifconfig 兜底
    ip="$(ifconfig 2>/dev/null | awk '/inet / && $2!="127.0.0.1" {split($2,a,":"); print a[2]; exit}')"
    [ -n "$ip" ] && { printf '%s' "$ip"; return; }
    printf ''
}

# 文件名优先使用 ssh 登录时传入的 LOGIN_IP（即登录命令里输入的 IP）；
# 未传入时再回退到本机网卡探测 IP；都取不到用默认文件名。
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

# 控制台输出：CSV_STDOUT 模式下全部走 stderr，保证 stdout 是纯净 CSV
say() {
    local fmt="$1"; shift
    if [ "$CSV_STDOUT" = "1" ]; then
        printf "$fmt" "$@" >&2
    else
        printf "$fmt" "$@"
    fi
}

# ===================== 新增：column表格打印函数（核心改动）=====================
# 功能：传入多行 | 分隔文本，自动用column对齐；无column则原样输出
print_table() {
    local input="$1"
    if command -v column >/dev/null 2>&1; then
        # -t 表格模式，-s '|' 指定竖线为字段分隔符
        printf '%s' "$input" | column -t -s '|'
    else
        # 无column（alpine精简镜像），直接原样输出
        printf '%s' "$input"
    fi
}

hr()  { say '%s\n' "------------------------------------------------------------"; }
title() { say '\n%s==== %s ====%s\n' "$C_TITLE" "$1" "$C_RST"; }

# 记录“运行中容器”的 镜像 -> 版本 映射，供第 3 部分复用，避免重复起临时容器
declare -A RUNNING_VER=()

# ---- 版本判断工具函数 --------------------------------------------------------

# 从任意输出中提取三段版本号（如 1.30.7），提取不到返回空
extract_version() {
    printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# 比较两个三段版本号：$1=当前 $2=基准；输出 -1(低) 0(相等) 1(高)
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

# 物理机判定：统一与基准 1.30.7 比较
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

# 容器/镜像判定：按次版本线分别对比基准
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
            # 不属于1.30、1.31版本线，统一建议升级到1.30.7
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

# 判定结论简短化：需要更新 / 无需更新 / 无法判断
judge_short() {
    case "$1" in
        需要更新*) echo "需要更新" ;;
        无需更新*) echo "无需更新" ;;
        *) echo "无法判断" ;;
    esac
}

# 提取纯版本号；提取不到返回“未检测到”
plain_version() {
    local v; v="$(extract_version "$1")"
    [ -z "$v" ] && echo "未检测到" || echo "$v"
}

# 推断应升级到的目标基准版本
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

# CSV 字段转义：含逗号、双引号、换行时用双引号包裹，内部双引号翻倍
csv_escape() {
    local s="$1"
    case "$s" in
        *,*|*\"*|*$'\n'*) printf '"%s"' "${s//\"/\"\"}" ;;
        *) printf '%s' "$s" ;;
    esac
}

# ---- 收集 CSV 行片段 ---------------------------------------------------------
HOST_NOTE=""
CONTAINER_NOTE=""
IMAGE_NOTE=""

CSV_HOST=""
CSV_CONTAINERS=""
CSV_IMAGES=""

# ---- 1. 物理机（裸装）Nginx --------------------------------------------------
title "1. Linux 物理机（系统裸装）Nginx 版本"

if command -v nginx >/dev/null 2>&1; then
    NGINX_BIN="$(command -v nginx)"
    # nginx -v 将版本信息输出到 stderr，需 2>&1 合并
    NGINX_VER="$(nginx -v 2>&1 | tr -d '\r')"

    # 运行状态：优先 systemctl，非 systemd 环境用进程判断兜底
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

# ---- 2. Docker 运行中容器内 Nginx（已改成column自动表格）--------------------------------------------
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
        # 用 | 作为字段分隔符，先拼接所有行，再统一交给column格式化
        table_data=""
        # 表头
        table_data+="容器名|镜像|状态|容器内 Nginx 版本|是否需要更新"$'\n'

        while IFS='|' read -r C_NAME C_IMAGE C_STATUS; do
            [ -z "$C_NAME" ] && continue

            # nginx -v 输出到 stderr，必须 2>&1 合并，不能丢弃 stderr
            VER_RAW="$($DOCKER_CMD exec "$C_NAME" nginx -v 2>&1 | tr -d '\r' || true)"

            if printf '%s' "$VER_RAW" | grep -qi 'nginx/[0-9]'; then
                VER_SHOW="$VER_RAW"
                RUNNING_VER["$C_IMAGE"]="$VER_SHOW"
                VER_UPD="$(check_docker_update "$VER_RAW")"
            else
                VER_SHOW="未检测到 nginx（非 nginx 容器或镜像内无 nginx 二进制）"
                VER_UPD="无法判断（未检测到 nginx）"
            fi

            # 拼接入表格内容，竖线分隔
            table_data+="${C_NAME}|${C_IMAGE}|${C_STATUS}|${VER_SHOW}|${VER_UPD}"$'\n'

            CSV_CONTAINERS="$CSV_CONTAINERS$(printf '%s,%s,%s,%s,%s,%s\n' \
                "$(csv_escape "$C_NAME")" \
                "$(csv_escape "$C_IMAGE")" \
                "$(csv_escape "$C_STATUS")" \
                "$(csv_escape "$(plain_version "$VER_SHOW")")" \
                "$(csv_escape "$(judge_short "$VER_UPD")")" \
                "$(csv_escape "$(target_version "$VER_SHOW")")")"
        done < <($DOCKER_CMD ps --format '{{.Names}}|{{.Image}}|{{.Status}}')

        # 调用函数自动对齐输出表格
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

# ---- 3. Docker 镜像仓库中的 nginx 镜像（已改成column自动表格）--------------------------------------
title "3. 本地 Docker 镜像仓库中的 nginx 相关镜像"

if [ "$DOCKER_AVAILABLE" -eq 1 ]; then
    # 探测单个镜像内的 nginx 真实版本
    # 参数：$1=镜像名(或ID)  $2=镜像ID（名字为 <none> 时兜底用）
    detect_image_version() {
        local ref="$1" img_id="$2" raw

        # ① 复用运行中容器已查到的版本
        if [ -n "${RUNNING_VER[$ref]:-}" ]; then
            printf '%s' "${RUNNING_VER[$ref]}"
            return 0
        fi

        # ② 临时容器：通过 sh 执行 nginx -v（官方镜像均含 sh，通用性最好）
        raw="$($DOCKER_CMD run --rm --entrypoint sh "$ref" -c 'nginx -v 2>&1' 2>/dev/null || true)"
        if printf '%s' "$raw" | grep -qi 'nginx/[0-9]'; then
            printf '%s' "$(printf '%s' "$raw" | grep -oiE 'nginx/[0-9][^ ]*' | head -1)"
            return 0
        fi

        # ③ 名字探测失败（如 Tag 为 <none>），改用镜像 ID 再试一次
        if [ -n "$img_id" ] && [ "$img_id" != "$ref" ]; then
            raw="$($DOCKER_CMD run --rm --entrypoint sh "$img_id" -c 'nginx -v 2>&1' 2>/dev/null || true)"
            if printf '%s' "$raw" | grep -qi 'nginx/[0-9]'; then
                printf '%s' "$(printf '%s' "$raw" | grep -oiE 'nginx/[0-9][^ ]*' | head -1)"
                return 0
            fi
        fi

        # ④ 最后尝试直接以 nginx 为 entrypoint
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
        # | 分隔字段，先拼接全部内容
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

        # 自动格式化输出表格
        say "$(print_table "$img_table")"$'\n'

    else
        say '%s本地镜像仓库中未找到名称含 nginx 的镜像。%s\n' "$C_WARN" "$C_RST"
        IMAGE_NOTE="本地镜像仓库中未找到名称含 nginx 的镜像。"
    fi
else
    say '%s跳过镜像清单（Docker 不可用）。%s\n' "$C_DIM" "$C_RST"
    IMAGE_NOTE="跳过镜像清单（Docker 不可用）。"
fi

# ---- 组装 CSV 内容（三段独立小节，两种模式复用） -----------------------------
CSV_BODY="$(
    # 段一：物理机
    printf '# 一、物理机 Nginx\n'
    printf '主机名,二进制路径,运行状态,Nginx版本,是否需要更新,需要升级至指定版本\n'
    if [ -n "$CSV_HOST" ]; then
        printf '%s\n' "$CSV_HOST"
    else
        printf '%s\n' "$(csv_escape "${HOST_NOTE:-未检测到裸装 nginx。}")"
    fi

    printf '\n'

    # 段二：运行中容器
    printf '# 二、运行中容器\n'
    printf '容器名,镜像,状态,Nginx版本,是否需要更新,需要升级至指定版本\n'
    if [ -n "$CSV_CONTAINERS" ]; then
        printf '%s' "$CSV_CONTAINERS"
    else
        printf '%s\n' "$(csv_escape "${CONTAINER_NOTE:-无运行中容器。}")"
    fi

    printf '\n'

    # 段三：本地镜像
    printf '# 三、本地镜像\n'
    printf '镜像名,镜像ID,大小,创建时间,Nginx版本,是否需要更新,需要升级至指定版本\n'
    if [ -n "$CSV_IMAGES" ]; then
        printf '%s' "$CSV_IMAGES"
    else
        printf '%s\n' "$(csv_escape "${IMAGE_NOTE:-未找到 nginx 相关镜像。}")"
    fi
)"

# ---- 输出分流 ----------------------------------------------------------------
if [ "$CSV_STDOUT" = "1" ]; then
    # 管道回传模式：stdout 只输出纯净 CSV（含 BOM），供本地重定向保存
    printf '\xEF\xBB\xBF'
    printf '%s' "$CSV_BODY"
    say '%s盘点完成，已在当前目录生成CSV文件。%s\n' "$C_OK" "$C_RST"
else
    # 文件模式：CSV 直接写入远端共享挂载目录
    OUT_DIR="$(dirname "$CSV_OUT")"
    if ! mkdir -p "$OUT_DIR" 2>/dev/null; then
        say '%s错误：无法创建共享目录 %s，请检查共享盘挂载与当前用户写权限。%s\n' "$C_WARN" "$OUT_DIR" >&2
        exit 1
    fi
    if [ ! -d "$OUT_DIR" ] || [ ! -w "$OUT_DIR" ]; then
        say '%s错误：目录 %s 不存在或当前用户无写权限，CSV 未落盘。%s\n' "$C_WARN" "$OUT_DIR" >&2
        exit 1
    fi

    {
        printf '\xEF\xBB\xBF'
        printf '%s' "$CSV_BODY"
    } > "$CSV_OUT"

    hr
    say '%s盘点完成，CSV 台账：%s%s\n' "$C_OK" "$C_RST" "$CSV_OUT"
fi
