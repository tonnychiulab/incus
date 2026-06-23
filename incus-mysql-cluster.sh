#!/usr/bin/env bash
# incus-mysql-cluster.sh — Phase A
# 以宣告式 cluster.yaml 佈建 1 master + N read slave 的 MySQL GTID 主從複製（Incus 容器）。
# 指令: apply / status / destroy。密碼走 cluster.secrets(0600) 或環境變數。
# 註: ProxySQL 讀寫分流與 --json 事件輸出於下一增量加入（見檔尾 TODO）。

set -euo pipefail

# ---------- 顏色（僅終端機啟用，寫入 log 時去除跳脫碼） ----------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_INFO=$'\033[0;36m'; C_OK=$'\033[0;32m'
    C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_BOLD=$'\033[1m'
else
    C_RESET=''; C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_BOLD=''
fi

LOGFILE="${CLUSTER_LOG:-$HOME/incus-mysql-cluster.log}"
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOGFILE")) 2>&1

log()        { printf '%b[%s] %s%b\n' "$C_INFO" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" "$C_RESET"; }
ok()         { printf '%b[%s] %s%b\n' "$C_OK"   "$(date +'%Y-%m-%d %H:%M:%S')" "$*" "$C_RESET"; }
warn()       { printf '%b[%s] %s%b\n' "$C_WARN" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" "$C_RESET" >&2; }
error_exit() { printf '%b錯誤: %s%b\n' "$C_ERR" "$*" "$C_RESET" >&2; exit 1; }
phase()      { printf '%b\n========== %s ==========%b\n' "$C_BOLD$C_INFO" "$*" "$C_RESET"; }
incus_exec() { incus exec "$1" -- "${@:2}"; }

CONFIG="${CLUSTER_CONFIG:-cluster.yaml}"
SECRETS="${CLUSTER_SECRETS:-cluster.secrets}"

NAME_PATTERN='^[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'

# ==================== 相依檢查 ====================
require_tools() {
    command -v incus &>/dev/null || error_exit "找不到 incus，請先安裝 Incus。"
    command -v yq &>/dev/null   || error_exit "找不到 yq（YAML 解析），請先安裝：見 README 或 https://github.com/mikefarah/yq"
}

# ==================== 設定載入 ====================
cfg() { yq "$1" "$CONFIG"; }

load_config() {
    [[ -f "$CONFIG" ]] || error_exit "找不到設定檔 $CONFIG。"
    IMAGE=$(cfg '.cluster.image')
    DB_NAME=$(cfg '.cluster.database')
    NETWORK_CFG=$(cfg '.cluster.network')
    MASTER_NAME=$(cfg '.master.name')
    MASTER_IP_CFG=$(cfg '.master.ip')
    REPL_USER=$(cfg '.credentials.repl_user')
    PROXY_ENABLED=$(cfg '.proxy.enabled')

    [[ "$MASTER_NAME" =~ $NAME_PATTERN ]] || error_exit "master 名稱不合法: $MASTER_NAME"
    [[ "$REPL_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_]{0,31}$ ]] || error_exit "複製使用者名稱不合法: $REPL_USER"

    SLAVE_NAMES=(); SLAVE_IPS_CFG=(); SLAVE_ROLES=()
    local count i n ip r
    count=$(cfg '.slaves | length')
    (( count >= 1 )) || error_exit "設定檔至少需要 1 台 slave。"
    for (( i=0; i<count; i++ )); do
        n=$(cfg ".slaves[$i].name"); ip=$(cfg ".slaves[$i].ip"); r=$(cfg ".slaves[$i].role")
        [[ "$n" =~ $NAME_PATTERN ]] || error_exit "slave[$i] 名稱不合法: $n"
        [[ "$r" == "read" ]] || error_exit "slave $n 角色 '$r' 尚未實作（本階段僅支援 read）。"
        [[ "$n" == "$MASTER_NAME" ]] && error_exit "slave 名稱不可與 master 相同: $n"
        SLAVE_NAMES+=("$n"); SLAVE_IPS_CFG+=("$ip"); SLAVE_ROLES+=("$r")
    done
    # 重複名稱檢查
    local all=("$MASTER_NAME" "${SLAVE_NAMES[@]}") uniq
    uniq=$(printf '%s\n' "${all[@]}" | sort | uniq -d)
    [[ -z "$uniq" ]] || error_exit "節點名稱重複: $uniq"
}

# ==================== Secret 管理 ====================
declare -A SECRET_FILE_VALS
declare -A NEW_SECRETS

gen_password() {
    local p
    p=$(openssl rand -base64 18 2>/dev/null | tr -d '/+=' ) || true
    [[ -z "$p" ]] && p=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
    printf '%sAa1!' "$p"   # 附加保證大小寫/數字/特殊符號，符合 validate_password 政策
}

load_secret_file() {
    [[ -f "$SECRETS" ]] || return 0
    local perms
    perms=$(stat -c '%a' "$SECRETS" 2>/dev/null || stat -f '%Lp' "$SECRETS")
    [[ "${perms: -2}" == "00" ]] || error_exit "secrets 檔權限過鬆 ($perms)，請執行: chmod 600 $SECRETS"
    local k v
    while IFS='=' read -r k v; do
        [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        SECRET_FILE_VALS["$k"]="$v"
    done < "$SECRETS"
}

# ensure_secret KEY  — 取值優先序: 真實環境變數 > secrets 檔 > 自動產生
ensure_secret() {
    local key=$1 cur
    cur="${!key:-}"
    [[ -z "$cur" ]] && cur="${SECRET_FILE_VALS[$key]:-}"
    if [[ -z "$cur" ]]; then
        cur=$(gen_password)
        NEW_SECRETS["$key"]="$cur"
        log "secret $key 未提供，已自動產生強隨機值。"
    fi
    printf -v "$key" '%s' "$cur"
    export "$key"
}

persist_secrets() {
    (( ${#NEW_SECRETS[@]} == 0 )) && return 0
    local k
    ( umask 077; for k in "${!NEW_SECRETS[@]}"; do printf '%s=%s\n' "$k" "${NEW_SECRETS[$k]}"; done >> "$SECRETS" )
    chmod 600 "$SECRETS"
    ok "已將自動產生的 secret 寫入 $SECRETS (0600)。"
}

load_secrets() {
    load_secret_file
    ensure_secret MYSQL_ROOT_PASSWORD
    ensure_secret REPL_PASSWORD
    persist_secrets
}

# ==================== 網路 / IP / server-id ====================
resolve_network() {
    if [[ -z "$NETWORK_CFG" || "$NETWORK_CFG" == "auto" || "$NETWORK_CFG" == "null" ]]; then
        NETWORK=$(incus network list --format csv | tail -n +2 | awk -F, '$5 != "" {print $1; exit}')
        [[ -z "$NETWORK" ]] && NETWORK="incusbr0"
    else
        NETWORK="$NETWORK_CFG"
    fi
    local addr
    addr=$(incus network get "$NETWORK" ipv4.address 2>/dev/null || true)
    [[ -z "$addr" || "$addr" == "none" ]] && error_exit "網路 $NETWORK 未設定 IPv4 位址。"
    local base cidr
    IFS='/' read -r base cidr <<< "$addr"
    [[ "$cidr" == "24" ]] || error_exit "目前僅支援 /24 子網，偵測到 /$cidr。"
    NET_PREFIX="${base%.*}."
    GATEWAY="$base"
    log "網路 $NETWORK: ${NET_PREFIX}0/24, 閘道 $GATEWAY"
}

declare -A USED_IP
scan_used_ips() {
    local line _ ipv4
    while IFS= read -r line; do
        [[ "$line" == NAME* ]] && continue
        IFS=',' read -r _ _ ipv4 _ <<< "$line"
        ipv4=$(echo "$ipv4" | awk '{print $1}')
        [[ -n "$ipv4" && "$ipv4" != "none" ]] && USED_IP["$ipv4"]=1
    done < <(incus list --format csv)
}

allocate_ip() {
    local i cand
    for i in $(seq 2 254); do
        cand="${NET_PREFIX}$i"
        [[ "$cand" == "$GATEWAY" ]] && continue
        [[ -z "${USED_IP[$cand]:-}" ]] && { echo "$cand"; return 0; }
    done
    return 1
}

# resolve_ip NAME CFG_IP — 回傳實際要用的 IP（auto 則分配）
resolve_ip() {
    local name=$1 want=$2 ip
    # 容器已存在則沿用其現有 IP
    if incus list "$name" --format csv 2>/dev/null | grep -q "^$name,"; then
        ip=$(incus_exec "$name" ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
        [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    fi
    if [[ -z "$want" || "$want" == "auto" || "$want" == "null" ]]; then
        ip=$(allocate_ip) || error_exit "找不到可用 IP 給 $name。"
    else
        ip="$want"
    fi
    USED_IP["$ip"]=1
    echo "$ip"
}

server_id_from_ip() { echo "${1##*.}"; }

# ==================== 佈建函式（沿用已驗證邏輯） ====================
container_diag() {
    local name=$1
    warn "---------- 容器 $name 診斷資訊 ----------"
    incus list "$name" 2>&1 || true
    incus exec "$name" -- cloud-init status 2>&1 || warn "  (cloud-init 無法查詢)"
    incus exec "$name" -- systemctl status mysql --no-pager -l 2>&1 | tail -n 15 || true
    incus exec "$name" -- journalctl -u mysql --no-pager -n 15 2>&1 || true
    warn "----------------------------------------"
}

wait_for_container() {
    local name=$1 ip=$2 timeout=120 interval=3 elapsed=0 state
    log "等待容器 $name 取得 IP $ip (逾時 ${timeout}s)..."
    while ! incus_exec "$name" ip -4 addr show eth0 2>/dev/null | grep -q "inet $ip/"; do
        sleep "$interval"; ((elapsed+=interval))
        if (( elapsed % 15 == 0 )); then
            state=$(incus list "$name" -c s --format csv 2>/dev/null || echo UNKNOWN)
            log "  …等待 $name (狀態=$state, ${elapsed}/${timeout}s)"
        fi
        (( elapsed >= timeout )) && { container_diag "$name"; error_exit "$name 啟動逾時。"; }
    done
    ok "容器 $name 已就緒，IP=$ip。"
}

ensure_container() {
    local name=$1 ip=$2
    if incus list "$name" --format csv | grep -q "^$name,"; then
        log "容器 $name 已存在，套用靜態 IP $ip 並強制重啟…"
        incus config device override "$name" eth0 ipv4.address="$ip" 2>/dev/null \
            || incus config device set "$name" eth0 ipv4.address "$ip"
        incus restart -f "$name"
    else
        log "建立容器 $name（init→設IP→start，首次需下載鏡像）…"
        incus init "$IMAGE" "$name" -c security.nesting=true -c limits.memory=2GB
        incus config device override "$name" eth0 ipv4.address="$ip"
        incus start "$name"
        ok "容器 $name 已建立並啟動。"
    fi
    wait_for_container "$name" "$ip"
}

install_mysql() {
    local container=$1
    log "[$container] 等待 cloud-init 完成（最多 180s）…"
    incus_exec "$container" timeout 180 cloud-init status --wait \
        || warn "[$container] cloud-init 未在時限內完成，仍續裝。"
    log "[$container] 預埋 root 密碼並 apt-get update…"
    incus_exec "$container" bash -c "
        export DEBIAN_FRONTEND=noninteractive
        debconf-set-selections <<< 'mysql-community-server mysql-community-server/root-pass password $MYSQL_ROOT_PASSWORD'
        debconf-set-selections <<< 'mysql-community-server mysql-community-server/re-root-pass password $MYSQL_ROOT_PASSWORD'
        apt-get update -qq
    " || error_exit "[$container] apt-get update 失敗，請檢查容器網路或套件來源。"
    log "[$container] 安裝 mysql-server / mysql-client（數分鐘，以下為 apt 輸出）…"
    incus_exec "$container" bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y mysql-server mysql-client
    " || { container_diag "$container"; error_exit "[$container] MySQL 安裝失敗。"; }
    incus_exec "$container" bash -c "systemctl enable mysql && systemctl start mysql" \
        || { container_diag "$container"; error_exit "[$container] mysql 服務啟動失敗。"; }
    ok "[$container] MySQL 安裝完成。"
}

wait_for_mysql() {
    local container=$1 timeout=60 interval=2 elapsed=0
    log "[$container] 等待 MySQL 接受連線（逾時 ${timeout}s）…"
    while ! incus_exec "$container" mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent &>/dev/null; do
        sleep "$interval"; ((elapsed+=interval))
        (( elapsed % 10 == 0 )) && log "  …$container MySQL 尚未就緒 (${elapsed}/${timeout}s)"
        (( elapsed >= timeout )) && { container_diag "$container"; error_exit "[$container] MySQL 就緒逾時。"; }
    done
    ok "[$container] MySQL 已可連線。"
}

ensure_root_password() {
    local container=$1 timeout=60 interval=2 elapsed=0 resets=0
    log "[$container] 確認 root 密碼（含 socket fallback）…"
    while true; do
        if incus_exec "$container" mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent &>/dev/null; then
            ok "[$container] root 密碼已生效。"; return 0
        fi
        if incus_exec "$container" mysql -uroot <<EOF &>/dev/null
SET SESSION sql_log_bin=0;
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '$MYSQL_ROOT_PASSWORD';
FLUSH PRIVILEGES;
EOF
        then
            resets=$((resets+1))
            (( resets > 3 )) && { container_diag "$container"; error_exit "[$container] 多次重設仍無法以密碼登入。"; }
            log "[$container] 已透過 socket 重設 root 密碼（第 $resets 次），重新驗證…"
            continue
        fi
        (( elapsed % 10 == 0 )) && log "  …等待 $container 可連線/重設 (${elapsed}/${timeout}s)"
        sleep "$interval"; elapsed=$((elapsed+interval))
        (( elapsed >= timeout )) && { container_diag "$container"; error_exit "[$container] root 密碼處理逾時。"; }
    done
}

# configure_mysql NAME ROLE SERVER_ID
configure_mysql() {
    local container=$1 role=$2 server_id=$3
    local cnf=/etc/mysql/mysql.conf.d/zz-replication.cnf
    local config
    config=$(cat <<EOF
[mysqld]
server-id=$server_id
log_bin=mysql-bin
binlog_format=row
gtid_mode=ON
enforce_gtid_consistency=ON
bind-address=0.0.0.0
max_connections=200
EOF
)
    [[ "$role" == "read" ]] && config+=$'\nread_only=ON\nsuper_read_only=ON'
    log "[$container] 寫入複製設定（role=$role, server-id=$server_id）…"
    echo "$config" | incus_exec "$container" bash -c "cat > $cnf"
    incus_exec "$container" systemctl restart mysql
    sleep 3
    wait_for_mysql "$container"
}

setup_repl_user() {
    log "[$MASTER_NAME] 建立複製使用者 $REPL_USER…"
    incus_exec "$MASTER_NAME" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<EOF
CREATE USER IF NOT EXISTS '$REPL_USER'@'%' IDENTIFIED BY '$REPL_PASSWORD';
GRANT REPLICATION SLAVE ON *.* TO '$REPL_USER'@'%';
FLUSH PRIVILEGES;
EOF
    ok "[$MASTER_NAME] 複製使用者完成。"
}

setup_replica() {
    local slave=$1
    log "[$slave] 設定從 $MASTER_NAME (GTID auto-position) 複製…"
    incus_exec "$slave" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<EOF
STOP REPLICA;
RESET REPLICA ALL;
CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='$MASTER_IP',
    SOURCE_USER='$REPL_USER',
    SOURCE_PASSWORD='$REPL_PASSWORD',
    SOURCE_AUTO_POSITION=1,
    GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
EOF
    ok "[$slave] 已啟動複製。"
}

replica_health() {
    local slave=$1 status io sql
    status=$(incus_exec "$slave" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G" 2>/dev/null)
    io=$(echo "$status"  | awk -F': ' '/Replica_IO_Running/{gsub(/ /,"",$2);print $2}')
    sql=$(echo "$status" | awk -F': ' '/Replica_SQL_Running/{gsub(/ /,"",$2);print $2}')
    if [[ "$io" == "Yes" && "$sql" == "Yes" ]]; then
        ok "[$slave] 複製正常 (IO=Yes, SQL=Yes)。"
    else
        warn "[$slave] 複製異常 (IO=$io, SQL=$sql)。"
        echo "$status" | grep -E 'Last_IO_Error|Last_SQL_Error' || true
    fi
}

# ==================== 漂移偵測（孤兒節點） ====================
warn_orphans() {
    local managed=("$MASTER_NAME" "${SLAVE_NAMES[@]}") name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        # 僅檢查疑似本工具命名的 mysql-* 容器，避免誤報無關容器
        [[ "$name" == mysql-* || "$name" == "$MASTER_NAME" ]] || continue
        if ! printf '%s\n' "${managed[@]}" | grep -qx "$name"; then
            warn "孤兒節點: $name 存在於 Incus 但不在 $CONFIG。如需移除請手動 'incus delete -f $name'（apply 不會自動刪）。"
        fi
    done < <(incus list --format csv -c n | tr -d '"')
}

# ==================== 指令 ====================
cmd_apply() {
    require_tools; load_config; load_secrets
    resolve_network; scan_used_ips

    MASTER_IP=$(resolve_ip "$MASTER_NAME" "$MASTER_IP_CFG")
    SLAVE_IPS=()
    local i
    for (( i=0; i<${#SLAVE_NAMES[@]}; i++ )); do
        SLAVE_IPS+=("$(resolve_ip "${SLAVE_NAMES[$i]}" "${SLAVE_IPS_CFG[$i]}")")
    done

    log "叢集規劃: master=$MASTER_NAME($MASTER_IP), slaves=${#SLAVE_NAMES[@]}"
    for (( i=0; i<${#SLAVE_NAMES[@]}; i++ )); do log "  - ${SLAVE_NAMES[$i]} (${SLAVE_IPS[$i]}, ${SLAVE_ROLES[$i]})"; done

    phase "步驟 1/4：建立容器並指派靜態 IP"
    ensure_container "$MASTER_NAME" "$MASTER_IP"
    for (( i=0; i<${#SLAVE_NAMES[@]}; i++ )); do ensure_container "${SLAVE_NAMES[$i]}" "${SLAVE_IPS[$i]}"; done

    phase "步驟 2/4：安裝 MySQL"
    install_mysql "$MASTER_NAME"
    for s in "${SLAVE_NAMES[@]}"; do install_mysql "$s"; done

    phase "步驟 3/4：設定 GTID 複製"
    ensure_root_password "$MASTER_NAME"; configure_mysql "$MASTER_NAME" master "$(server_id_from_ip "$MASTER_IP")"
    for (( i=0; i<${#SLAVE_NAMES[@]}; i++ )); do
        ensure_root_password "${SLAVE_NAMES[$i]}"
        configure_mysql "${SLAVE_NAMES[$i]}" "${SLAVE_ROLES[$i]}" "$(server_id_from_ip "${SLAVE_IPS[$i]}")"
    done
    setup_repl_user
    for s in "${SLAVE_NAMES[@]}"; do setup_replica "$s"; done

    phase "步驟 4/4：驗證"
    sleep 2
    for s in "${SLAVE_NAMES[@]}"; do replica_health "$s"; done
    warn_orphans

    if [[ "$PROXY_ENABLED" == "true" ]]; then
        warn "proxy.enabled=true，但 ProxySQL 於下一增量才實作，本次略過。"
    fi
    ok "叢集 apply 完成。詳細日誌: $LOGFILE"
}

cmd_status() {
    require_tools; load_config; load_secrets
    phase "叢集狀態: master=$MASTER_NAME, slaves=${#SLAVE_NAMES[@]}"
    incus list "$MASTER_NAME" 2>/dev/null || true
    for s in "${SLAVE_NAMES[@]}"; do
        incus list "$s" 2>/dev/null || true
        if incus list "$s" --format csv 2>/dev/null | grep -q "^$s,"; then
            replica_health "$s"
        else
            warn "[$s] 容器不存在。"
        fi
    done
    warn_orphans
}

cmd_destroy() {
    require_tools; load_config
    local all=("$MASTER_NAME" "${SLAVE_NAMES[@]}")
    warn "即將刪除以下容器: ${all[*]}"
    printf '確認刪除？(y/N): '
    read -r ans </dev/tty
    [[ "$ans" =~ ^[Yy]$ ]] || { warn "已取消。"; exit 0; }
    for n in "${all[@]}"; do
        if incus list "$n" --format csv 2>/dev/null | grep -q "^$n,"; then
            incus delete -f "$n" && ok "已刪除 $n。"
        else
            log "$n 不存在，略過。"
        fi
    done
}

usage() {
    cat <<USAGE
用法: $0 <指令>
  apply     依 $CONFIG 建立/校正叢集（冪等，不自動刪節點）
  status    顯示各節點狀態與複製健康
  destroy   刪除設定檔中所有節點（需確認）
  help      顯示此說明

環境變數:
  CLUSTER_CONFIG (預設 cluster.yaml)   CLUSTER_SECRETS (預設 cluster.secrets)
  MYSQL_ROOT_PASSWORD / REPL_PASSWORD  可覆寫 secrets 檔
USAGE
}

# ==================== 入口 ====================
printf '%b=== %s: incus-mysql-cluster (%s) ===%b\n' "$C_BOLD" "$(date)" "${1:-help}" "$C_RESET"
case "${1:-help}" in
    apply)   cmd_apply ;;
    status)  cmd_status ;;
    destroy) cmd_destroy ;;
    help|-h|--help) usage ;;
    *) echo "未知指令: $1" >&2; usage; exit 1 ;;
esac

# ==================== TODO（下一增量） ====================
# - ProxySQL: 佈建 proxysql 容器 + hostgroups(writer=10/reader=20)
#   + mysql_replication_hostgroups(依 read_only 自動分類) + query rules + monitor/app 帳號
#   + secret 鍵 PROXYSQL_MONITOR_PASSWORD / PROXYSQL_ADMIN_PASSWORD / APP_DB_PASSWORD
# - --json: NDJSON 事件輸出 {ts,node,phase,status,msg,lag} 供 Go/Bubble Tea TUI 解析
# - add-slave / remove-slave / promote
