#!/usr/bin/env bash
# RK3588 box bootstrap: RKNN Runtime 2.3.2 + Docker + RKNN compose
set -euo pipefail

TARGET_RKNN_VERSION="2.3.2"
REPO_URL="https://github.com/zuoa/cvab-installer.git"
# Default branch is master; also try main so either raw URL works.
REPO_RAW_CANDIDATES=(
  "https://raw.githubusercontent.com/zuoa/cvab-installer/master"
  "https://raw.githubusercontent.com/zuoa/cvab-installer/main"
)
# Official first; on timeout/failure wrap github.com / raw.githubusercontent.com.
# These prefixes are prepended to the original URL (https://mirror/.../https://github.com/...).
GH_PROXY_PREFIXES=(
  "https://ghfast.top/"
  "https://gh-proxy.com/"
  "https://mirror.ghproxy.com/"
  "https://gitdl.cn/"
)
CURL_CONNECT_TIMEOUT=10
CURL_MAX_TIME=45
RKNN_TAG="v${TARGET_RKNN_VERSION}"
RKNN_LIB_REL="rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so"
RKNN_SERVER_REL="rknpu2/runtime/Linux/rknn_server/aarch64/usr/bin/rknn_server"
RKNN_LIB_URL="https://github.com/airockchip/rknn-toolkit2/raw/${RKNN_TAG}/${RKNN_LIB_REL}"
RKNN_SERVER_URL="https://github.com/airockchip/rknn-toolkit2/raw/${RKNN_TAG}/${RKNN_SERVER_REL}"
RKNN_JSDELIVR_LIB="https://cdn.jsdelivr.net/gh/airockchip/rknn-toolkit2@${RKNN_TAG}/${RKNN_LIB_REL}"
RKNN_JSDELIVR_SERVER="https://cdn.jsdelivr.net/gh/airockchip/rknn-toolkit2@${RKNN_TAG}/${RKNN_SERVER_REL}"
RKNN_TARBALL_URL="https://github.com/airockchip/rknn-toolkit2/archive/refs/tags/${RKNN_TAG}.tar.gz"

DEFAULT_WORKDIR="/opt/cvab"
BACKUP_ROOT="/var/backups/rknn-runtime"

WORKDIR="${DEFAULT_WORKDIR}"
MQTT_MODE=""          # mqtt | no-mqtt
SKIP_RKNN=0
SKIP_DOCKER=0
START_MODE=""         # start | no-start
FORCE=0

RKNN_OLD_VERSION="(not installed)"
RKNN_NEW_VERSION=""
RKNN_BACKUP_DIR=""
RKNN_ACTION="skipped"
COMPOSE_VARIANT=""
DOCKER_VERSION=""
COMPOSE_VERSION=""

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'
  C_CYN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""
fi

log()  { printf '%s\n' "$*"; }
info() { printf '%s[INFO]%s %s\n' "$C_CYN" "$C_RESET" "$*"; }
ok()   { printf '%s[OK]%s   %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
err()  { printf '%s[ERR]%s  %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%s==> [%s] %s%s\n' "$C_BOLD" "$1" "$2" "$C_RESET"; }

usage() {
  cat <<'EOF'
RK3588 环境初始化：RKNN Runtime 2.3.2 + Docker + RKNN compose

用法:
  sudo bash install.sh [选项]

选项:
  --mqtt              部署带 MQTT 的 compose（非交互）
  --no-mqtt           部署不带 MQTT 的 compose（非交互）
  --workdir PATH      工作目录，默认 /opt/cvab
  --start             准备完成后执行 docker compose up -d
  --no-start          只准备文件，不启动容器
  --skip-rknn         跳过 RKNN Runtime 检查/升级
  --skip-docker       跳过 Docker 安装
  --force             非 RK3588 时不询问，继续执行
  -h, --help          显示本帮助

示例:
  sudo bash install.sh
  sudo bash install.sh --mqtt --no-start
  curl -fsSL https://raw.githubusercontent.com/zuoa/cvab-installer/master/install.sh | sudo bash -s -- --mqtt --no-start
EOF
}

# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mqtt) MQTT_MODE="mqtt"; shift ;;
    --no-mqtt) MQTT_MODE="no-mqtt"; shift ;;
    --workdir)
      [[ $# -ge 2 ]] || die "--workdir 需要路径"
      WORKDIR="$2"
      shift 2
      ;;
    --start) START_MODE="start"; shift ;;
    --no-start) START_MODE="no-start"; shift ;;
    --skip-rknn) SKIP_RKNN=1; shift ;;
    --skip-docker) SKIP_DOCKER=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（--help 查看用法）" ;;
  esac
done

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
has_tty() { [[ -r /dev/tty ]]; }

prompt_read() {
  local prompt="$1"
  local dest="$2"
  if has_tty; then
    printf '%s' "$prompt" > /dev/tty
    IFS= read -r "$dest" < /dev/tty
    return 0
  fi
  return 1
}

confirm() {
  local prompt="${1:-继续? [y/N] } "
  local ans=""
  prompt_read "$prompt" ans || return 1
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "请用 root 运行：sudo bash $0 $*"
  fi
}

script_dir() {
  local src="${BASH_SOURCE[0]:-}"
  if [[ -n "$src" && -f "$src" && "$src" != /dev/fd/* ]]; then
    cd "$(dirname "$src")" && pwd
  else
    echo ""
  fi
}

SCRIPT_DIR="$(script_dir)"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_pkg() {
  local pkg="$1"
  if have_cmd "$pkg"; then
    return 0
  fi
  if have_cmd apt-get; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  else
    die "缺少命令 $pkg，且当前系统没有 apt-get"
  fi
}

is_github_origin() {
  case "$1" in
    https://github.com/*|https://raw.githubusercontent.com/*|https://codeload.github.com/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Print the original URL, then China-reachable mirrors. Non-GitHub URLs are unchanged.
expand_github_mirrors() {
  local url="$1"
  printf '%s\n' "$url"
  is_github_origin "$url" || return 0

  local prefix
  for prefix in "${GH_PROXY_PREFIXES[@]}"; do
    printf '%s\n' "${prefix}${url}"
  done

  local owner repo ref path
  if [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.*)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    ref="${BASH_REMATCH[3]}"
    path="${BASH_REMATCH[4]}"
    printf '%s\n' "https://raw.gitmirror.com/${owner}/${repo}/${ref}/${path}"
    printf '%s\n' "https://cdn.jsdelivr.net/gh/${owner}/${repo}@${ref}/${path}"
    printf '%s\n' "https://raw.kkgithub.com/${owner}/${repo}/${ref}/${path}"
  elif [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/raw/([^/]+)/(.*)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    ref="${BASH_REMATCH[3]}"
    path="${BASH_REMATCH[4]}"
    printf '%s\n' "https://cdn.jsdelivr.net/gh/${owner}/${repo}@${ref}/${path}"
    printf '%s\n' "https://raw.gitmirror.com/${owner}/${repo}/${ref}/${path}"
    printf '%s\n' "https://kkgithub.com/${owner}/${repo}/raw/${ref}/${path}"
  elif [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/archive/(.*)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    printf '%s\n' "https://kkgithub.com/${owner}/${repo}/archive/${BASH_REMATCH[3]}"
  fi
}

download() {
  local url="$1"
  local dest="$2"
  if have_cmd curl; then
    # One attempt per URL: fail fast so we can fall through to a mirror.
    curl -fL --retry 0 --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
      --max-time "${CURL_MAX_TIME}" -o "$dest" "$url"
  elif have_cmd wget; then
    wget --timeout="${CURL_CONNECT_TIMEOUT}" --tries=1 -O "$dest" "$url"
  else
    die "需要 curl 或 wget"
  fi
}

try_download() {
  local dest="$1"
  shift
  local url expanded
  local -a queue=()
  local -A seen=()
  for url in "$@"; do
    while IFS= read -r expanded; do
      [[ -n "$expanded" ]] || continue
      [[ -z "${seen[$expanded]+x}" ]] || continue
      seen["$expanded"]=1
      queue+=("$expanded")
    done < <(expand_github_mirrors "$url")
  done
  for url in "${queue[@]}"; do
    info "下载 $url"
    if download "$url" "$dest"; then
      ok "下载成功"
      return 0
    fi
    warn "失败，尝试下一源"
    rm -f "$dest"
  done
  return 1
}

clone_github() {
  local dest="$1"
  local url="${2:-$REPO_URL}"
  local candidate
  local -a queue=()
  queue+=("$url")
  if [[ "$url" == https://github.com/* ]]; then
    local prefix
    for prefix in "${GH_PROXY_PREFIXES[@]}"; do
      queue+=("${prefix}${url}")
    done
    # hostname rewrite: github.com/a/b.git -> kkgithub.com/a/b.git
    queue+=("https://kkgithub.com/${url#https://github.com/}")
    queue+=("https://gitclone.com/github.com/${url#https://github.com/}")
  fi
  if ! have_cmd git; then
    return 1
  fi
  for candidate in "${queue[@]}"; do
    info "git clone $candidate"
    rm -rf "$dest"
    if git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=20 \
      -c http.connectTimeout="${CURL_CONNECT_TIMEOUT}" \
      clone --depth 1 "$candidate" "$dest"; then
      ok "clone 成功"
      return 0
    fi
    warn "clone 失败，尝试下一源"
    rm -rf "$dest"
  done
  return 1
}

extract_semver() {
  printf '%s' "${1:-}" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true
}

normalize_semver() {
  local v="$1"
  case "$v" in
    *.*.*) printf '%s\n' "$v" ;;
    *.*)   printf '%s.0\n' "$v" ;;
    *)     printf '%s\n' "$v" ;;
  esac
}

# 0: $1 < $2   1: $1 == $2   2: $1 > $2
cmp_semver() {
  local a b
  a="$(normalize_semver "$1")"
  b="$(normalize_semver "$2")"
  if [[ "$a" == "$b" ]]; then
    return 1
  fi
  if [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" == "$a" ]]; then
    return 0
  fi
  return 2
}

host_ip() {
  local ip=""
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -z "$ip" ]] && have_cmd ip; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  printf '%s\n' "${ip:-<box-ip>}"
}

read_os() {
  # shellcheck disable=SC1091
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
  fi
  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  OS_PRETTY="${PRETTY_NAME:-unknown}"
}

docker_family() {
  case "$OS_ID" in
    ubuntu|debian) printf '%s\n' "$OS_ID"; return 0 ;;
  esac
  case " $OS_LIKE " in
    *" ubuntu "*) printf 'ubuntu\n'; return 0 ;;
    *" debian "*) printf 'debian\n'; return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# 0. preflight
# ---------------------------------------------------------------------------
preflight() {
  step "0/3" "前置检查"
  require_root "$@"
  read_os

  local arch
  arch="$(uname -m)"
  [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] || die "需要 aarch64，当前是 $arch"

  local compatible=""
  if [[ -r /proc/device-tree/compatible ]]; then
    compatible="$(tr '\0' ' ' < /proc/device-tree/compatible)"
  fi

  info "系统: $OS_PRETTY"
  info "内核: $(uname -r)"
  info "架构: $arch"
  info "compatible: ${compatible:-<none>}"

  if [[ "$compatible" != *rk3588* ]]; then
    warn "未在 device-tree 中检测到 rk3588"
    if [[ "$FORCE" -ne 1 ]]; then
      if ! confirm "仍要继续? [y/N] "; then
        die "已取消。确认是 RK3588 后加 --force 可跳过询问"
      fi
    fi
  else
    ok "平台: RK3588"
  fi

  have_cmd curl || have_cmd wget || ensure_pkg curl
  have_cmd curl || have_cmd wget || die "安装 curl 失败"

  local node
  for node in /dev/dri /dev/mpp_service /dev/rga; do
    if [[ -e "$node" ]]; then
      ok "设备节点 $node"
    else
      warn "缺少设备节点 $node（worker 硬解/NPU 可能不可用）"
    fi
  done

  if [[ ! -e /sys/kernel/debug/rknpu ]] && [[ -d /sys/kernel/debug ]]; then
    if ! mountpoint -q /sys/kernel/debug 2>/dev/null; then
      info "尝试挂载 debugfs（仪表盘 NPU 负载需要）"
      mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
    fi
  fi
}

# ---------------------------------------------------------------------------
# 1. RKNN Runtime
# ---------------------------------------------------------------------------
find_librknnrt() {
  local p
  for p in /usr/lib/librknnrt.so /usr/lib/aarch64-linux-gnu/librknnrt.so /usr/lib64/librknnrt.so; do
    if [[ -e "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

read_so_version() {
  local file="$1"
  local pattern="$2"
  [[ -r "$file" ]] || return 1
  have_cmd strings || return 1
  strings "$file" 2>/dev/null | grep -iE "$pattern" | head -1 || true
}

probe_rknn() {
  local lib server driver
  lib="$(find_librknnrt || true)"
  if [[ -n "$lib" ]]; then
    info "librknnrt: $lib"
    info "  $(read_so_version "$lib" 'librknnrt version|rknnrt version' || echo '<no version string>')"
  else
    info "librknnrt: 未安装"
  fi

  server="/usr/bin/rknn_server"
  if [[ -e "$server" ]]; then
    info "rknn_server: $server"
    info "  $(read_so_version "$server" 'rknn_server version' || echo '<no version string>')"
  else
    info "rknn_server: 未安装"
  fi

  driver=""
  if [[ -r /sys/kernel/debug/rknpu/version ]]; then
    driver="$(tr -d '\0' < /sys/kernel/debug/rknpu/version | head -1)"
    info "NPU 驱动: $driver"
  else
    warn "读不到 /sys/kernel/debug/rknpu/version（debugfs 未挂载或驱动未加载）"
  fi
}

write_restore_script() {
  local dir="$1"
  cat > "$dir/restore.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# Restore RKNN Runtime files backed up at $(date -Iseconds)
BACKUP_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
if [[ "\$(id -u)" -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi
if [[ -f "\$BACKUP_DIR/paths.txt" ]]; then
  while IFS='=' read -r name path; do
    [[ -n "\$path" && -e "\$BACKUP_DIR/\$name" ]] || continue
    cp -a "\$BACKUP_DIR/\$name" "\$path"
    echo "restored \$path"
  done < "\$BACKUP_DIR/paths.txt"
fi
ldconfig || true
echo "RKNN Runtime restored from \$BACKUP_DIR"
EOF
  chmod +x "$dir/restore.sh"
}

download_rknn_files() {
  local tmp="$1"
  mkdir -p "$tmp"
  local lib="$tmp/librknnrt.so"
  local srv="$tmp/rknn_server"

  if try_download "$lib" "$RKNN_LIB_URL" "$RKNN_JSDELIVR_LIB"; then
    :
  else
    warn "直接下载 librknnrt.so 失败，改用官方 tag 压缩包"
    local tarball="$tmp/rknn-toolkit2.tar.gz"
    try_download "$tarball" "$RKNN_TARBALL_URL" || die "无法下载 rknn-toolkit2 ${RKNN_TAG}"
    tar -tzf "$tarball" | grep -E "/${RKNN_LIB_REL}$" >/dev/null \
      || die "压缩包里找不到 ${RKNN_LIB_REL}"
    tar -xzf "$tarball" -C "$tmp" --wildcards "*/${RKNN_LIB_REL}" "*/${RKNN_SERVER_REL}"
    local found_lib found_srv
    found_lib="$(find "$tmp" -type f -path "*/${RKNN_LIB_REL}" | head -1)"
    found_srv="$(find "$tmp" -type f -path "*/${RKNN_SERVER_REL}" | head -1)"
    [[ -n "$found_lib" ]] || die "解压后找不到 librknnrt.so"
    cp -f "$found_lib" "$lib"
    [[ -n "$found_srv" ]] && cp -f "$found_srv" "$srv"
  fi

  if [[ ! -s "$srv" ]]; then
    try_download "$srv" "$RKNN_SERVER_URL" "$RKNN_JSDELIVR_SERVER" \
      || warn "rknn_server 下载失败，仅升级 librknnrt.so"
  fi

  have_cmd file || ensure_pkg file
  local lib_desc
  lib_desc="$(file -b "$lib")"
  printf '%s' "$lib_desc" | grep -qiE 'ELF.*64.*ARM aarch64|ELF 64-bit LSB.*ARM aarch64|ELF 64-bit LSB shared object, ARM aarch64' \
    || die "librknnrt.so 不是 aarch64 ELF：$lib_desc"
  if [[ -s "$srv" ]]; then
    local srv_desc
    srv_desc="$(file -b "$srv")"
    printf '%s' "$srv_desc" | grep -qiE 'ELF.*64.*ARM aarch64|ELF 64-bit LSB' \
      || die "rknn_server 不是 aarch64 ELF：$srv_desc"
  fi
}

install_rknn() {
  step "1/3" "RKNN Runtime ${TARGET_RKNN_VERSION}"
  if [[ "$SKIP_RKNN" -eq 1 ]]; then
    warn "已跳过 RKNN（--skip-rknn）"
    RKNN_ACTION="skipped"
    return 0
  fi

  have_cmd strings || ensure_pkg binutils
  have_cmd file || ensure_pkg file
  probe_rknn

  local current_lib=""
  current_lib="$(find_librknnrt || true)"
  local current_ver=""
  if [[ -n "$current_lib" ]]; then
    current_ver="$(extract_semver "$(read_so_version "$current_lib" 'librknnrt version|rknnrt version' || true)")"
  fi
  RKNN_OLD_VERSION="${current_ver:-未安装}"

  if [[ -n "$current_ver" ]]; then
    set +e
    cmp_semver "$current_ver" "$TARGET_RKNN_VERSION"
    local cmp=$?
    set -e
    case "$cmp" in
      1)
        ok "已是 ${TARGET_RKNN_VERSION}，跳过升级"
        RKNN_NEW_VERSION="$current_ver"
        RKNN_ACTION="already-current"
        return 0
        ;;
      2)
        warn "当前 ${current_ver} 高于目标 ${TARGET_RKNN_VERSION}，不降级"
        RKNN_NEW_VERSION="$current_ver"
        RKNN_ACTION="kept-newer"
        return 0
        ;;
      0)
        info "当前 ${current_ver} < ${TARGET_RKNN_VERSION}，准备无损升级"
        ;;
    esac
  else
    info "未检测到可解析的 Runtime 版本，将安装 ${TARGET_RKNN_VERSION}"
  fi

  local stamp tmp dest_lib dest_server server_was_running=0
  stamp="$(date +%Y%m%d-%H%M%S)"
  RKNN_BACKUP_DIR="${BACKUP_ROOT}/${stamp}"
  tmp="$(mktemp -d /tmp/rknn-upgrade.XXXXXX)"
  trap 'rm -rf "$tmp"' RETURN

  download_rknn_files "$tmp"

  mkdir -p "$RKNN_BACKUP_DIR"
  : > "$RKNN_BACKUP_DIR/paths.txt"

  dest_lib="${current_lib:-/usr/lib/librknnrt.so}"
  dest_server="/usr/bin/rknn_server"

  if [[ -e "$dest_lib" ]]; then
    cp -a "$dest_lib" "$RKNN_BACKUP_DIR/librknnrt.so"
    echo "librknnrt.so=${dest_lib}" >> "$RKNN_BACKUP_DIR/paths.txt"
  fi
  if [[ -e "$dest_server" ]]; then
    cp -a "$dest_server" "$RKNN_BACKUP_DIR/rknn_server"
    echo "rknn_server=${dest_server}" >> "$RKNN_BACKUP_DIR/paths.txt"
  fi
  write_restore_script "$RKNN_BACKUP_DIR"
  ok "已备份到 $RKNN_BACKUP_DIR"

  if pidof rknn_server >/dev/null 2>&1 || pgrep -x rknn_server >/dev/null 2>&1; then
    server_was_running=1
    info "停止 rknn_server 以便替换"
    killall rknn_server 2>/dev/null || pkill -x rknn_server 2>/dev/null || true
    sleep 1
  fi

  if ! install -m 0755 "$tmp/librknnrt.so" "$dest_lib"; then
    warn "安装 librknnrt.so 失败，正在回滚"
    [[ -f "$RKNN_BACKUP_DIR/restore.sh" ]] && bash "$RKNN_BACKUP_DIR/restore.sh" || true
    die "RKNN 升级失败，已尝试回滚"
  fi

  if [[ -s "$tmp/rknn_server" ]]; then
    if ! install -m 0755 "$tmp/rknn_server" "$dest_server"; then
      warn "安装 rknn_server 失败，正在回滚"
      bash "$RKNN_BACKUP_DIR/restore.sh" || true
      die "RKNN 升级失败，已尝试回滚"
    fi
  fi

  ldconfig || true

  if [[ "$server_was_running" -eq 1 && -x "$dest_server" ]]; then
    info "重新拉起 rknn_server"
    nohup "$dest_server" >/dev/null 2>&1 &
  fi

  local new_line new_ver
  new_line="$(read_so_version "$dest_lib" 'librknnrt version|rknnrt version' || true)"
  new_ver="$(extract_semver "$new_line")"
  RKNN_NEW_VERSION="${new_ver:-unknown}"
  if [[ "$new_ver" != "$TARGET_RKNN_VERSION" ]]; then
    warn "替换后版本字符串: ${new_line:-<empty>}（期望含 ${TARGET_RKNN_VERSION}）"
    warn "如需回滚: $RKNN_BACKUP_DIR/restore.sh"
  else
    ok "RKNN Runtime 现为 ${new_ver}"
  fi
  RKNN_ACTION="upgraded"
  trap - RETURN
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# 2. Docker
# ---------------------------------------------------------------------------
docker_ready() {
  have_cmd docker || return 1
  docker compose version >/dev/null 2>&1
}

install_docker_official() {
  local family
  family="$(docker_family)" || return 1
  [[ -n "$OS_CODENAME" ]] || return 1

  have_cmd dpkg || return 1
  have_cmd apt-get || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg || return 1

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL "https://download.docker.com/linux/${family}/gpg" -o /etc/apt/keyrings/docker.asc || return 1
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  local arch
  arch="$(dpkg --print-architecture)"
  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${family} ${OS_CODENAME} stable
EOF
  apt-get update -y || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
}

install_docker_get() {
  info "回退到 get.docker.com"
  local script
  script="$(mktemp)"
  download "https://get.docker.com" "$script"
  sh "$script"
  rm -f "$script"
  if ! docker compose version >/dev/null 2>&1; then
    if have_cmd apt-get; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin || true
    fi
  fi
}

install_docker() {
  step "2/3" "Docker + Compose"
  if [[ "$SKIP_DOCKER" -eq 1 ]]; then
    warn "已跳过 Docker（--skip-docker）"
    return 0
  fi

  if docker_ready; then
    ok "Docker 已就绪: $(docker --version)"
    ok "Compose: $(docker compose version)"
  else
    info "安装 Docker Engine 与 Compose 插件"
    set +e
    install_docker_official
    official_rc=$?
    set -e
    if [[ "$official_rc" -ne 0 ]]; then
      warn "官方 apt 源安装失败，尝试 get.docker.com"
      install_docker_get
    fi
    docker_ready || die "Docker / Compose 安装后仍不可用"
    ok "Docker 安装完成: $(docker --version)"
  fi

  if have_cmd systemctl; then
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker || true
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    if getent group docker >/dev/null 2>&1; then
      usermod -aG docker "$SUDO_USER"
      info "已将 ${SUDO_USER} 加入 docker 组（重新登录后无需 sudo）"
    fi
  fi

  docker info >/dev/null || die "docker info 失败，daemon 未正常运行"
  DOCKER_VERSION="$(docker --version | head -1)"
  COMPOSE_VERSION="$(docker compose version | head -1)"
  ok "$DOCKER_VERSION"
  ok "$COMPOSE_VERSION"
}

# ---------------------------------------------------------------------------
# 3. compose files
# ---------------------------------------------------------------------------
copy_or_fetch() {
  local rel="$1"
  local dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/${rel}" ]]; then
    cp -f "${SCRIPT_DIR}/${rel}" "$dest"
    return 0
  fi
  info "从 GitHub 拉取 $rel"
  local base
  local -a urls=()
  for base in "${REPO_RAW_CANDIDATES[@]}"; do
    urls+=("${base}/${rel}")
  done
  try_download "$dest" "${urls[@]}"
}

choose_mqtt() {
  if [[ -n "$MQTT_MODE" ]]; then
    return 0
  fi
  local ans=""
  if prompt_read $'请选择部署变体:\n  1) 带 MQTT（eclipse-mosquitto）\n  2) 不带 MQTT\n输入 1 或 2: ' ans; then
    case "$ans" in
      1) MQTT_MODE="mqtt" ;;
      2) MQTT_MODE="no-mqtt" ;;
      *) die "无效选择: $ans" ;;
    esac
    return 0
  fi
  die "非交互模式请指定 --mqtt 或 --no-mqtt"
}

choose_start() {
  if [[ -n "$START_MODE" ]]; then
    return 0
  fi
  if confirm "现在执行 docker compose up -d ? [y/N] "; then
    START_MODE="start"
  else
    START_MODE="no-start"
  fi
}

setup_compose() {
  step "3/3" "RKNN docker-compose"
  choose_mqtt

  mkdir -p "$WORKDIR/data" "$WORKDIR/deploy"

  local src_compose dest_compose
  dest_compose="${WORKDIR}/docker-compose.yml"
  if [[ "$MQTT_MODE" == "mqtt" ]]; then
    src_compose="docker-compose.yml.rknn"
    COMPOSE_VARIANT="带 MQTT"
  else
    src_compose="docker-compose.no-mqtt.yml.rknn"
    COMPOSE_VARIANT="不带 MQTT"
  fi

  local fetched
  fetched="$(mktemp -d /tmp/cvab-compose.XXXXXX)"
  if ! copy_or_fetch "$src_compose" "${fetched}/docker-compose.yml"; then
    if [[ -z "$SCRIPT_DIR" ]] && have_cmd git; then
      info "raw 下载失败，改为 git clone（含国内镜像）"
      clone_github "${fetched}/repo" "$REPO_URL" || die "无法 clone ${REPO_URL}"
      [[ -f "${fetched}/repo/${src_compose}" ]] || die "仓库中没有 ${src_compose}（远端可能尚未推送）"
      cp -f "${fetched}/repo/${src_compose}" "${fetched}/docker-compose.yml"
      [[ -f "${fetched}/repo/mediamtx.yml" ]] && cp -f "${fetched}/repo/mediamtx.yml" "${fetched}/mediamtx.yml"
      [[ -f "${fetched}/repo/deploy/mosquitto.conf" ]] && cp -f "${fetched}/repo/deploy/mosquitto.conf" "${fetched}/mosquitto.conf"
    else
      die "无法获取 ${src_compose}。请在已 clone 的仓库里运行，或先把本仓库推到 GitHub"
    fi
  else
    copy_or_fetch "mediamtx.yml" "${fetched}/mediamtx.yml" || true
    copy_or_fetch "deploy/mosquitto.conf" "${fetched}/mosquitto.conf" || true
  fi

  [[ -s "${fetched}/docker-compose.yml" ]] || die "compose 文件为空"

  if [[ -f "$dest_compose" ]]; then
    local bak="${dest_compose}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$dest_compose" "$bak"
    info "已备份旧 compose: $bak"
  fi

  cp -f "${fetched}/docker-compose.yml" "$dest_compose"
  if [[ -f "${fetched}/mediamtx.yml" ]]; then
    cp -f "${fetched}/mediamtx.yml" "${WORKDIR}/mediamtx.yml"
  elif [[ ! -f "${WORKDIR}/mediamtx.yml" ]]; then
    die "缺少 mediamtx.yml"
  fi
  if [[ "$MQTT_MODE" == "mqtt" ]]; then
    if [[ -f "${fetched}/mosquitto.conf" ]]; then
      cp -f "${fetched}/mosquitto.conf" "${WORKDIR}/deploy/mosquitto.conf"
    elif [[ ! -f "${WORKDIR}/deploy/mosquitto.conf" ]]; then
      die "缺少 deploy/mosquitto.conf"
    fi
  fi
  rm -rf "$fetched"

  ok "工作目录: $WORKDIR"
  ok "变体: $COMPOSE_VARIANT  ($src_compose → docker-compose.yml)"

  choose_start
  if [[ "$START_MODE" == "start" ]]; then
    have_cmd docker || die "未安装 Docker，无法启动"
    info "拉取镜像并启动（ghcr.io/zuoa/video-ba-pipe:rk）"
    (
      cd "$WORKDIR"
      docker compose pull
      docker compose up -d
      docker compose ps
    )
    ok "服务已启动"
  else
    info "未启动容器。就绪后执行:"
    log "  cd ${WORKDIR} && docker compose up -d"
  fi
}

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
print_summary() {
  local ip
  ip="$(host_ip)"
  printf '\n%s======== 完成 ========%s\n' "$C_BOLD" "$C_RESET"
  log "RKNN Runtime : ${RKNN_OLD_VERSION} → ${RKNN_NEW_VERSION:-$RKNN_OLD_VERSION}  (${RKNN_ACTION})"
  [[ -n "$RKNN_BACKUP_DIR" ]] && log "RKNN 备份     : ${RKNN_BACKUP_DIR}  (回滚: sudo bash ${RKNN_BACKUP_DIR}/restore.sh)"
  log "Docker        : ${DOCKER_VERSION:-$(docker --version 2>/dev/null || echo skipped)}"
  log "Compose       : ${COMPOSE_VERSION:-$(docker compose version 2>/dev/null || echo skipped)}"
  log "部署变体      : ${COMPOSE_VARIANT}"
  log "工作目录      : ${WORKDIR}"
  log ""
  log "访问:"
  log "  前端  http://${ip}:8080"
  log "  API   http://${ip}:5002"
  log "  WebRTC http://${ip}:8889  (默认关闭，需 MEDIAMTX_ENABLED=true)"
  log ""
  log "常用命令:"
  log "  cd ${WORKDIR}"
  log "  docker compose ps"
  log "  docker compose logs -f"
  log "  docker compose down"
}

main() {
  preflight "$@"
  install_rknn
  install_docker
  setup_compose
  print_summary
}

main "$@"
