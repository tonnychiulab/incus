#!/usr/bin/env bash
# incus-mysql-replication.sh
# Interactive script to set up MySQL master-slave replication using Incus containers.
# Prompts for container names, database name, and automatically assigns free IPs
# from the default Incus network to avoid IP conflicts.
# Logs all actions to ~/incus-mysql-replication.log for debugging.

set -euo pipefail

# ---------- 參數解析 ----------
DRY_RUN=0
usage() {
    cat <<USAGE
用法: $0 [選項]
  -n, --dry-run   只執行網路偵測、IP 分配與摘要，不建立容器或安裝 MySQL
  -h, --help      顯示此說明並結束
USAGE
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "未知選項: $1" >&2; usage; exit 1 ;;
    esac
done

# ---------- 顏色（僅在終端機啟用，寫入 log 時會去除跳脫碼） ----------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_INFO=$'\033[0;36m'; C_OK=$'\033[0;32m'
    C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_BOLD=$'\033[1m'
else
    C_RESET=''; C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_BOLD=''
fi

LOGFILE="$HOME/incus-mysql-replication.log"
# 終端機顯示彩色，但寫入 log 前先過濾掉 ANSI 跳脫碼
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOGFILE")) 2>&1

printf '%b=== %s: 開始 MySQL 主從複製腳本 ===%b\n' "$C_BOLD" "$(date)" "$C_RESET"
(( DRY_RUN )) && printf '%b[DRY-RUN] 僅做網路偵測、IP 分配與摘要，不會建立容器。%b\n' "$C_WARN" "$C_RESET"

# ---------- 函式 ----------
log()        { printf '%b[%s] %s%b\n' "$C_INFO" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" "$C_RESET"; }
ok()         { printf '%b[%s] %s%b\n' "$C_OK"   "$(date +'%Y-%m-%d %H:%M:%S')" "$*" "$C_RESET"; }
warn()       { printf '%b[%s] %s%b\n' "$C_WARN" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" "$C_RESET" >&2; }
error_exit() { printf '%b錯誤: %s%b\n' "$C_ERR" "$*" "$C_RESET" >&2; exit 1; }
incus_exec() { incus exec "$1" -- "${@:2}"; }

# 帶驗證的互動式輸入：不符合 pattern 就重問。所有提示走 stderr，僅結果走 stdout 供命令替換擷取。
read_validated() {
    local prompt=$1 default=$2 pattern=$3 errmsg=$4 input
    while true; do
        read -rp "$prompt" input </dev/tty
        input=${input:-$default}
        if [[ "$input" =~ $pattern ]]; then
            printf '%s' "$input"
            return 0
        fi
        printf '%b%s%b\n' "$C_WARN" "$errmsg" "$C_RESET" >&2
    done
}

# 檢查密碼是否符合 MySQL validate_password 預設（MEDIUM）政策
validate_password() {
    local pw=$1 label=$2
    if (( ${#pw} < 8 )) || [[ ! "$pw" =~ [A-Z] ]] || [[ ! "$pw" =~ [a-z] ]] \
       || [[ ! "$pw" =~ [0-9] ]] || [[ ! "$pw" =~ [^a-zA-Z0-9] ]]; then
        error_exit "$label 不符合 MySQL validate_password 預設政策（至少 8 碼，需含大寫、小寫、數字與特殊符號）。"
    fi
}

# ---------- 互動式輸入 ----------
NAME_PATTERN='^[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'
NAME_ERR="容器名稱僅能包含字母、數字與連字號，須以字母開頭、不可以連字號結尾，長度 1-63。"
DB_PATTERN='^[a-zA-Z_][a-zA-Z0-9_]{0,63}$'
DB_ERR="資料庫名稱僅能包含字母、數字與底線，須以字母或底線開頭，長度 1-64。"

MASTER_CONTAINER=$(read_validated "請輸入主要容器名稱 (預設: mysql-master): " "mysql-master" "$NAME_PATTERN" "$NAME_ERR")
SLAVE_CONTAINER=$(read_validated "請輸入從容器名稱 (預設: mysql-slave): " "mysql-slave" "$NAME_PATTERN" "$NAME_ERR")
DB_NAME=$(read_validated "請輸入要複製的資料庫名稱 (預設: myappdb): " "myappdb" "$DB_PATTERN" "$DB_ERR")

if [[ "$MASTER_CONTAINER" == "$SLAVE_CONTAINER" ]]; then
    error_exit "主容器與從容器名稱不可相同（皆為 $MASTER_CONTAINER）。"
fi

# 預設密碼（可用環境變數覆寫，避免把密碼寫死在腳本內）
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-MyRo...3!}"
REPL_USER="${REPL_USER:-replicator}"
REPL_PASSWORD="${REPL_PASSWORD:-Repl...3!}"

validate_password "$MYSQL_ROOT_PASSWORD" "root 密碼"
validate_password "$REPL_PASSWORD" "複製使用者密碼"

if [[ ! "$REPL_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_]{0,31}$ ]]; then
    error_exit "複製使用者名稱不合法（僅限字母、數字、底線，以字母或底線開頭，長度 1-32）。"
fi

# 使用 Ubuntu 24.04 cloud image
MYSQL_IMAGE="images:ubuntu/24.04/cloud"

log "使用者輸入:"
log "  主容器名稱: $MASTER_CONTAINER"
log "  從容器名稱: $SLAVE_CONTAINER"
log "  資料庫名稱: $DB_NAME"

# ---------- 檢查 incus ----------
if ! command -v incus &>/dev/null; then
    error_exit "找不到 incus 指令，請先安裝 Incus。"
fi
log "Incus 已找到。"

# ---------- 取得 Incus 預設網路 ----------
DEFAULT_NETWORK=$(incus network list --format csv | tail -n +2 | awk -F, '$5 != "" {print $1; exit}')
if [[ -z "$DEFAULT_NETWORK" ]]; then
    DEFAULT_NETWORK="incusbr0"
    log "未偵測到已設定 ipv4.address 的網路，使用預設網路名稱: $DEFAULT_NETWORK"
else
    log "偵測到網路: $DEFAULT_NETWORK"
fi

NETWORK_ADDR=$(incus network get "$DEFAULT_NETWORK" ipv4.address 2>/dev/null || true)
if [[ -z "$NETWORK_ADDR" || "$NETWORK_ADDR" == "none" ]]; then
    error_exit "網路 $DEFAULT_NETWORK 未設定 IPv4 位址，請先設定或檢查 Incus 網路設定。"
fi
log "網路 $DEFAULT_NETWORK IPv4 位址: $NETWORK_ADDR"

# 解析 base 與 cidr
IFS='/' read -r NET_BASE NET_CIDR <<< "$NETWORK_ADDR"
if [[ "$NET_CIDR" != "24" ]]; then
    error_exit "此腳本目前僅支援 /24 子網（如 10.0.0.0/24）。偵測到的 CIDR 為 $NET_CIDR，請手動調整腳本或使用其他腳本。"
fi
NETWORK_PREFIX="${NET_BASE%.*}."   # e.g. 10.172.106.1 -> 10.172.106.
GATEWAY="$NET_BASE"                # 閘道即網路的 ipv4.address 位址
USABLE_START=2
USABLE_END=254
log "網路位址: ${NETWORK_PREFIX}0/$NET_CIDR, 閘道: $GATEWAY, 可用 IP 範圍: $USABLE_START-$USABLE_END"

# ---------- 取得目前已用 IP ----------
declare -A used_ip_map
while IFS= read -r line; do
    [[ "$line" == NAME* ]] && continue   # 跳過標題
    IFS=',' read -r _ _ ipv4 _ <<< "$line"
    ipv4=$(echo "$ipv4" | awk '{print $1}')
    if [[ -n "$ipv4" && "$ipv4" != "none" ]]; then
        used_ip_map["$ipv4"]=1
    fi
done < <(incus list --format csv)
log "目前已用 IP: ${!used_ip_map[*]:-（無）}"

# ---------- 分配兩個空閒 IP ----------
allocate_ip() {
    local i candidate
    for i in $(seq "$USABLE_START" "$USABLE_END"); do
        candidate="${NETWORK_PREFIX}$i"
        [[ "$candidate" == "$GATEWAY" ]] && continue
        if [[ -z "${used_ip_map[$candidate]:-}" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

MASTER_IP=$(allocate_ip) || error_exit "無法在網路 ${NETWORK_PREFIX}0/$NET_CIDR 找到可用 IP 作為主要容器。"
used_ip_map["$MASTER_IP"]=1

SLAVE_IP=$(allocate_ip) || error_exit "無法在網路 ${NETWORK_PREFIX}0/$NET_CIDR 找到第二個可用 IP 作為從容器。"
used_ip_map["$SLAVE_IP"]=1

log "分配的 IP:"
log "  主要容器 IP: $MASTER_IP"
log "  從容器 IP: $SLAVE_IP"

# ---------- 顯示摘要並請確認 ----------
cat <<EOF

即將使用以下資訊進行設定：
  主要容器名稱: $MASTER_CONTAINER
  從容器名稱:   $SLAVE_CONTAINER
  主要容器 IP:  $MASTER_IP
  從容器 IP:    $SLAVE_IP
  資料庫名稱:   $DB_NAME
  複製使用者:   $REPL_USER
  鏡像:         $MYSQL_IMAGE
  (密碼見腳本內部或環境變數)
EOF

if (( DRY_RUN )); then
    ok "DRY-RUN 完成：已驗證網路偵測、IP 分配與摘要，未建立任何容器或安裝 MySQL。"
    exit 0
fi

printf '是否繼續？(y/N): '
read -r answer </dev/tty
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    warn "使用者取消操作。"
    exit 0
fi

# ---------- 階段標題與診斷 ----------
phase() { printf '%b\n========== %s ==========%b\n' "$C_BOLD$C_INFO" "$*" "$C_RESET"; }

# 容器卡住/逾時時，盡量蒐集現場資訊讓使用者知道卡在哪
container_diag() {
    local name=$1
    warn "---------- 容器 $name 診斷資訊 ----------"
    warn "Incus 實例狀態:"
    incus list "$name" 2>&1 || true
    warn "cloud-init 狀態:"
    incus exec "$name" -- cloud-init status 2>&1 || warn "  (無法執行 cloud-init status，容器 agent 可能尚未就緒)"
    warn "dpkg/apt 是否被佔用 (鎖):"
    incus exec "$name" -- bash -c 'fuser /var/lib/dpkg/lock-frontend 2>/dev/null && echo "  dpkg 鎖被佔用中（apt 仍在執行）" || echo "  dpkg 未被鎖定"' 2>&1 || true
    warn "MySQL 服務狀態:"
    incus exec "$name" -- systemctl status mysql --no-pager -l 2>&1 | tail -n 15 || warn "  (mysql 服務尚未存在)"
    warn "MySQL 日誌 (最後 15 行):"
    incus exec "$name" -- journalctl -u mysql --no-pager -n 15 2>&1 || true
    warn "----------------------------------------"
}

# ---------- 等待容器啟動並套用靜態 IP ----------
wait_for_container() {
    local name=$1
    local ip=$2
    local timeout=120
    local interval=3
    local elapsed=0
    local state
    log "等待容器 $name 啟動並取得 IP $ip (逾時 ${timeout}s)..."
    while ! incus_exec "$name" ip -4 addr show eth0 2>/dev/null | grep -q "inet $ip/"; do
        sleep "$interval"
        ((elapsed+=interval))
        if (( elapsed % 15 == 0 )); then
            state=$(incus list "$name" -c s --format csv 2>/dev/null || echo "UNKNOWN")
            log "  …仍在等待 $name 取得 IP (實例狀態=$state, 已等 ${elapsed}/${timeout}s)"
        fi
        if (( elapsed >= timeout )); then
            warn "容器 $name 在 ${timeout}s 內未取得 IP $ip。"
            container_diag "$name"
            error_exit "容器 $name 啟動逾時，請見上方診斷資訊。"
        fi
    done
    ok "容器 $name 已就緒，IP=$ip (耗時 ${elapsed}s)。"
}

# ---------- 建立容器（若不存在）並指派靜態 IP ----------
ensure_container() {
    local name=$1
    local ip=$2
    if incus list "$name" --format csv | grep -q "^$name,"; then
        log "容器 $name 已存在，沿用。"
    else
        log "建立容器 $name (鏡像 $MYSQL_IMAGE)，首次需下載鏡像，請稍候…"
        incus launch "$MYSQL_IMAGE" "$name" -c security.nesting=true -c limits.memory=2GB
        ok "容器 $name 已建立。"
    fi
    log "指派靜態 IP $ip 給 $name 並重啟以套用…"
    incus config device override "$name" eth0 ipv4.address="$ip" 2>/dev/null \
        || incus config device set "$name" eth0 ipv4.address "$ip"
    incus restart "$name"
    wait_for_container "$name" "$ip"
}

phase "步驟 1/4：建立容器並指派靜態 IP"
ensure_container "$MASTER_CONTAINER" "$MASTER_IP"
ensure_container "$SLAVE_CONTAINER" "$SLAVE_IP"

# ---------- 安裝 MySQL ----------
install_mysql() {
    local container=$1
    log "[$container] 等待 cloud-init 完成（避免與 apt 衝突，最多 180s）…"
    incus_exec "$container" timeout 180 cloud-init status --wait \
        || warn "[$container] cloud-init 未在時限內回報完成，仍繼續嘗試安裝。"

    log "[$container] 預埋 root 密碼並更新套件索引（apt-get update）…"
    incus_exec "$container" bash -c "
        export DEBIAN_FRONTEND=noninteractive
        debconf-set-selections <<< 'mysql-community-server mysql-community-server/root-pass password $MYSQL_ROOT_PASSWORD'
        debconf-set-selections <<< 'mysql-community-server mysql-community-server/re-root-pass password $MYSQL_ROOT_PASSWORD'
        apt-get update -qq
    " || error_exit "[$container] apt-get update 失敗，請檢查容器網路或套件來源。"

    log "[$container] 安裝 mysql-server / mysql-client（可能需數分鐘，以下為 apt 即時輸出）…"
    incus_exec "$container" bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y mysql-server mysql-client
    " || { container_diag "$container"; error_exit "[$container] MySQL 套件安裝失敗，請見上方診斷資訊。"; }

    log "[$container] 啟用並啟動 mysql 服務…"
    incus_exec "$container" bash -c "systemctl enable mysql && systemctl start mysql" \
        || { container_diag "$container"; error_exit "[$container] mysql 服務啟動失敗。"; }
    ok "[$container] MySQL 安裝完成。"
}

phase "步驟 2/4：安裝 MySQL"
install_mysql "$MASTER_CONTAINER"
install_mysql "$SLAVE_CONTAINER"

# ---------- 等待 MySQL 就緒 ----------
wait_for_mysql() {
    local container=$1
    local timeout=60
    local interval=2
    local elapsed=0
    log "[$container] 等待 MySQL 接受連線（逾時 ${timeout}s）…"
    while ! incus_exec "$container" mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent &>/dev/null; do
        sleep "$interval"
        ((elapsed+=interval))
        if (( elapsed % 10 == 0 )); then
            log "  …$container 的 MySQL 尚未就緒 (已等 ${elapsed}/${timeout}s)"
        fi
        if (( elapsed >= timeout )); then
            warn "[$container] MySQL 在 ${timeout}s 內未就緒。"
            container_diag "$container"
            error_exit "[$container] MySQL 就緒逾時，請見上方診斷資訊。"
        fi
    done
    ok "[$container] MySQL 已可連線 (耗時 ${elapsed}s)。"
}

# ---------- 確認 root 密碼（debconf 失效時的 fallback） ----------
ensure_root_password() {
    local container=$1
    local timeout=60
    local interval=2
    local elapsed=0
    local resets=0
    log "[$container] 確認 root 密碼（含 socket fallback，逾時 ${timeout}s）…"
    while true; do
        # 1) 已能用密碼登入（debconf 預埋成功）
        if incus_exec "$container" mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent &>/dev/null; then
            ok "[$container] root 密碼已生效。"
            return 0
        fi
        # 2) root 可能為 auth_socket 或空密碼，透過本機 socket 以 root 身分重設
        if incus_exec "$container" mysql -uroot <<EOF &>/dev/null
SET SESSION sql_log_bin=0;
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '$MYSQL_ROOT_PASSWORD';
FLUSH PRIVILEGES;
EOF
        then
            ((resets++))
            if (( resets > 3 )); then
                container_diag "$container"
                error_exit "[$container] 已重設 root 密碼多次仍無法以密碼登入，請手動檢查認證設定。"
            fi
            log "[$container] 已透過 socket 重設 root 密碼（第 $resets 次），重新驗證…"
            continue
        fi
        # 兩者皆失敗：MySQL 可能尚未就緒，稍候重試
        if (( elapsed % 10 == 0 )); then
            log "  …等待 $container 的 MySQL 可被連線/重設 (已等 ${elapsed}/${timeout}s)"
        fi
        sleep "$interval"
        ((elapsed+=interval))
        if (( elapsed >= timeout )); then
            warn "[$container] 無法確認或重設 root 密碼。"
            container_diag "$container"
            error_exit "[$container] root 密碼處理逾時，請見上方診斷資訊。"
        fi
    done
}

ensure_root_password "$MASTER_CONTAINER"
ensure_root_password "$SLAVE_CONTAINER"

# ---------- 設定 MySQL 參數（GTID 複製） ----------
configure_mysql() {
    local container=$1
    local role=$2   # master or slave
    local server_id=$3
    local cnf_path="/etc/mysql/mysql.conf.d/zz-replication.cnf"

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
    # 從容器設為唯讀，避免被誤寫造成主從分歧（複製執行緒不受 read_only 限制）
    if [[ "$role" == "slave" ]]; then
        config+=$'\nread_only=ON\nsuper_read_only=ON'
    fi

    log "將設定寫入 $container:$cnf_path"
    echo "$config" | incus_exec "$container" bash -c "cat > $cnf_path"
    log "重啟 $container 的 MySQL 服務..."
    incus_exec "$container" systemctl restart mysql
    sleep 3
    wait_for_mysql "$container"
    log "容器 $container 已設定為 $role (server-id=$server_id)"
}

phase "步驟 3/4：設定 GTID 複製"
configure_mysql "$MASTER_CONTAINER" master 1
configure_mysql "$SLAVE_CONTAINER" slave 2

# ---------- 在主容器建立複製使用者 ----------
log "在主容器 $MASTER_CONTAINER 上建立複製使用者 $REPL_USER..."
incus_exec "$MASTER_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<EOF
CREATE USER IF NOT EXISTS '$REPL_USER'@'%' IDENTIFIED BY '$REPL_PASSWORD';
GRANT REPLICATION SLAVE ON *.* TO '$REPL_USER'@'%';
FLUSH PRIVILEGES;
EOF
log "主容器複製使用者建立完成。"

# ---------- 設定 slave 複製（GTID 自動定位） ----------
log "設定從容器 $SLAVE_CONTAINER 從主容器 $MASTER_CONTAINER 複製..."
incus_exec "$SLAVE_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<EOF
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
log "從容器已設定為從主容器複製。"

# ---------- 檢查 slave 狀態 ----------
sleep 2
SLAVE_STATUS=$(incus_exec "$SLAVE_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G")
log "從容器狀態（重點欄位）："
echo "$SLAVE_STATUS" | grep -E 'Replica_IO_Running|Replica_SQL_Running|Last_IO_Error|Last_SQL_Error|Seconds_Behind_Source' || true

IO_RUNNING=$(echo "$SLAVE_STATUS" | awk -F': ' '/Replica_IO_Running/{gsub(/ /,"",$2);print $2}')
SQL_RUNNING=$(echo "$SLAVE_STATUS" | awk -F': ' '/Replica_SQL_Running/{gsub(/ /,"",$2);print $2}')
if [[ "$IO_RUNNING" == "Yes" && "$SQL_RUNNING" == "Yes" ]]; then
    ok "複製執行緒正常運作 (IO=Yes, SQL=Yes)。"
else
    warn "複製執行緒未正常運作 (IO=$IO_RUNNING, SQL=$SQL_RUNNING)。以下為完整狀態供排查："
    echo "$SLAVE_STATUS"
fi

# ---------- 建立測試資料庫與表格 ----------
phase "步驟 4/4：驗證複製"
log "在主要容器上建立測試資料庫 $DB_NAME..."
incus_exec "$MASTER_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
incus_exec "$MASTER_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$DB_NAME" -e "
    CREATE TABLE IF NOT EXISTS test_replication (
        id INT AUTO_INCREMENT PRIMARY KEY,
        msg VARCHAR(255),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
"
log "在主要容器中插入測試資料..."
incus_exec "$MASTER_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$DB_NAME" -e "
    INSERT INTO test_replication (msg) VALUES ('來自主容器的問候，時間：$(date)');
"
log "等待複製同步（5 秒）..."
sleep 5

log "檢查從容器是否已接收到資料："
incus_exec "$SLAVE_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$DB_NAME" -e "SELECT * FROM test_replication;"

ok "=== $(date): MySQL 主從複製設定完成 ==="
printf '%b設定完成！%b詳細日誌請參見：%s\n' "$C_OK$C_BOLD" "$C_RESET" "$LOGFILE"
echo "主要容器：$MASTER_CONTAINER ($MASTER_IP)"
echo "從容器：  $SLAVE_CONTAINER ($SLAVE_IP)"
echo "複製資料庫：$DB_NAME"
echo "您現在可以使用這些容器進行實驗。"
