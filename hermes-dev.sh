#!/usr/bin/env bash
#====================================================================
# hermes-dev.sh
#   建立 Incus 容器 hermes-dev，內含 Ubuntu 24.04 + 開發工具 + Hermes Agent
#   並提供 SSH 登入（host port 2222 → container port 22）
#
#   使用方式：
#       sudo ./hermes-dev.sh          # 或直接以 root 執行
#
#   完成後，於 GCP 主機上執行：
#       ssh hermesuser@<HOST_IP> -p 2222
#   進入容器後，可直接使用 hermes：
#       hermes setup          #（視需求而設定模型／提供者）
#       hermes chat -q "你好"
#====================================================================

set -euo pipefail

# -------------------- 可自行調整的變數 --------------------
CONTAINER_NAME="hermes-dev"          # Incus 容器名稱
UBUNTU_RELEASE="24.04"               # 使用的 Ubuntu 版本
TARGET_USER="hermesuser"             # 容器內的一般使用者
SSH_HOST_PORT=2222                   # 主機對外映射的 SSH 埠 (容器內部永遠是 22)
PASSWORDLESS_SUDO=true               # 是否給目標使用者免密 sudo（true/false）
# ---------------------------------------------------------

# 基礎套件清單（可依需求增減）
BASE_PACKAGES=(
    git curl wget vim tmux htop
    ca-certificates gnupg lsb-release software-properties-common
    build-essential openssh-server rsync unzip zip jq gh
)

# 輔助函式：在容器內執行指令
incus_exec() {
    incus exec "$CONTAINER_NAME" -- "$@"
}

echo "🔍 檢查 Incus 是否已安裝..."
if ! command -v incus >/dev/null 2>&1; then
    echo "❌ 錯誤：找不到 incus 指令。請先安裝 Incus (sudo snap install incus)。"
    exit 1
fi

echo "🚀 建立 Incus 容器：$CONTAINER_NAME (基礎映像 images:ubuntu/$UBUNTU_RELEASE)"
incus launch images:ubuntu/$UBUNTU_RELEASE "$CONTAINER_NAME" -c security.nesting=true --empty

echo "⏳ 等待容器完全啟動（網路與 SSH 服務準備就緒）..."
# 透過輪詢容器的狀態，直到顯示為 RUNNING
while true; do
    STATUS=$(incus info "$CONTAINER_NAME" --show-log=false | awk -F': ' '/Status:/ {print $2}' | xargs)
    if [[ "$STATUS" == "Running" ]]; then
        echo "✅ 容器目前處於 Running 狀態。"
        break
    fi
    sleep 2
done

# 進一步確認容器內的 SSH 服務可以啟動（先更新套件庫）
echo "📦 更新容器內的套件庫..."
incus_exec apt-get update -qq

echo "🛠️  安裝基礎套件..."
incus_exec apt-get install -y "${BASE_PACKAGES[@]}"

echo "🟢 安裝 Node.js 20.x (NodeSource)..."
incus_exec bash -c "
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
"

echo "🐍 安裝 Python 3、venv、pip..."
incus_exec apt-get install -y python3 python3-venv python3-pip

echo "📦 安裝 uv（Python 包管理工具）..."
incus_exec pip3 install uv

echo "🤖 安裝 Hermes Agent（官方腳本）..."
incus_exec bash -c "
    curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash -
"

echo "👤 建立一般使用者：$TARGET_USER"
incus_exec bash -c "
    adduser --disabled-password --gecos '' $TARGET_USER &&
    usermod -aG sudo $TARGET_USER
"

if [[ "$PASSWORDLESS_SUDO" == "true" ]]; then
    echo "🔓 設定 $TARGET_USER 免密 sudo"
    incus_exec bash -c "
        echo '$TARGET_USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$TARGET_USER &&
        chmod 440 /etc/sudoers.d/$TARGET_USER
    "
else
    echo "🔒 保留 sudo 密碼提示（不設免密）"
fi

echo "🔧 啟用 SSH 服務並設定開機自動啟動"
incus_exec systemctl enable ssh

echo "🔗 設定 Incus proxy device：將主機埠 $SSH_HOST_PORT 轉發到容器內 22 (SSH)"
incus config device add "$CONTAINER_NAME" httpssh-proxy proxy listen=tcp:0.0.0.0:$SSH_HOST_PORT connect=tcp:127.0.0.1:22

echo "🧹 清理 apt 快取與暫存檔案，以減少最終映像大小"
incus_exec bash -c "
    apt-get clean &&
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
"

echo "🛑 停止容器以準備後續使用（如需匯出 image，可於此處執行 incus publish）"
incus stop "$CONTAINER_NAME"

echo "========================================================"
echo "✅ 容器建置完成！"
echo "   容器名稱：$CONTAINER_NAME"
echo "   使用方式："
echo "     incus start $CONTAINER_NAME          # 先啟動容器（若尚未啟動）"
echo "     ssh $TARGET_USER@<HOST_IP> -p $SSH_HOST_PORT   # 登入容器"
echo "   登入後，可直接使用 hermes："
echo "     hermes setup          #（首次設定模型／提供者，可視需求而定）"
echo "     hermes chat -q \"你好，請介紹一下你自己\""
echo "========================================================"
echo "💡 如需將此容器匯出為可分發的 Incus image，可執行："
echo "     incus publish $CONTAINER_NAME --alias hermes-dev-ubuntu2404 --compression gzip"
echo "   之後其他主機只要執行："
echo "     incus launch hermes-dev-ubuntu2404 <new-name> -c security.nesting=true"
echo "========================================================"

exit 0