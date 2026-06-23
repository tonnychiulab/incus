# Incus MySQL 叢集工具 — 功能規格 v0.1

> 狀態：規劃中（本文件不含實作，僅作為後續開發藍圖）
> 現況基準：`incus-mysql-replication.sh` 已能一鍵建立 1 master + 1 slave 的 GTID 主從複製並驗證通過。

---

## 1. 目標

把目前寫死「1 master + 1 slave」的內部小工具，演進為：

- **可自訂叢集規模**：1 master + N 台 read slave
- **ProxySQL 讀寫分流**：寫導 master、讀分散到 slave
- **宣告式設定**：YAML 設定檔當單一真相來源（直接對接未來 TUI）
- **未來 TUI**：Go + Bubble Tea 即時面板

---

## 2. 範圍

### 本階段（MVP）
- 宣告式 `cluster.yaml` 設定
- N 台 `read` 角色 slave
- ProxySQL 讀寫分流（含監控自動剔除落後節點）
- 指令：`apply` / `status` / `destroy`
- Secret：0600 檔為主 + env 覆寫 + 缺值自動產生
- 人類彩色 log + `--json` 機器事件輸出

### 不在本階段（預留 / 後續）
- 角色 `standby` / `delayed` / `analytics`（schema 預留欄位，填值即報「尚未實作」）
- 指令 `add-slave` / `remove-slave` / `promote`
- `apply` 自動刪除 config 已移除的節點（一律交給 `destroy` 或手動）

---

## 3. 決策摘要

| 項目 | 決定 | 備註 |
|---|---|---|
| 設定模型 | 宣告式 YAML 設定檔 | 直接接 TUI |
| 角色範圍 | 僅 `read` 啟用，其餘預留 | schema 向前相容 |
| 讀寫分流 | 納入，採 **ProxySQL** | 非 HAProxy（需依查詢分流） |
| TUI 技術 | **Go + Bubble Tea** | 單一靜態二進位、原生並發 |
| `apply` 差異化 | 缺的建、已存在校正；**不自動刪**，孤兒節點僅警告 | 破壞性操作需明確 |
| Secret | **0600 secret 檔**為主，env 覆寫，缺值自動產生 | 拓樸與機密分離 |

---

## 4. 設定檔 schema

### 4.1 `cluster.yaml`（拓樸，非機密，可進版控）

```yaml
cluster:
  network: auto                 # 不填則自動偵測（目前僅支援 /24）
  image: images:ubuntu/24.04/cloud
  database: myappdb
master:
  name: mysql-master
  ip: auto                      # 或指定，如 10.172.106.2
slaves:
  - { name: mysql-slave-1, ip: auto, role: read }
  - { name: mysql-slave-2, ip: auto, role: read }
  - { name: mysql-slave-3, ip: auto, role: read }
proxy:
  enabled: true
  name: proxysql
  ip: auto
  read_write_split: true
credentials:                    # 僅放「鍵名」，不放值
  root_password_env: MYSQL_ROOT_PASSWORD
  repl_user: replicator
```

- `role` 目前只接受 `read`；其他值 → 中止並提示「尚未實作」。
- YAML 解析採 `yq`（mikefarah 版，單一 Go binary）。

### 4.2 `cluster.secrets`（機密，0600，永不進版控/log）

`KEY=value` env-file 格式，bash 可 `set -a; source`、Go 用 godotenv 讀：

```
MYSQL_ROOT_PASSWORD=...
REPL_PASSWORD=...
PROXYSQL_MONITOR_PASSWORD=...
PROXYSQL_ADMIN_PASSWORD=...
APP_DB_PASSWORD=...
```

---

## 5. 命名 / 網路 / ID 規則

- **容器名稱**：須符合 Incus 規範 — 1–63 字元、僅字母數字連字號、字母開頭、不可連字號結尾（[官方文件](https://linuxcontainers.org/incus/docs/main/reference/instance_properties/)）。
- **IP**：`auto` 從預設網路自動分配空閒位址，或於設定檔 pin 固定值；目前僅支援 /24。
- **server-id**：取 IP 末段自動指派，唯一且重跑冪等。

---

## 6. 角色定義

| 角色 | 用途 | super_read_only | log_replica_updates | SOURCE_DELAY | 本階段 |
|---|---|---|---|---|---|
| **read** | 讀取流量擴展（主力） | ON | 關 | 0 | ✅ |
| standby | 故障接手候選（可 promote） | ON | ON | 0 | 預留 |
| delayed | 防呆/災備（誤刪可回溯） | ON | ON | 例如 3600 | 預留 |
| analytics | 報表/重查詢隔離 | ON | 關 | 0 | 預留 |

`configure_mysql` 依 role 查設定表套用對應 cnf 與 `CHANGE REPLICATION SOURCE TO` 選項。

---

## 7. 佈建流程（`apply`）

```
讀 config → 偵測網路 → 為所有節點分配 IP / server-id
  → for each 節點:
       ensure_container(init → 設 IP → start)   # 不用 restart，避免優雅關機逾時、不打斷 cloud-init
       install_mysql → ensure_root_password → configure_mysql(依角色)
  → master 建 repl / monitor / app 帳號（靠複製下放各 slave）
  → for each slave: CHANGE REPLICATION SOURCE TO（GTID auto-position + GET_SOURCE_PUBLIC_KEY）→ START REPLICA
  → 若 proxy.enabled: 佈建 proxysql → 灌 hostgroup / query rule / user
  → 驗證: 每台 slave 健康 + 經 proxy 讀寫分流
```

**冪等性**：已存在節點略過建立、僅校正設定。
**漂移處理**：incus 內有、但 config 已移除的孤兒節點 → 只列黃色警告，不刪除。

---

## 8. ProxySQL 設計

- **Hostgroups**：writer = 10（master）、reader = 20（slaves）。
- **`mysql_replication_hostgroups`**：依各節點 `read_only` 變數自動分類 — 對接 slave 的 `super_read_only=ON` 與 master 的 `read_only=OFF`，角色設定天然驅動分流。
- **Query rules**：`^SELECT...FOR UPDATE` → writer；`^SELECT` → reader；其餘 → writer。
- **Monitor 帳號**：master 建立後複製到各 slave，供 ProxySQL 健康檢查與延遲監測。
- **部署**：獨立 `proxysql` 容器，自有靜態 IP。
- **驗證**：經 ProxySQL 連線，寫入落 master、讀取輪到不同 slave（以 `SELECT @@hostname` 或 ProxySQL stats 佐證）。

---

## 9. Secret 管理

- **取值優先序**：真實環境變數 > `cluster.secrets` 檔 > 缺則自動產生。
- **自動產生**：monitor / app / proxysql-admin 等缺值時，產生符合 validate_password 政策的強隨機值，寫回 0600 檔並回報；root / repl 可由使用者指定。
- **權限把關**：以 `umask 077` 建立、強制 `chmod 600`；偵測到 group/world 可讀則拒絕執行。
- **不外洩**：沿用 log ANSI 過濾思路，secret 值不 echo、不入 log。

---

## 10. 輸出與可觀測性

- **人類**：彩色分階段 log（沿用現有 `phase`/`log`/`ok`/`warn`/`error_exit` + 心跳 + 逾時診斷）。
- **機器（TUI）**：`--json` 模式輸出 NDJSON 事件：
  `{"ts","node","phase","status","msg","lag"}`
- **節點狀態模型**：
  `pending → creating → installing → configuring → replicating → healthy | error`
  proxy：`pending → installing → configuring → healthy`

---

## 11. 指令介面

| 指令 | 作用 | 本階段 |
|---|---|---|
| `apply` | 依 config 收斂實際狀態（冪等） | ✅ |
| `status` | 所有節點即時複製健康 + proxy hostgroup 視圖 | ✅ |
| `destroy` | 依 config 拆除所有節點 | ✅ |
| `add-slave` / `remove-slave` | 改 config 後套用差異 | 後續 |
| `promote` | 故障接手（需 standby 角色） | 待角色解鎖 |

---

## 12. TUI 架構與路線圖

**技術**：Go + Bubble Tea（搭 Lipgloss / Bubbles）。理由：單一靜態二進位、原生並發（平行佈建 + 即時輪詢）、原生 YAML/JSON、長期可接 Incus Go client。

- **階段 A**：bash 引擎改為「讀設定檔 + 迴圈佈建 + 輸出 JSON 事件」，仍可獨立 CLI 跑。
- **階段 B**：Go TUI 當外殼，spawn bash 引擎、解析 JSON 事件畫即時面板（邏輯零重寫）。
- **階段 C（可選）**：Go 以 Incus client 直接接管，逐步淘汰 bash。

---

## 13. 安全與作業慣例

- **改程式前先 zip 備份**整支工具，事後可還原。
- Secret 不進版控、不入 log。
- 破壞性操作（刪容器、destroy）需明確指令或確認。

---

## 14. 驗證標準（沿用現行）

1. 複製鏈路健康：`Replica_IO_Running=Yes`、`Replica_SQL_Running=Yes`、`Seconds_Behind_Source=0`、無 Last_Error。
2. 即時同步：master 寫入 → 各 slave 秒級讀到。
3. 方向性防護：直接寫 slave 被 `super_read_only` 擋下（ERROR 1290）。
4. （納入 ProxySQL 後）經 proxy 讀寫分流：寫落 master、讀分散 slave。
