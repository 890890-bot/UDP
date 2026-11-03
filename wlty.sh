#!/bin/bash
# ==============================================================================
# WLTY v4.1 — Hy2 (QUIC/UDP) 网络调优引擎 (含河南/黑龙江节点 · 穿透版)
# ------------------------------------------------------------------------------
#  控制面板: sudo wlty
#   0 网络体检 : UDP健康度 + Hy2 隧道实测
#   1 科学调优 : Hy2/QUIC-UDP 专项优化 (零中断热更新)
#   2 一键删除 : 卸载 wlty 并复位全部配置
#   3 回程测试 : 检测到国内节点的物理路由 (看是否绕路)
#   4 退出面板
#
#  直调参数: wlty 0|test / wlty 3|route / wlty tunnel / wlty 1|apply / wlty 2|remove
# ==============================================================================

G='\033[1;32m'; Y='\033[1;33m'; C='\033[1;36m'; B='\033[1;34m'; R='\033[1;31m'; P='\033[0m'; D='\033[0;37m'
[[ $EUID -ne 0 ]] && { echo -e "${R}请使用 sudo wlty 运行!${P}"; exit 1; }

SVC_NAME="wlty-network-tuning"
NIC_SH="/usr/local/bin/wlty-nic-tuning.sh"
SYSCTL_FILE="/etc/sysctl.d/99-wlty.conf"
CHAIN="WLTY_TCPMSS"
LIMITS_FILE="/etc/security/limits.d/99-wlty-nofiles.conf"
SYS_CONF="/etc/systemd/system.conf.d/99-wlty-nofiles.conf"
MOD_FILE="/etc/modules-load.d/wlty-nf-conntrack.conf"
STATE_FILE="/var/lib/wlty-state"

# 回程检测目标 (可自行增删)
RT_NAMES=(上海电信 广东电信 北京联通 广东移动 上海联通 河南电信 河南联通 黑龙江电信 黑龙江联通)
RT_IPS=(114.114.114.114 202.96.128.86 202.106.0.20 211.136.17.100 210.22.70.3 222.88.88.88 202.102.224.68 219.147.198.230 221.212.91.108)

declare -A GEO_CACHE
declare -a HOP_IPS HOP_RTTS

declare -A CN_MAP=(
    [CN]="中国" [HK]="中国香港" [MO]="中国澳门" [TW]="中国台湾"
    [US]="美国" [JP]="日本" [SG]="新加坡" [KR]="韩国" [DE]="德国" [GB]="英国"
    [FR]="法国" [NL]="荷兰" [CA]="加拿大" [AU]="澳大利亚" [RU]="俄罗斯"
    [IN]="印度" [MY]="马来西亚" [TH]="泰国" [VN]="越南" [PH]="菲律宾"
)

check_deps() {
    local missing=()
    for cmd in curl ping traceroute ethtool python3 openssl mtr; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if (( ${#missing[@]} > 0 )); then
        echo -e "  ${Y}▶ 检测到缺少依赖工具: ${missing[*]}${P}"
        echo -e "  ${Y}▶ 正在尝试自动安装 (这可能需要几十秒)...${P}"
        if command -v apt-get &>/dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq curl iputils-ping traceroute ethtool python3 openssl mtr-tiny >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y -q curl iputils traceroute ethtool python3 openssl mtr >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y -q curl iputils traceroute ethtool python3 openssl mtr >/dev/null 2>&1
        elif command -v apk &>/dev/null; then
            apk add --quiet curl iputils traceroute ethtool python3 openssl mtr >/dev/null 2>&1
        else
            warn "未识别的包管理器，请手动安装上述依赖。"
            return 1
        fi
        local still_missing=()
        for cmd in "${missing[@]}"; do
            command -v "$cmd" &>/dev/null || still_missing+=("$cmd")
        done
        if (( ${#still_missing[@]} > 0 )); then
            warn "部分依赖安装失败: ${still_missing[*]}"
            return 1
        else
            echo -e "  ${G}✓ 依赖安装完成${P}\n"
        fi
    fi
    return 0
}

h1()   { echo -e "\n${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${P}"; echo -e " ${B}$1${P}"; echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${P}"; }
note() { echo -e "  ${D}※ $1${P}"; }
warn() { echo -e "  ${Y}△ $1${P}"; }

dwidth() {
    local LC_ALL=C
    local s bytes cont ascii ch i
    s=$(printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*m//g')
    bytes=${#s}; cont=0; ascii=0
    for ((i=0; i<bytes; i++)); do
        ch="${s:i:1}"
        [[ "$ch" > $'\x1f' && "$ch" < $'\x7f' ]] && ((ascii++))
        [[ "$ch" > $'\x7f' && "$ch" < $'\xc0' ]] && ((cont++))
    done
    echo $(( 2*(bytes-cont) - ascii ))
}
pad()   { local d=$(( $2 - $(dwidth "$1") )); (( d < 0 )) && d=0; printf '%*s' "$d" ''; }
trunc() {
    local s="$1" w="$2" out="" ch cw=0 c
    for ((i=0; i<${#s}; i++)); do
        ch="${s:i:1}"
        c=$(dwidth "$ch")
        (( cw + c > w )) && { out="${out}…"; break; }
        out="${out}${ch}"; (( cw += c ))
    done
    printf '%s' "$out"
}

kv()  { printf "  ${B}%s${P}%s ${D}│${P} %b\n" "$1" "$(pad "$1" "${3:-14}")" "$2"; }
t_head() { printf "  ${C}%-22s ${C}%-20s ${C}%-20s${P}\n" "$1" "$2" "$3"; echo -e "  ${D}──────────────────────────────────────────────────────────${P}"; }
t_row()  { printf "  %-22s %s%s %s%s %b\n" "$1" "$2" "$(pad "$2" 20)" "$3" "$(pad "$3" 20)" "$4"; }
t4_head() { printf "  ${C}%-16s ${C}%-30s ${C}%-12s ${C}%-12s${P}\n" "$1" "$2" "$3" "$4"; echo -e "  ${D}──────────────────────────────────────────────────────────────────────${P}"; }
t4_row()  { printf "  %-16s %-30s %-12s %b\n" "$1" "$2" "$3" "$4"; }

cpu_snap() { awk '/^cpu /{idle=$5+$6; tot=0; for(i=2;i<=NF;i++) tot+=$i; print idle, tot}' /proc/stat 2>/dev/null; }
pct_busy() { awk -v bi="$1" -v bt="$2" -v ai="$3" -v at="$4" 'BEGIN{dt=at-bt; di=ai-bi; printf "%.0f", (dt>0 ? 100*(dt-di)/dt : 0)}'; }

is_private_ip() {
    local ip="$1"
    [[ "$ip" =~ ^(10|127)\. ]] || [[ "$ip" =~ ^192\.168\. ]] || \
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] || [[ "$ip" =~ ^169\.254\. ]] || \
    [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] || [[ "$ip" =~ ^0\. ]]
}

has_tun() { ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -qE '^tun[0-9]+$'; }

geo_lookup() {
    local ip="$1" res c ci cc
    # 首选 HTTPS + 中文输出的 ipwho.is (免费 1 万次/月, 无需密钥, 全程加密)
    res=$(curl -4 -s -m 4 "https://ipwho.is/${ip}?lang=zh" 2>/dev/null)
    if echo "$res" | grep -q '"success":true'; then
        c=$(echo "$res" | grep -oP '"country":"\K[^"]+')
        ci=$(echo "$res" | grep -oP '"city":"\K[^"]+')
        if [[ "$c" =~ [A-Za-z] ]]; then
            cc=$(echo "$res" | grep -oP '"country_code":"\K[A-Z]{2}')
            c="${CN_MAP[$cc]:-$c}"
        fi
        echo "${c:-?}|${ci:-?}"
        return
    fi
    # 备选 HTTPS: ipinfo.io (英文国家名, 用 CN_MAP 转中文)
    res=$(curl -4 -s -m 4 "https://ipinfo.io/${ip}/json" 2>/dev/null)
    if echo "$res" | grep -q '"country"'; then
        c=$(echo "$res" | grep -oP '"country": "\K[A-Z]{2}')
        ci=$(echo "$res" | grep -oP '"city": "\K[^"]+')
        echo "${CN_MAP[$c]:-$c}|${ci:-?}"
        return
    fi
    echo "?|?"
}
geo() {
    local ip="$1" res
    res="${GEO_CACHE[$ip]:-}"
    if [[ -z "$res" ]]; then
        res=$(geo_lookup "$ip")
        GEO_CACHE[$ip]="$res"
        sleep 0.15
    fi
    echo "$res"
}
geo_self() {
    local res c
    res=$(curl -4 -s -m 5 "https://ipwho.is/?lang=zh" 2>/dev/null)
    c=$(echo "$res" | grep -oP '"country":"\K[^"]+')
    if [[ -z "$c" || "$c" == "null" ]]; then
        res=$(curl -4 -s -m 5 "https://ipinfo.io/json" 2>/dev/null)
        c=$(echo "$res" | grep -oP '"country": "\K[A-Z]{2}')
        c="${CN_MAP[$c]:-$c}"
    fi
    [[ -n "$c" && "$c" != "null" ]] && echo "$c" || echo "未知"
}

# 优化探测逻辑：优先 ICMP 提延迟，其次 TCP/UDP 穿透
trace_hops() {
    local tgt="$1" line ip rtt t
    HOP_IPS=(); HOP_RTTS=()

    # 1. 动态插队，临时放行测试包（绕过本地代理）
    iptables -t nat -I OUTPUT -d "$tgt" -j RETURN 2>/dev/null
    iptables -t mangle -I OUTPUT -d "$tgt" -j RETURN 2>/dev/null

    if command -v traceroute &>/dev/null; then
        local methods=(
            "traceroute -I -n -q 1 -w 1 -m 14 -i $NIC $tgt"
            "traceroute -T -p 80 -n -q 1 -w 1 -m 14 -i $NIC $tgt"
            "traceroute -n -q 1 -w 1 -m 14 -i $NIC $tgt"
        )
        local m tmp_out
        for m in "${methods[@]}"; do
            tmp_out=$($m 2>/dev/null)
            while IFS= read -r line; do
                # 关键: traceroute 首行是 "traceroute to 目标IP (目标IP), ..." 头部,
                # 含目标 IP, 不能作为跳点解析; 这里只解析以跳数开头的行。
                [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]] ]] || continue
                ip=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
                rtt=$(echo "$line" | grep -oE '[0-9.]+ ms' | head -n1 | grep -oE '[0-9.]+')
                [[ -n "$ip" ]] && { HOP_IPS+=("$ip"); HOP_RTTS+=("${rtt:-*}"); }
            done <<< "$tmp_out"
            (( ${#HOP_IPS[@]} > 0 )) && break
        done
    fi

    # 2. 清理临时规则
    iptables -t nat -D OUTPUT -d "$tgt" -j RETURN 2>/dev/null
    iptables -t mangle -D OUTPUT -d "$tgt" -j RETURN 2>/dev/null
}

free_port() {
    local p="$1"
    while ss -tln 2>/dev/null | grep -q ":${p} " || ss -uln 2>/dev/null | grep -q ":${p} "; do p=$((p+1)); done
    echo "$p"
}
is_tuned()  { [[ -f "$SYSCTL_FILE" ]] || systemctl is-active --quiet "$SVC_NAME" 2>/dev/null; }
press_any() { echo; echo -e -n "  按回车返回控制面板..."; read -r _; }

scan_system() {
    OS_NAME=$(grep -oP '(?<=^PRETTY_NAME=).+' /etc/os-release 2>/dev/null | tr -d '"')
    OS_NAME=${OS_NAME:-unknown}
    KERNEL=$(uname -r)
    VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
    CORES=$(nproc)
    MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
    SWAP_MB=$(free -m | awk '/^Swap:/{print $2}')

    NIC=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
    [[ -z "$NIC" ]] && NIC=$(ip -o link show up 2>/dev/null | awk -F': ' '!/lo|vir|wl|docker|veth|br-|dummy|tun|tap|sit|ifb/{print $2;exit}')
    MTU=$(cat /sys/class/net/$NIC/mtu 2>/dev/null || echo 1500)
    RX_Q=$(ls -d /sys/class/net/$NIC/queues/rx-* 2>/dev/null | wc -l)
    TX_Q=$(ls -d /sys/class/net/$NIC/queues/tx-* 2>/dev/null | wc -l)

    PROCS=$(ps -eo comm= | grep -xE 'sing-box|xray|hysteria|hysteria-server' | sort -u | xargs)
    MAIN_PID=$(pgrep -x -o sing-box || pgrep -x -o hysteria || pgrep -x -o hysteria-server || pgrep -x -o xray)
    UDP_PORTS=$(ss -ulnp 2>/dev/null | grep -E 'sing-box|xray|hysteria' | awk '{p=$5; sub(/^.*:/,"",p); print p}' | sort -un | xargs)

    HOP_RAW=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -E -- "-p udp .*--dports? [0-9:,]+.*(DNAT|REDIRECT)")
    HOP_RANGES=""; HOP_TARGETS=""; HOP_COUNT=0
    if [[ -n "$HOP_RAW" ]]; then
        while IFS= read -r line; do
            dp=$(echo "$line" | grep -oE -- "--dports? [0-9:,]+" | awk '{print $2}')
            tp=$(echo "$line" | grep -oE "(--to-destination :|--to-ports )[0-9]+" | grep -oE "[0-9]+$")
            [[ -n "$dp" && " $HOP_RANGES " != *" $dp "* ]] && HOP_RANGES="${HOP_RANGES}${dp} "
            [[ -n "$tp" && " $HOP_TARGETS " != *" $tp "* ]] && HOP_TARGETS="${HOP_TARGETS}${tp} "
            if [[ -n "$dp" ]]; then
                IFS=',' read -ra PARTS <<< "$dp"
                for item in "${PARTS[@]}"; do
                    if [[ "$item" == *:* ]]; then
                        s_p=${item%:*}; e_p=${item#*:}
                        (( e_p >= s_p )) && HOP_COUNT=$((HOP_COUNT + e_p - s_p + 1))
                    elif [[ "$item" =~ ^[0-9]+$ ]]; then
                        HOP_COUNT=$((HOP_COUNT + 1))
                    fi
                done
            fi
        done <<< "$HOP_RAW"
    fi

    if (( MEM_MB < 768 )); then
        TIER="微型(<768MB)"; T_BUF=16777216; T_QLEN=1500; T_BACKLOG=16384; T_BUDGET=600; T_BUDGET_US=4000; T_RING=1024
    elif (( MEM_MB <= 2500 )); then
        TIER="标准(1~2.5GB)"; T_BUF=33554432; T_QLEN=3000; T_BACKLOG=32768; T_BUDGET=1000; T_BUDGET_US=6000; T_RING=2048
    else
        TIER="高配(>2.5GB)"; T_BUF=67108864; T_QLEN=5000; T_BACKLOG=65536; T_BUDGET=2000; T_BUDGET_US=8000; T_RING=4096
    fi
    T_CT=$(( MEM_MB * 128 ))
    (( T_CT < 65536 )) && T_CT=65536
    (( T_CT > 1048576 )) && T_CT=1048576
    (( HOP_COUNT > 20000 && T_CT < 262144 )) && T_CT=262144
    UDPM_MIN=$((MEM_MB*4)); UDPM_PRES=$((MEM_MB*8)); UDPM_MAX=$((MEM_MB*16))

    if (( CORES > 1 && RX_Q == 1 )); then
        NEED_RPS="yes"
        RPSC=$(( CORES > 32 ? 32 : CORES ))
        RPS_MASK=$(printf "%x" $(( (1 << RPSC) - 1 )))
    else
        NEED_RPS="no"; RPS_MASK=0
    fi
}

collect_metrics() {
    CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    QD=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)
    RM=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    WM=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
    QL=$(cat /sys/class/net/$NIC/tx_queue_len 2>/dev/null || echo 1000)
    BL=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo 1000)

    CT_CUR=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
    CT_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 0)
    CT_PCT=$(( CT_MAX > 0 ? CT_CUR * 100 / CT_MAX : 0 ))
    UTO=$(sysctl -n net.netfilter.nf_conntrack_udp_timeout 2>/dev/null || echo 30)
    USTO=$(sysctl -n net.netfilter.nf_conntrack_udp_timeout_stream 2>/dev/null || echo 120)

    UDP_IN=$(awk '/^Udp:/{getline; print $2}' /proc/net/snmp 2>/dev/null || echo 0)
    UDP_OUT=$(awk '/^Udp:/{getline; print $5}' /proc/net/snmp 2>/dev/null || echo 0)
    UDP_NP=$(awk '/^Udp:/{getline; print $3}' /proc/net/snmp 2>/dev/null || echo 0)
    UDP_RCV_ERR=$(awk '/^Udp:/{getline; print $6}' /proc/net/snmp 2>/dev/null || echo 0)
    UDP_SND_ERR=$(awk '/^Udp:/{getline; print $7}' /proc/net/snmp 2>/dev/null || echo 0)

    RPS_CUR=$(cat /sys/class/net/$NIC/queues/rx-0/rps_cpus 2>/dev/null || echo 0)
    RING_CUR=$(ethtool -g "$NIC" 2>/dev/null | sed -n '/Current hardware settings:/,$p' | awk '/RX:/{print $2;exit}')
    TXUDP_SEG=$(ethtool -k "$NIC" 2>/dev/null | awk '/tx-udp-segmentation/{print $2;exit}')
    GRO_STATE=$(ethtool -k "$NIC" 2>/dev/null | awk '/generic-receive-offload/{print $2;exit}')
    MSS_S=$(iptables -t mangle -S $CHAIN 2>/dev/null | grep -q TCPMSS && echo "已开启" || echo "未开启")

    if [[ -n "$MAIN_PID" && -d "/proc/$MAIN_PID" ]]; then
        P_NF=$(awk '/Max open files/{print $4}' /proc/$MAIN_PID/limits 2>/dev/null)
        P_NI=$(ps -o ni= -p "$MAIN_PID" 2>/dev/null | tr -d ' ')
        P_OOM=$(cat /proc/$MAIN_PID/oom_score_adj 2>/dev/null)
    else
        P_NF=$(ulimit -n); P_NI="无"; P_OOM="无"
    fi
}

panel() {
    clear 2>/dev/null || true
    scan_system; collect_metrics
    local tuned="${R}未调优${P}"
    is_tuned && tuned="${G}已调优 ✓${P}"

    echo -e "\n  ${C}WLTY v4.1 · Hy2 (QUIC/UDP) 网络调优控制面板${P}"
    echo -e "  ${D}────────────────────────────────────────────────────────────${P}"

    local key_w=12
    printf "  ${B}%-${key_w}s${P} ${D}│${P} %s\n" "系统" "${OS_NAME} · 内核 ${KERNEL} · ${VIRT}"
    printf "  ${B}%-${key_w}s${P} ${D}│${P} %s\n" "硬件" "${CORES} 核 / ${MEM_MB} MB 内存 (Swap ${SWAP_MB} MB)"
    printf "  ${B}%-${key_w}s${P} ${D}│${P} %s\n" "网卡" "${NIC} · MTU ${MTU} · RX${RX_Q}/TX${TX_Q} 队列 · 环形缓冲 ${RING_CUR:-?}"
    printf "  ${B}%-${key_w}s${P} ${D}│${P} %s\n" "代理" "${PROCS:-未检测到} (PID ${MAIN_PID:-无}) · UDP端口 ${UDP_PORTS:-无}"
    printf "  ${B}%-${key_w}s${P} ${D}│${P} %s\n" "端口跳跃" "${HOP_COUNT} 个 → ${HOP_TARGETS:-无} · ${HOP_RANGES:-未设置}"
    printf "  ${B}%-${key_w}s${P} ${D}│${P} %s\n" "内核网络" "${CC}+${QD} · UDP缓冲 ${RM}B · backlog ${BL}"
    printf "  ${B}%-${key_w}s${P} ${D}│${P} %s\n" "conntrack" "${CT_CUR}/${CT_MAX} (${CT_PCT}%) · 超时 ${UTO}/${USTO}s · 溢出 收${UDP_RCV_ERR}/发${UDP_SND_ERR}"
    printf "  ${B}%-${key_w}s${P} ${D}│${P} %s\n" "硬件卸载" "GRO ${GRO_STATE:-?} · UDP-GSO ${TXUDP_SEG:-?} · RPS ${RPS_CUR:-0}"
    printf "  ${B}%-${key_w}s${P} ${D}│${P} %b\n" "调优状态" "${tuned}"

    echo -e "  ${D}────────────────────────────────────────────────────────────${P}"
    echo -e "  ${Y}0.${P} 网络体检  ${D}(UDP健康度 + Hy2 隧道实测)${P}"
    echo -e "  ${Y}1.${P} 科学调优  ${D}(Hy2/QUIC-UDP 专项优化 · 零中断热更新)${P}"
    echo -e "  ${Y}2.${P} 一键删除  ${D}(卸载 wlty 并复位全部系统配置)${P}"
    echo -e "  ${Y}3.${P} 回程测试  ${D}(检测到国内节点的物理路由, 看是否绕路)${P}"
    echo -e "  ${Y}4.${P} 退出面板  ${D}(返回 shell)${P}"
    echo -e "  ${D}────────────────────────────────────────────────────────────${P}"
}

save_state() {
    local PR CC QD TMP SS
    CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)
    QD=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo fq_codel)
    PR=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | tr '\t' ' ')
    TMP=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo 0)
    SS=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo 1)
    cat > "$STATE_FILE" << STATE
NIC=$NIC
QLEN=$QL
RM=$RM
WM=$WM
BL=$BL
UTO=$UTO
USTO=$USTO
CTMAX=$CT_MAX
RING=${RING_CUR:-1024}
CC=$CC
QD=$QD
PR="$PR"
TMP=$TMP
SS=$SS
STATE
}
restore_state() {
    local V_CC=cubic V_QD=fq_codel V_RM=212992 V_WM=212992 V_BL=1000 V_UTO=30 V_USTO=120
    local V_CT=65536 V_QL=1000 V_RING=1024 V_PR="32768 60999" V_TMP=0 V_SS=1
    if [[ -f "$STATE_FILE" ]]; then
        . "$STATE_FILE" 2>/dev/null
        [[ "$CC" =~ ^[A-Za-z0-9_]+$ ]] && V_CC="$CC"
        [[ "$QD" =~ ^[A-Za-z0-9_]+$ ]] && V_QD="$QD"
        [[ "$RM" =~ ^[0-9]+$ ]] && V_RM="$RM"
        [[ "$WM" =~ ^[0-9]+$ ]] && V_WM="$WM"
        [[ "$BL" =~ ^[0-9]+$ ]] && V_BL="$BL"
        [[ "$UTO" =~ ^[0-9]+$ ]] && V_UTO="$UTO"
        [[ "$USTO" =~ ^[0-9]+$ ]] && V_USTO="$USTO"
        [[ "$CTMAX" =~ ^[0-9]+$ ]] && V_CT="$CTMAX"
        [[ "$QLEN" =~ ^[0-9]+$ ]] && V_QL="$QLEN"
        [[ "$RING" =~ ^[0-9]+$ ]] && V_RING="$RING"
        [[ -n "$PR" ]] && V_PR="$PR"
        [[ "$TMP" =~ ^[0-9]+$ ]] && V_TMP="$TMP"
        [[ "$SS" =~ ^[0-9]+$ ]] && V_SS="$SS"
        [[ -n "$NIC" ]] && NIC="$NIC"
    fi
    sysctl -w net.core.rmem_max=$V_RM net.core.wmem_max=$V_WM \
               net.core.rmem_default=212992 net.core.wmem_default=212992 \
               net.core.netdev_max_backlog=$V_BL net.core.netdev_budget=300 \
               net.core.netdev_budget_usecs=2000 >/dev/null 2>&1
    sysctl -w net.ipv4.udp_rmem_min=4096 net.ipv4.udp_wmem_min=4096 \
               "net.ipv4.ip_local_port_range=$V_PR" \
               net.ipv4.tcp_mtu_probing=$V_TMP net.ipv4.tcp_slow_start_after_idle=$V_SS \
               net.core.default_qdisc=$V_QD >/dev/null 2>&1
    modprobe tcp_cubic 2>/dev/null
    sysctl -w net.ipv4.tcp_congestion_control=$V_CC >/dev/null 2>&1 || \
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    sysctl -w net.netfilter.nf_conntrack_max=$V_CT \
               net.netfilter.nf_conntrack_udp_timeout=$V_UTO \
               net.netfilter.nf_conntrack_udp_timeout_stream=$V_USTO >/dev/null 2>&1
    sysctl -w net.core.rps_sock_flow_entries=0 >/dev/null 2>&1
    ip link set dev "$NIC" txqueuelen "$V_QL" 2>/dev/null
    command -v ethtool &>/dev/null && ethtool -G "$NIC" rx "$V_RING" tx "$V_RING" 2>/dev/null
    echo -e "  ${G}✓ 运行值已复位 (精确恢复到本次调优前)${P}"
}

apply_tuning() {
    scan_system; collect_metrics
    h1 "Hy2 (QUIC/UDP) 科学调优 · 零中断热更新"
    kv "调优分档" "$TIER"
    kv "目标参数" "UDP缓冲 $((T_BUF/1048576))MB · backlog $T_BACKLOG · conntrack $T_CT · Ring $T_RING"
    kv "端口跳跃" "$HOP_COUNT 个端口 (conntrack 已相应扩容)"
    if [[ -z "$MAIN_PID" ]]; then warn "未检测到代理进程, 仅执行系统层调优"
    else kv "代理进程" "${PROCS} (PID ${MAIN_PID}, 热更新不重启)"; fi

    [[ -f "$STATE_FILE" ]] || save_state

    local B_L=(UDP缓冲上限 收包背压 conntrack容量 UDP超时 环形缓冲RX UDP-GSO TCPMSS子链 代理进程保护 BBR/qdisc)
    local B_V=("${RM}B" "qlen${QL}/bl${BL}" "${CT_CUR}/${CT_MAX}" "${UTO}/${USTO}s" "${RING_CUR:-?}" "${TXUDP_SEG:-?}" "$MSS_S" "nf${P_NF}/ni${P_NI}/oom${P_OOM}" "${CC}/${QD}")

    echo -e "\n  ${Y}>>> 正在应用系统调优...${P}"
    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        systemctl disable --now irqbalance >/dev/null 2>&1
        echo -e "  ${G}✓ irqbalance 已禁用 (VPS 推荐)${P}"
    fi
    modprobe tcp_bbr 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true
    mkdir -p /etc/modules-load.d
    echo nf_conntrack > "$MOD_FILE"

    cat > "$SYSCTL_FILE" << SYS
# WLTY v4.1 生成的 Hy2 (QUIC/UDP) 科学调优 — 执行 wlty 2 可一键清除
# ① UDP 缓冲
net.core.rmem_max = $T_BUF
net.core.wmem_max = $T_BUF
net.core.rmem_default = $((T_BUF/16))
net.core.wmem_default = $((T_BUF/16))
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
# ② UDP 全局内存池 (页)
net.ipv4.udp_mem = $UDPM_MIN $UDPM_PRES $UDPM_MAX
# ③ 本机出站 UDP 源端口池
net.ipv4.ip_local_port_range = 1024 65535
# ④ 收包背压与软中断预算
net.core.netdev_max_backlog = $T_BACKLOG
net.core.netdev_budget = $T_BUDGET
net.core.netdev_budget_usecs = $T_BUDGET_US
# ⑤ conntrack (UDP 超时保持 30/120s, 防 QUIC 空闲断流)
net.netfilter.nf_conntrack_max = $T_CT
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120
# ⑥ 本机出站 TCP
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
SYS
    sysctl --system >/dev/null 2>&1
    echo -e "  ${G}✓ sysctl 已写入并生效${P}"

    cat > "$NIC_SH" << NICSH
#!/bin/bash
modprobe nf_conntrack 2>/dev/null
sysctl --system >/dev/null 2>&1

NIC="$NIC"
cur=\$(ethtool -g "\$NIC" 2>/dev/null | sed -n '/Current hardware settings:/,\$p' | awk '/RX:/{print \$2;exit}')
if [[ -n "\$cur" && "\$cur" -lt $T_RING ]]; then
    ethtool -G "\$NIC" rx $T_RING tx $T_RING 2>/dev/null || ethtool -G "\$NIC" rx 1024 tx 1024 2>/dev/null || true
fi
ethtool -K "\$NIC" gro on 2>/dev/null
ethtool -K "\$NIC" tx-udp-segmentation on 2>/dev/null
ethtool -K "\$NIC" rx-gro-list on 2>/dev/null
ip link set dev "\$NIC" txqueuelen $T_QLEN 2>/dev/null
echo 100 > /sys/class/net/\$NIC/napi_defer_hard_irqs 2>/dev/null
echo 200000 > /sys/class/net/\$NIC/gro_flush_timeout 2>/dev/null

CORES=$CORES
RX_Q=\$(ls -d /sys/class/net/\$NIC/queues/rx-* 2>/dev/null | wc -l)
if (( CORES > 1 && RX_Q == 1 )); then
    RPSC=\$(( CORES > 32 ? 32 : CORES ))
    MASK=\$(printf "%x" \$(( (1 << RPSC) - 1 )))
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
    echo \$MASK > /sys/class/net/\$NIC/queues/rx-0/rps_cpus
    echo 32768 > /sys/class/net/\$NIC/queues/rx-0/rps_flow_cnt
fi

q=0
for f in /sys/class/net/\$NIC/queues/tx-*/xps_cpus; do
    cpu=\$(( q % CORES )); (( cpu > 31 )) && cpu=31
    printf "%x" \$(( 1 << cpu )) > "\$f" 2>/dev/null
    q=\$(( q + 1 ))
done

iptables -t mangle -N $CHAIN 2>/dev/null || iptables -t mangle -F $CHAIN
iptables -t mangle -A $CHAIN -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -C FORWARD -j $CHAIN 2>/dev/null || iptables -t mangle -A FORWARD -j $CHAIN
iptables -t mangle -C OUTPUT -j $CHAIN 2>/dev/null || iptables -t mangle -A OUTPUT -j $CHAIN
exit 0
NICSH
    chmod +x "$NIC_SH"

    cat > "/etc/systemd/system/${SVC_NAME}.service" << SVC
[Unit]
Description=WLTY v4.1 Hy2 QUIC/UDP Network Guard
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$NIC_SH
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
    systemctl enable "$SVC_NAME" >/dev/null 2>&1
    systemctl restart "$SVC_NAME" >/dev/null 2>&1
    echo -e "  ${G}✓ 网卡硬件层守护服务已启用${P}"

    echo -e "* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576" > "$LIMITS_FILE"
    mkdir -p /etc/systemd/system.conf.d
    echo -e "[Manager]\nDefaultLimitNOFILE=1048576" > "$SYS_CONF"
    systemctl daemon-reexec 2>/dev/null
    UNITS=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'sing-box|xray|hysteria|hy2' | sort -u)
    for u in $UNITS; do
        mkdir -p "/etc/systemd/system/$u.d"
        cat > "/etc/systemd/system/$u.d/99-wlty-protect.conf" << PROTECT
[Service]
Nice=-5
OOMScoreAdjust=-300
LimitNOFILE=1048576
PROTECT
    done
    systemctl daemon-reload
    for pid in $(pgrep -x sing-box; pgrep -x hysteria; pgrep -x hysteria-server; pgrep -x xray); do
        prlimit --pid "$pid" --nofile=1048576:1048576 2>/dev/null
        renice -n -5 -p "$pid" >/dev/null 2>&1
        echo -300 > "/proc/$pid/oom_score_adj" 2>/dev/null
    done
    echo -e "  ${G}✓ 代理进程热保护已应用 (未重启)${P}"

    collect_metrics
    local A_V=("${RM}B" "qlen${QL}/bl${BL}" "${CT_CUR}/${CT_MAX}" "${UTO}/${USTO}s" "${RING_CUR:-?}" "${TXUDP_SEG:-?}" "$MSS_S" "nf${P_NF}/ni${P_NI}/oom${P_OOM}" "${CC}/${QD}")

    echo -e "\n${C}  ── 调优结果对比 ──${P}"
    t_head "项目" "调优前" "调优后"
    local i m col okn=0
    for i in 0 1 2 3 4 5 6 7 8; do
        case $i in
            0) [[ $RM -ge $T_BUF ]] && m="✓" || m="✗" ;;
            1) [[ $BL -ge $T_BACKLOG ]] && m="✓" || m="✗" ;;
            2) [[ $CT_MAX -ge $T_CT ]] && m="✓" || m="✗" ;;
            3) [[ $UTO -eq 30 && $USTO -eq 120 ]] && m="✓" || m="✗" ;;
            4) if (( ${RING_CUR:-0} >= T_RING )); then m="✓"; elif (( ${RING_CUR:-0} > 0 )); then m="△驱动上限"; else m="✗"; fi ;;
            5) [[ $TXUDP_SEG == "on" ]] && m="✓" || m="△驱动不支持" ;;
            6) [[ $MSS_S == "已开启" ]] && m="✓" || m="✗" ;;
            7) [[ -n $MAIN_PID && $P_NF == 1048576 ]] && m="✓" || m="✗" ;;
            8) [[ $CC == bbr* && $QD == fq ]] && m="✓" || m="✗" ;;
        esac
        case $m in ✓*) col=$G;; ✗*) col=$R;; *) col=$Y;; esac
        [[ "$m" == "✓" ]] && okn=$((okn+1))
        t_row "${B_L[$i]}" "${B_V[$i]}" "${A_V[$i]}" "${col}${m}${P}"
    done
    local okcol=$G; (( okn < 9 )) && okcol=$Y
    echo -e "  ${D}──────────────────────────────────────────────────────────${P}"
    echo -e "  验收: ${okcol}${okn}/9 项达标${P}"
    echo -e "  ${Y}※ 建议: 返回面板输入 0/3, 运行 Hy2 隧道实测与回程检测验证效果${P}"
}

wan_rtt() {
    local out line mi av ma jt s t=0 n=0 i
    out=$(LC_ALL=C ping -c 5 -i 0.2 -W 1 -q 1.1.1.1 2>/dev/null)
    line=$(echo "$out" | grep -oE '= [0-9.]+/[0-9.]+/[0-9.]+/[0-9.]+ ms' | head -n1)
    if [[ -n "$line" ]]; then
        line="${line#= }"; line="${line% ms}"
        IFS='/' read -r mi av ma jt <<< "$line"
        echo "1.1.1.1: ${mi}/${av}/${ma} ms (最小/平均/最大 · 抖动 ${jt} ms)"
        return
    fi
    for i in 1 2 3; do
        s=$(curl -s -o /dev/null -w '%{time_connect}' --max-time 3 --noproxy '*' https://1.1.1.1 2>/dev/null)
        [[ -n "$s" ]] && { t=$(awk -v a="$t" -v b="$s" 'BEGIN{print a+b}'); n=$((n+1)); }
    done
    if (( n > 0 )); then
        t=$(awk -v t="$t" -v n="$n" 'BEGIN{printf "%.0f", t/n*1000}')
        echo "ICMP 不通, 改用 TCP 握手: ${t} ms (1.1.1.1:443)"
    else
        echo "不可达 (ICMP/TCP 均超时)"
    fi
}
health_test() {
    check_deps
    collect_metrics
    h1 "UDP 健康度 (内核累计计数)"
    kv "UDP收/发包" "收 ${UDP_IN} / 发 ${UDP_OUT} · NoPorts ${UDP_NP} (启动以来累计)"
    kv "缓冲溢出" "接收 ${UDP_RCV_ERR} / 发送 ${UDP_SND_ERR} (0 为健康)"
    kv "conntrack" "${CT_CUR}/${CT_MAX} (${CT_PCT}%) · UDP 超时 ${UTO}/${USTO}s"
    kv "软中断NET_RX" "$(awk '/NET_RX:/{for(i=2;i<=NF;i++) printf "CPU%d:%s ", i-2, $i}' /proc/softirqs 2>/dev/null | sed 's/ *$//')"
    kv "公网RTT" "$(wan_rtt)"
    if command -v curl &>/dev/null; then
        local ref refm
        ref=$(curl -4 -s --noproxy '*' -w '%{speed_download}' -o /dev/null --max-time 8 "https://speed.cloudflare.com/__down?bytes=25000000" 2>/dev/null || echo 0)
        refm=$(awk -v s="${ref:-0}" 'BEGIN{printf "%.1f Mbps", s*8/1e6}')
        kv "出站TCP参考" "${refm} (TCP 指标, 仅参考带宽, 不代表 Hy2/UDP)"
    fi
    note "UDP 真实吞吐请以「Hy2 隧道实测」为准"
}

route_test() {
    check_deps
    [[ -z "${NIC:-}" ]] && scan_system
    h1 "回程路由检测 (VPS → 国内节点, 看是否绕路)"
    if ! command -v traceroute &>/dev/null && ! command -v ping &>/dev/null && ! command -v mtr &>/dev/null; then
        warn "缺少 traceroute/ping/mtr, 无法检测"; return
    fi
    local mode="强制穿透代理探测 (ICMP → TCP → UDP)"
    kv "检测方式" "$mode"
    kv "国家识别" "ipwho.is (HTTPS 加密, 中文输出)"
    local SRC_CNTRY; SRC_CNTRY=$(geo_self)
    kv "本机所在国" "${SRC_CNTRY}"
    local i tgt chain mid rtt_sum rtt_n prev_rtt backtrack n h ip rtt g c avg verdict col a b c2 d s
    local last_c=""
    local -a SUM
    for i in "${!RT_IPS[@]}"; do
        tgt="${RT_IPS[$i]}"
        echo -e "\n  ${Y}▶ ${RT_NAMES[$i]} (${tgt})${P}"
        trace_hops "$tgt"
        n=${#HOP_IPS[@]}
        if (( n == 0 )); then
            echo -e "    目标不可达或全链路超时"
            SUM+=("${RT_NAMES[$i]}|不可见|- ms|无法判定")
            continue
        fi

        # 检测是否被本地代理拦截 (第一跳直接是目标IP)
        if [[ "${HOP_IPS[0]}" == "$tgt" ]]; then
            if has_tun; then
                echo -e "    ${R}警告: 第一跳即目标, 疑似被本地代理(TUN)拦截!${P}"
                echo -e "    ${Y}提示: 请尝试临时关闭 sing-box 的 TUN 模式后再测。${P}"
                SUM+=("${RT_NAMES[$i]}|疑似TUN拦截|- ms|无效数据")
            else
                echo -e "    ${Y}注意: 中间节点不回应 TTL 超时 (仅目标应答), 常见于骨干网对 ICMP 限速, 非绕路证据${P}"
                local hr="${HOP_RTTS[0]}"
                [[ "$hr" == "*" ]] && hr="-"
                SUM+=("${RT_NAMES[$i]}|直连可达(中间隐藏)|${hr} ms|无法判定")
            fi
            continue
        fi

        chain=""; mid=0; rtt_sum=0; rtt_n=0; prev_rtt=-1; backtrack=0; last_c=""
        for ((h=0; h<n; h++)); do
            ip="${HOP_IPS[$h]}"; rtt="${HOP_RTTS[$h]}"
            if is_private_ip "$ip"; then g="内网"; c="内网"; else g=$(geo "$ip"); c="${g%%|*}"; fi
            [[ "$rtt" != "*" ]] && { rtt_sum=$(awk -v a="$rtt_sum" -v b="$rtt" 'BEGIN{printf "%.1f", a+b}'); rtt_n=$((rtt_n+1)); }
            if [[ "$rtt" != "*" && "$prev_rtt" != "-1" ]]; then
                awk -v p="$prev_rtt" -v r="$rtt" 'BEGIN{ exit (r < p/2 && p > 80) ? 0 : 1 }' && backtrack=1
            fi
            [[ "$rtt" != "*" ]] && prev_rtt="$rtt"
            if [[ "$c" != "$last_c" && "$c" != "内网" && "$c" != "?" ]]; then
                chain="${chain}${c} → "; last_c="$c"
                [[ "$c" != "$SRC_CNTRY" && "$c" != "中国" ]] && mid=$((mid+1))
            fi
            printf '    %2d   %-15s   %7s ms   %s%s\n' "$((h+1))" "$ip" "$rtt" "$g" "$(pad "$g" 18)"
        done
        chain="${chain% → }"; [[ -z "$chain" ]] && chain="不可见"
        avg="-"
        (( rtt_n > 0 )) && avg=$(awk -v s="$rtt_sum" -v n="$rtt_n" 'BEGIN{printf "%.0f", s/n}')
        verdict="正常"
        (( mid >= 3 )) && verdict="疑似绕路(途经${mid}个中转国家)"
        (( backtrack == 1 )) && verdict="疑似绕路(RTT异常回退)"
        col=$G; [[ "$verdict" != "正常" ]] && col=$R
        echo -e "    └ 路径: ${chain} | 平均 ${avg} ms | 判定: ${col}${verdict}${P}"
        SUM+=("${RT_NAMES[$i]}|${chain}|${avg} ms|${verdict}")
    done
    echo -e "\n${C}  ── 回程总览 ──${P}"
    t4_head "目标" "回程国家链" "延迟" "判定"
    for s in "${SUM[@]}"; do
        IFS='|' read -r a b c2 d <<< "$s"
        col=$G; [[ "$d" != "正常" ]] && col=$R
        t4_row "$a" "$b" "$c2" "${col}${d}${P}"
    done
    echo -e "  ${D}──────────────────────────────────────────────────────────────────────${P}"
    note "判定为启发式 (中转国家数量 + RTT 回退), 仅供参考"
}

tunnel_test() {
    check_deps
    h1 "Hy2 (QUIC/UDP) 隧道实测 · 本机回环全栈自测"
    note "临时拉起一对 Hy2 服务端/客户端 (回环链路, 不触碰生产监听端口),"
    note "实测 quic-go 真实协议栈的吞吐、丢包、RTT 抖动与并发 CPU。"

    local HY_BIN SB_BIN engine=""
    HY_BIN=$(command -v hysteria 2>/dev/null)
    [[ -z "$HY_BIN" ]] && HY_BIN=$(command -v hysteria-linux-amd64 2>/dev/null)
    SB_BIN=$(command -v sing-box 2>/dev/null)
    if [[ -z "$SB_BIN" ]]; then
        for p in /usr/local/bin/sing-box /usr/bin/sing-box /opt/sing-box/sing-box; do
            [[ -x "$p" ]] && SB_BIN="$p" && break
        done
    fi
    local exe pid
    for pid in $(pgrep -x sing-box 2>/dev/null | head -n1) $(pgrep -x hysteria 2>/dev/null | head -n1); do
        exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
        [[ -n "$exe" ]] || continue
        [[ "$(basename "$exe")" == "sing-box" && -z "$SB_BIN" ]] && SB_BIN="$exe"
        [[ "$(basename "$exe")" == "hysteria" && -z "$HY_BIN" ]] && HY_BIN="$exe"
    done
    if [[ -n "$HY_BIN" ]] && command -v openssl &>/dev/null; then engine="hysteria"
    elif [[ -n "$SB_BIN" ]]; then engine="sing-box"
    fi
    if [[ -z "$engine" ]]; then
        warn "未找到 hysteria/sing-box 二进制, 无法自建隧道。"; return
    fi
    command -v python3 &>/dev/null || { warn "缺少 python3, 无法启动本地端点, 跳过"; return; }
    command -v curl &>/dev/null || { warn "缺少 curl, 跳过"; return; }

    local TUN_DIR TUN_PORT SOCKS_PORT HTTP_PORT ECHO_PORT PASS SRV_PID CLI_PID HTTP_PID
    if [ -d /dev/shm ]; then
        TUN_DIR=$(mktemp -d /dev/shm/wlty-tun.XXXXXX)
    else
        TUN_DIR=$(mktemp -d /tmp/wlty-tun.XXXXXX)
    fi
    TUN_PORT=$(free_port 39991); SOCKS_PORT=$(free_port 10808)
    HTTP_PORT=$(free_port 18080); ECHO_PORT=$(free_port 19090)
    PASS=$( (date +%s%N; head -c 24 /dev/urandom) | md5sum | cut -c1-16 )
    local TLS_ON="no"
    command -v openssl &>/dev/null && TLS_ON="yes"

    cleanup() {
        [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null
        [[ -n "${CLI_PID:-}" ]] && kill "$CLI_PID" 2>/dev/null
        [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null
        [[ -n "${TUN_DIR:-}" ]] && rm -rf "$TUN_DIR" 2>/dev/null
    }
    trap cleanup EXIT

    if [[ "$TLS_ON" == "yes" ]]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -keyout "$TUN_DIR/key.pem" -out "$TUN_DIR/cert.crt" -days 1 \
            -subj "/CN=localhost" >/dev/null 2>&1
    fi

    if [[ "$engine" == "hysteria" ]]; then
        cat > "$TUN_DIR/server.yaml" << Y1
listen: 127.0.0.1:${TUN_PORT}
tls:
  cert: ${TUN_DIR}/cert.crt
  key: ${TUN_DIR}/key.pem
auth:
  type: password
  password: ${PASS}
quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 33554432
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 67108864
ignoreClientBandwidth: true
Y1
        cat > "$TUN_DIR/client.yaml" << Y2
server: 127.0.0.1:${TUN_PORT}
auth: ${PASS}
tls:
  sni: localhost
  insecure: true
bandwidth:
  up: 10 gbps
  down: 10 gbps
socks5:
  listen: 127.0.0.1:${SOCKS_PORT}
Y2
    else
        cat > "$TUN_DIR/server.json" << J1
{
  "log": {"level": "error"},
  "inbounds": [{
    "type": "hysteria2",
    "listen": "127.0.0.1",
    "listen_port": ${TUN_PORT},
    "users": [{"password": "${PASS}"}],
    "ignore_client_bandwidth": true,
    "up_mbps": 10000,
    "down_mbps": 10000,
    "tls": {"enabled": true, "certificate_path": "${TUN_DIR}/cert.crt", "key_path": "${TUN_DIR}/key.pem"}
  }]
}
J1
        cat > "$TUN_DIR/client.json" << J2
{
  "log": {"level": "error"},
  "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": ${SOCKS_PORT}}],
  "outbounds": [{
    "type": "hysteria2",
    "server": "127.0.0.1",
    "server_port": ${TUN_PORT},
    "password": "${PASS}",
    "up_mbps": 10000,
    "down_mbps": 10000,
    "tls": {"enabled": true, "insecure": true, "server_name": "localhost"}
  }]
}
J2
    fi

    kv "隧道引擎" "$engine"
    if [[ "$engine" == "hysteria" ]]; then
        "$HY_BIN" server -c "$TUN_DIR/server.yaml" >"$TUN_DIR/srv.log" 2>&1 & SRV_PID=$!
    else
        "$SB_BIN" run -c "$TUN_DIR/server.json" >"$TUN_DIR/srv.log" 2>&1 & SRV_PID=$!
    fi
    local okup=0 i
    for i in $(seq 1 8); do ss -uln 2>/dev/null | grep -q ":${TUN_PORT} " && { okup=1; break; }; sleep 0.4; done
    (( okup )) || { warn "临时服务端启动失败"; cleanup; return; }

    if [[ "$engine" == "hysteria" ]]; then
        "$HY_BIN" client -c "$TUN_DIR/client.yaml" >"$TUN_DIR/cli.log" 2>&1 & CLI_PID=$!
    else
        "$SB_BIN" run -c "$TUN_DIR/client.json" >"$TUN_DIR/cli.log" 2>&1 & CLI_PID=$!
    fi
    local okp=0
    for i in $(seq 1 8); do ss -tln 2>/dev/null | grep -q ":${SOCKS_PORT} " && { okp=1; break; }; sleep 0.4; done
    (( okp )) || { warn "临时客户端启动失败"; cleanup; return; }

    # 3GB 稀疏文件: 只占 1MB 磁盘, 保证 10s/15s 窗口测试不会提前传完
    dd if=/dev/zero of="$TUN_DIR/data.bin" bs=1M count=1 seek=3000 2>/dev/null
    head -c 1024 /dev/zero > "$TUN_DIR/small.bin"
    ( cd "$TUN_DIR" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) & HTTP_PID=$!
    sleep 1
    ss -tln 2>/dev/null | grep -q ":${HTTP_PORT} " || { warn "本地 HTTP 源启动失败"; cleanup; return; }

    local SP SP_M c1 c2 CP1 TOT CP2 SW SWM ST WIN1 WIN2 WIN3
    local SAVG=0 SMIN=0 SMAX=0 SFL=0 umbps=0 uloss="-" rmin="-" rav="-" rmax="-" rjit="-"

    echo -e "\n  ${Y}▶ ① 隧道 TCP 单流吞吐 (10s)${P}"
    c1=$(cpu_snap)
    SP=$(curl -s --noproxy '*' --socks5-hostname "127.0.0.1:$SOCKS_PORT" -o /dev/null \
        -w '%{speed_download}' --max-time 10 "http://127.0.0.1:$HTTP_PORT/data.bin" 2>/dev/null || echo 0)
    c2=$(cpu_snap)
    SP_M=$(awk -v s="${SP:-0}" 'BEGIN{printf "%.1f", s*8/1e6}')
    CP1=$(pct_busy "${c1%% *}" "${c1##* }" "${c2%% *}" "${c2##* }")
    kv "隧道TCP吞吐" "${G}${SP_M} Mbps${P} (期间 CPU 占用 ${CP1}%)"

    echo -e "\n  ${Y}▶ ② 高并发 8 流吞吐与 CPU (8s)${P}"
    rm -f "$TUN_DIR"/spd.*
    c1=$(cpu_snap)
    local pids=()
    for i in $(seq 1 8); do
        ( timeout 12 curl -s --connect-timeout 3 --max-time 8 --noproxy '*' --socks5-hostname "127.0.0.1:$SOCKS_PORT" -o /dev/null \
            -w '%{speed_download}' "http://127.0.0.1:$HTTP_PORT/data.bin" \
            > "$TUN_DIR/spd.$i" 2>/dev/null ) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    c2=$(cpu_snap)
    TOT=$(awk '{s+=$1} END{printf "%.1f", s*8/1e6}' "$TUN_DIR"/spd.* 2>/dev/null)
    CP2=$(pct_busy "${c1%% *}" "${c1##* }" "${c2%% *}" "${c2##* }")
    kv "并发8流吞吐" "${G}${TOT} Mbps${P} (期间 CPU 占用 ${CP2}%)"

    echo -e "\n  ${Y}▶ ③ 持续传输稳定性 (3 × 15s 窗口)${P}"
    for i in 1 2 3; do
        SW=$(curl -s --noproxy '*' --socks5-hostname "127.0.0.1:$SOCKS_PORT" -o /dev/null \
            -w '%{speed_download}' --max-time 15 "http://127.0.0.1:$HTTP_PORT/data.bin" 2>/dev/null || echo 0)
        SWM=$(awk -v s="${SW:-0}" 'BEGIN{printf "%.1f", s*8/1e6}')
        case $i in 1) WIN1=$SWM;; 2) WIN2=$SWM;; 3) WIN3=$SWM;; esac
        echo -e "    · 窗口 $i: ${G}${SWM} Mbps${P}"
    done
    ST=$(awk -v a="${WIN1:-0}" -v b="${WIN2:-0}" -v c="${WIN3:-0}" 'BEGIN{mn=a; if(b<mn)mn=b; if(c<mn)mn=c; mx=a; if(b>mx)mx=b; if(c>mx)mx=c; avg=(a+b+c)/3; printf "%.1f %.1f %.1f %.0f", mn, avg, mx, (avg>0 ? (mx-mn)/avg*100 : 0)}')
    read -r SMIN SAVG SMAX SFL <<< "$ST"
    kv "持续稳定性" "均值 ${SAVG} Mbps · 窗口 ${SMIN}~${SMAX} Mbps · 波动 ${SFL}%"

    echo -e "\n  ${Y}▶ ④ 隧道 RTT 与抖动 (10 次小请求)${P}"
    : > "$TUN_DIR/rtts"
    for i in $(seq 1 10); do
        SW=$(curl -s --noproxy '*' --socks5-hostname "127.0.0.1:$SOCKS_PORT" -o /dev/null \
            -w '%{time_total}' --max-time 3 "http://127.0.0.1:$HTTP_PORT/small.bin" 2>/dev/null)
        [[ -n "$SW" ]] && echo "$SW" >> "$TUN_DIR/rtts"
        sleep 0.1
    done
    if [[ -s "$TUN_DIR/rtts" ]]; then
        SW=$(awk '{ if(NR==1){mn=$1; mx=$1; s=$1} else { if($1<mn)mn=$1; if($1>mx)mx=$1; s+=$1 } } END{ printf "%.2f %.2f %.2f %.2f", mn*1000, s/NR*1000, mx*1000, (mx-mn)*1000 }' "$TUN_DIR/rtts")
        read -r rmin rav rmax rjit <<< "$SW"
        kv "隧道RTT" "${rmin} / ${rav} / ${rmax} ms (最小/平均/最大 · 抖动 ${rjit} ms)"
    fi

    echo -e "\n  ${Y}▶ ⑤ 隧道 UDP 吞吐与丢包 (6s, SOCKS5-UDP 透传)${P}"
    cat > "$TUN_DIR/udp_socks.py" << 'PYEOF'
#!/usr/bin/env python3
import socket, struct, sys, threading, time

def main():
    echo_port = int(sys.argv[1]); socks_port = int(sys.argv[2])
    dur = float(sys.argv[3]) if len(sys.argv) > 3 else 6.0
    pkt = 1200
    stop = False
    recv = [0]
    def echo_server():
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", echo_port)); s.settimeout(0.2)
        try:
            while not stop:
                try:
                    d, a = s.recvfrom(65535); s.sendto(d, a)
                except socket.timeout: pass
                except OSError: break
        finally: s.close()
    threading.Thread(target=echo_server, daemon=True).start()
    try:
        ctrl = socket.create_connection(("127.0.0.1", socks_port), timeout=5)
        ctrl.settimeout(5)
        ctrl.sendall(b"\x05\x01\x00")
        r = ctrl.recv(2)
        if r != b"\x05\x00":
            print("FAIL socks-auth"); return 2
        ctrl.sendall(b"\x05\x03\x00\x01" + socket.inet_aton("0.0.0.0") + struct.pack("!H", 0))
        r = ctrl.recv(10)
        if len(r) < 10 or r[0] != 5 or r[1] != 0:
            print("FAIL udp-associate"); return 2
        atyp = r[3]
        if atyp == 1:
            relay = (socket.inet_ntoa(r[4:8]), struct.unpack("!H", r[8:10])[0])
        elif atyp == 3:
            ln = r[4]
            relay = (r[5:5+ln].decode(), struct.unpack("!H", r[5+ln:7+ln])[0])
        else:
            print("FAIL relay-atyp"); return 2
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.settimeout(0.05)
        for opt in (socket.SOL_SOCKET,):
            try:
                udp.setsockopt(opt, socket.SO_RCVBUF, 8*1024*1024)
                udp.setsockopt(opt, socket.SO_SNDBUF, 8*1024*1024)
            except OSError: pass
        hdr = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", echo_port)
        payload = bytes(pkt)
        def receiver():
            while not stop:
                try:
                    data, _ = udp.recvfrom(65535)
                    if len(data) >= 10 and data[2] == 0: recv[0] += 1
                except socket.timeout: pass
                except OSError: break
        threading.Thread(target=receiver, daemon=True).start()
        sent = 0
        t0 = time.time(); end = t0 + dur
        while time.time() < end:
            for _ in range(20):
                try:
                    udp.sendto(hdr + payload, relay); sent += 1
                except OSError as e:
                    if e.errno in (11, 55, 10035, 10055): time.sleep(0.002)
                    else: end = time.time(); break
            if sent % 400 == 0: time.sleep(0.001)
        time.sleep(0.3)
        stop = True
        try:
            udp.settimeout(0.1)
            for _ in range(50):
                data, _ = udp.recvfrom(65535)
                if len(data) >= 10 and data[2] == 0: recv[0] += 1
        except Exception: pass
        dt = max(time.time() - t0, 0.001)
        loss = 100.0 * max(sent - recv[0], 0) / sent if sent else 0.0
        mbps = recv[0] * pkt * 8 / 1e6 / dt
        print("OK sent=%d recv=%d loss=%.2f%% mbps=%.1f" % (sent, recv[0], loss, mbps))
        ctrl.close(); udp.close()
        return 0
    except Exception as e:
        print("FAIL %s" % e)
        return 2
    finally: stop = True

if __name__ == "__main__":
    sys.exit(main())
PYEOF
    SW=$(python3 "$TUN_DIR/udp_socks.py" "$ECHO_PORT" "$SOCKS_PORT" 6 2>/dev/null)
    if [[ "$SW" == OK* ]]; then
        local usent urecv
        usent=$(echo "$SW" | grep -oE 'sent=[0-9]+' | cut -d= -f2)
        urecv=$(echo "$SW" | grep -oE 'recv=[0-9]+' | cut -d= -f2)
        uloss=$(echo "$SW" | grep -oE 'loss=[0-9.]+%' | cut -d= -f2)
        umbps=$(echo "$SW" | grep -oE 'mbps=[0-9.]+' | cut -d= -f2)
        kv "隧道UDP吞吐" "${G}${umbps} Mbps${P} | 发送 ${usent} / 接收 ${urecv} | 丢包 ${uloss}"
    else
        warn "隧道 UDP 测试失败 (客户端 SOCKS5 不支持 UDP 时可忽略)"
    fi

    echo -e "\n${C}  ── Hy2 实测结论 ──${P}"
    kv "隧道引擎" "$engine"
    kv "TCP单流" "${SP_M} Mbps (CPU ${CP1}%)"
    kv "TCP并发8流" "${TOT} Mbps (CPU ${CP2}%)"
    kv "持续稳定性" "均值 ${SAVG} Mbps · 波动 ${SFL}%"
    kv "UDP隧道" "${umbps} Mbps · 丢包 ${uloss}"
    kv "隧道RTT" "${rmin}/${rav}/${rmax} ms"

    local verdict
    verdict=$(awk -v s="${SP_M:-0}" 'BEGIN{ if (s>=800) print "处理能力充足 (≥800 Mbps), 基本不构成瓶颈"; else if (s>=300) print "中等 (300~800 Mbps), 千兆宽带下或接近瓶颈"; else print "偏低 (<300 Mbps), 高带宽场景建议升级 CPU"; }')
    kv "瓶颈评估" "${Y}${verdict}${P}"
    note "回环链路实测的是本机 Hy2 协议栈处理上限; 公网隧道真实吞吐还受链路与客户端影响。"

    cleanup
    trap - EXIT
}

remove_all() {
    scan_system
    h1 "一键删除 WLTY 并复位全部配置"
    echo -e "${Y}>>> 正在清除 WLTY 与旧版 YH 的全部配置...${P}"

    systemctl disable --now "$SVC_NAME" 2>/dev/null
    systemctl disable --now yh2-network-tuning 2>/dev/null
    rm -f "/etc/systemd/system/${SVC_NAME}.service" /etc/systemd/system/yh2-network-tuning.service \
          "$NIC_SH" /usr/local/bin/yh /usr/local/bin/yh2-nic-tuning.sh \
          "$SYSCTL_FILE" /etc/sysctl.d/99-yh2.conf \
          "$LIMITS_FILE" /etc/security/limits.d/99-yh2-nofiles.conf \
          "$SYS_CONF" /etc/systemd/system.conf.d/99-yh2-nofiles.conf "$MOD_FILE"
    for d in /etc/systemd/system/*.service.d/99-wlty-protect.conf /etc/systemd/system/*.service.d/99-yh2-protect.conf; do
        rm -f "$d" 2>/dev/null
    done
    systemctl daemon-reload
    systemctl daemon-reexec 2>/dev/null

    for ch in $CHAIN YH2_TCPMSS; do
        iptables -t mangle -D FORWARD -j "$ch" 2>/dev/null
        iptables -t mangle -D OUTPUT -j "$ch" 2>/dev/null
        iptables -t mangle -F "$ch" 2>/dev/null
        iptables -t mangle -X "$ch" 2>/dev/null
    done

    sysctl --system >/dev/null 2>&1
    restore_state

    for f in /sys/class/net/$NIC/queues/rx-*/rps_cpus; do echo 0 > "$f" 2>/dev/null; done
    for f in /sys/class/net/$NIC/queues/rx-*/rps_flow_cnt; do echo 0 > "$f" 2>/dev/null; done
    echo 0 > /sys/class/net/$NIC/napi_defer_hard_irqs 2>/dev/null
    echo 0 > /sys/class/net/$NIC/gro_flush_timeout 2>/dev/null

    systemctl enable --now irqbalance >/dev/null 2>&1 || true

    for pid in $(pgrep -x sing-box; pgrep -x hysteria; pgrep -x hysteria-server; pgrep -x xray); do
        renice -n 0 -p "$pid" >/dev/null 2>&1
        echo 0 > "/proc/$pid/oom_score_adj" 2>/dev/null
    done

    pkill -f '/tmp/wlty-tun\.' 2>/dev/null || true
    pkill -f '/dev/shm/wlty-tun\.' 2>/dev/null || true
    rm -rf /tmp/wlty-tun.* /dev/shm/wlty-tun.* "$STATE_FILE" 2>/dev/null
    rm -f /usr/local/bin/wlty

    echo -e "${G}✔ 已删除 wlty 及全部优化配置, 运行值已复位到调优前 (代理进程未重启)。${P}"
    echo -e "${Y}  重启系统后内核将 100% 恢复发行版默认状态。${P}"
    exit 0
}

usage() {
    echo -e "${C}WLTY v4.1 — Hy2 (QUIC/UDP) 网络调优引擎${P}"
    echo -e "  ${G}sudo wlty${P}           交互控制面板 (推荐)"
    echo -e "  ${G}wlty 0|test${P}        网络体检 (UDP健康 + Hy2隧道实测)"
    echo -e "  ${G}wlty 3|route${P}       回程路由检测 (看是否绕路)"
    echo -e "  ${G}wlty tunnel${P}       仅 Hy2 隧道实测"
    echo -e "  ${G}wlty 1|apply${P}      执行科学调优 (零中断热更新)"
    echo -e "  ${G}wlty 2|remove${P}     一键删除脚本并复位全部配置"
    exit 0
}

if [[ -z "${1:-}" ]]; then
    if [[ -t 0 ]]; then
        while true; do
            panel
            echo -e -n "  ${G}请输入选项 [0/1/2/3/4] (默认 0): ${P}"
            read -r choice
            case "${choice:-0}" in
                0) health_test; tunnel_test; press_any ;;
                1) apply_tuning; press_any ;;
                2) remove_all ;;
                3) route_test; press_any ;;
                4|q|Q) echo -e "${G}  再见!${P}"; exit 0 ;;
                *) ;;
            esac
        done
    else
        echo -e "${R}非交互模式请显式指定参数 (wlty 0/1/2/3), 或 wlty help${P}"
        usage
    fi
fi

case "$1" in
    0|test|check) scan_system; collect_metrics; health_test; tunnel_test ;;
    3|route|rt)   scan_system; collect_metrics; route_test ;;
    tunnel|tt)    scan_system; tunnel_test ;;
    health|hl)    scan_system; collect_metrics; health_test ;;
    1|apply|tune) apply_tuning ;;
    2|remove|uninstall|clean) remove_all ;;
    help|-h|--help) usage ;;
    *) usage ;;
esac
