#!/usr/bin/env bash
# Logpresso SONA standalone installer automation
# Based on: 소나 설치 가이드 (단독형) 웹 인스톨러 설치 방식 v2.0
# Target OS: Rocky Linux / RHEL 9 계열

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/logpresso_sona_install_$(date +%Y%m%d_%H%M%S).log"

INSTALL_DIR="${INSTALL_DIR:-/logpresso}"
DATA_DIR="${DATA_DIR:-/data/logpresso-data}"
PACKAGE_DIR="${PACKAGE_DIR:-/logpresso}"
RUN_USER="${RUN_USER:-logpresso}"
RUN_AS_USER="${RUN_AS_USER:-false}"
REGISTER_SYSTEMD="${REGISTER_SYSTEMD:-true}"
START_SERVICE="${START_SERVICE:-true}"
OPEN_FIREWALL="${OPEN_FIREWALL:-true}"
INSTALL_MARIADB="${INSTALL_MARIADB:-true}"
CONFIGURE_DB="${CONFIGURE_DB:-true}"
DB_ROOT_PASS="${DB_ROOT_PASS:-}"
DB_NAME="${DB_NAME:-sonar}"
DB_USER="${DB_USER:-sonar}"
DB_PASS="${DB_PASS:-}"
HEAP_SIZE="${HEAP_SIZE:-4G}"
DIRECT_MEM_SIZE="${DIRECT_MEM_SIZE:-4G}"

usage() {
  cat <<USAGE
사용법: sudo ./${SCRIPT_NAME} [옵션]

주요 전제:
  - MariaDB RPM tar.gz, JDK tar.gz, Logpresso SNR zip 파일이 기본적으로 /logpresso 에 있어야 합니다.
  - 설치 경로 기본값은 /logpresso, 데이터 경로 기본값은 /data/logpresso-data 입니다.

옵션:
  --install-dir PATH       설치 경로. 기본값: /logpresso
  --data-dir PATH          데이터 저장 경로. 기본값: /data/logpresso-data
  --package-dir PATH       설치 파일 위치. 기본값: /logpresso
  --run-user USER          일반 계정 실행 시 사용할 OS 계정. 기본값: logpresso
  --run-as-user            일반 계정 실행 설정 적용 및 해당 계정으로 서비스 시작
  --run-as-root            root 계정으로 서비스 시작. 기본값
  --db-root-pass PASS      MariaDB root 암호. 필수 (또는 환경변수 DB_ROOT_PASS)
  --db-user USER           SONA DB 계정. 기본값: sonar
  --db-pass PASS           SONA DB 계정 암호. 필수 (또는 환경변수 DB_PASS)
  --db-name NAME           SONA DB 이름. 기본값: sonar
  --heap SIZE              MIN/MAX HEAP 크기. 기본값: 4G
  --direct-mem SIZE        MAX_DIRECT_MEM_SIZE. 기본값: 4G
  --no-mariadb             MariaDB RPM 설치 생략
  --no-db-config           DB 및 계정 생성 생략
  --no-firewall            firewalld 포트 오픈 생략
  --no-systemd             systemd 서비스 등록 생략
  --no-start               설치 후 서비스 시작 생략
  -h, --help               도움말 출력

예시:
  sudo DB_ROOT_PASS='StrongRoot1!' DB_PASS='StrongSonar1!' ./install_logpresso_sona.sh
  sudo DB_ROOT_PASS='StrongRoot1!' DB_PASS='StrongSonar1!' ./install_logpresso_sona.sh --run-as-user
  sudo ./install_logpresso_sona.sh --db-root-pass 'StrongRoot1!' --db-pass 'StrongSonar1!' --package-dir /logpresso --install-dir /logpresso --data-dir /data/logpresso-data
USAGE
}

log() {
  echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE"
}

fail() {
  log "ERROR: $*"
  exit 1
}

run() {
  log "+ $*"
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "root 권한으로 실행해야 합니다. 예: sudo ./${SCRIPT_NAME}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir) INSTALL_DIR="$2"; shift 2 ;;
      --data-dir) DATA_DIR="$2"; shift 2 ;;
      --package-dir) PACKAGE_DIR="$2"; shift 2 ;;
      --run-user) RUN_USER="$2"; shift 2 ;;
      --run-as-user) RUN_AS_USER="true"; shift ;;
      --run-as-root) RUN_AS_USER="false"; shift ;;
      --db-root-pass) DB_ROOT_PASS="$2"; shift 2 ;;
      --db-user) DB_USER="$2"; shift 2 ;;
      --db-pass) DB_PASS="$2"; shift 2 ;;
      --db-name) DB_NAME="$2"; shift 2 ;;
      --heap) HEAP_SIZE="$2"; shift 2 ;;
      --direct-mem) DIRECT_MEM_SIZE="$2"; shift 2 ;;
      --no-mariadb) INSTALL_MARIADB="false"; shift ;;
      --no-db-config) CONFIGURE_DB="false"; shift ;;
      --no-firewall) OPEN_FIREWALL="false"; shift ;;
      --no-systemd) REGISTER_SYSTEMD="false"; shift ;;
      --no-start) START_SERVICE="false"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "알 수 없는 옵션입니다: $1" ;;
    esac
  done
}

find_one() {
  local pattern="$1"
  local found
  found="$(find "$PACKAGE_DIR" -maxdepth 2 -type f -name "$pattern" | sort | tail -n 1 || true)"
  [[ -n "$found" ]] || return 1
  echo "$found"
}

ensure_line_kv() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -Eq "^[[:space:]#]*${key}[[:space:]]*=" "$file"; then
    sed -ri "s|^[[:space:]#]*${key}[[:space:]]*=.*|${key}=${value}|" "$file"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$file"
  fi
}

append_once() {
  local file="$1"
  local line="$2"
  grep -Fxq "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

prepare_dirs() {
  log "설치 및 데이터 디렉터리를 준비합니다."
  mkdir -p "$INSTALL_DIR" "$DATA_DIR"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" || true
}

configure_selinux() {
  log "SELinux를 disabled/permissive로 설정합니다."
  if [[ -f /etc/selinux/config ]]; then
    sed -ri 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
  fi
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    setenforce 0 || log "setenforce 0 실행 실패 또는 불필요. 재부팅 후 disabled가 적용됩니다."
  fi
}

configure_firewall() {
  [[ "$OPEN_FIREWALL" == "true" ]] || { log "방화벽 설정을 생략합니다."; return; }
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    log "firewall-cmd가 없어 방화벽 설정을 건너뜁니다."
    return
  fi
  if ! firewall-cmd --state >/dev/null 2>&1; then
    log "firewalld가 실행 중이 아니므로 방화벽 설정을 건너뜁니다."
    return
  fi

  log "MariaDB 및 SONA 서비스 포트를 firewalld에 영구 등록합니다."
  local tcp_ports=(3306 8443 443 7140 44300 18443)
  local udp_ports=(514 162)
  for port in "${tcp_ports[@]}"; do
    firewall-cmd --permanent --add-port="${port}/tcp" | tee -a "$LOG_FILE" || true
  done
  for port in "${udp_ports[@]}"; do
    firewall-cmd --permanent --add-port="${port}/udp" | tee -a "$LOG_FILE" || true
  done
  firewall-cmd --reload | tee -a "$LOG_FILE" || true
}

install_mariadb_rpms() {
  [[ "$INSTALL_MARIADB" == "true" ]] || { log "MariaDB 설치를 생략합니다."; return; }
  if rpm -q MariaDB-server >/dev/null 2>&1 || rpm -q mariadb-server >/dev/null 2>&1; then
    log "MariaDB 서버 패키지가 이미 설치되어 있습니다. RPM 설치를 생략합니다."
  else
    local mariadb_tar mariadb_dir
    mariadb_tar="$(find_one 'MariaDB*.tar.gz' || true)"
    [[ -n "$mariadb_tar" ]] || fail "MariaDB RPM tar.gz 파일을 찾을 수 없습니다. 위치: $PACKAGE_DIR"
    log "MariaDB 패키지 압축을 해제합니다: $mariadb_tar"
    run tar -zxf "$mariadb_tar" -C "$PACKAGE_DIR"
    mariadb_dir="$(find "$PACKAGE_DIR" -maxdepth 1 -type d -name 'MariaDB*' -print -quit || true)"
    [[ -d "$mariadb_dir" ]] || fail "MariaDB RPM 압축 해제 디렉터리를 찾을 수 없습니다. $PACKAGE_DIR 에 'MariaDB*' 패턴의 디렉터리가 없습니다."
    (cd "$mariadb_dir" && run rpm -Uvh ./*.rpm --force --nodeps)
  fi

  log "MariaDB 문자셋 설정을 적용합니다."
  mkdir -p /etc/my.cnf.d
  if [[ ! -f /etc/my.cnf.d/server.cnf ]]; then
    printf '[mysqld]\n' > /etc/my.cnf.d/server.cnf
  fi
  if ! grep -q '^\\[mysqld\\]' /etc/my.cnf.d/server.cnf; then
    printf '\n[mysqld]\n' >> /etc/my.cnf.d/server.cnf
  fi
  ensure_line_kv "/etc/my.cnf.d/server.cnf" "character-set-server" "utf8"
  ensure_line_kv "/etc/my.cnf.d/server.cnf" "skip-character-set-client-handshake" ""

  log "MariaDB 서비스를 시작하고 자동 시작을 활성화합니다."
  systemctl daemon-reload || true
  systemctl enable --now mariadb 2>&1 | tee -a "$LOG_FILE" || systemctl enable --now mysql 2>&1 | tee -a "$LOG_FILE"
}

mysql_exec_root() {
  local sql_file="$1"
  if mysql -uroot < "$sql_file" >> "$LOG_FILE" 2>&1; then
    return 0
  fi
  mysql -uroot -p"$DB_ROOT_PASS" < "$sql_file" >> "$LOG_FILE" 2>&1
}

configure_mariadb_db() {
  [[ "$CONFIGURE_DB" == "true" ]] || { log "DB 생성 및 계정 설정을 생략합니다."; return; }
  command -v mysql >/dev/null 2>&1 || fail "mysql 클라이언트를 찾을 수 없습니다."

  log "SONA용 MariaDB 데이터베이스와 계정을 생성합니다."
  local sql_file
  sql_file="$(mktemp)"
  chmod 600 "$sql_file"
  cat > "$sql_file" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT USAGE ON *.* TO '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '${DB_ROOT_PASS}' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
  if ! mysql_exec_root "$sql_file"; then
    rm -f "$sql_file"
    fail "MariaDB DB/계정 설정에 실패했습니다. DB_ROOT_PASS 값을 확인하십시오. 로그: $LOG_FILE"
  fi
  rm -f "$sql_file"

  log "MariaDB root@localhost 암호를 설정합니다."
  local root_sql
  root_sql="$(mktemp)"
  chmod 600 "$root_sql"
  cat > "$root_sql" <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL
  mysql -uroot < "$root_sql" >> "$LOG_FILE" 2>&1 || mysql -uroot -p"$DB_ROOT_PASS" < "$root_sql" >> "$LOG_FILE" 2>&1 || log "root@localhost 암호 설정은 이미 적용되었거나 현재 버전 문법과 다를 수 있습니다."
  rm -f "$root_sql"
}

install_jdk() {
  local jdk_tar
  jdk_tar="$(find_one 'jdk-*.tar.gz' || true)"
  [[ -n "$jdk_tar" ]] || fail "JDK tar.gz 파일을 찾을 수 없습니다. 위치: $PACKAGE_DIR"
  log "JDK 압축을 해제합니다: $jdk_tar"
  run tar -zxf "$jdk_tar" -C "$INSTALL_DIR"

  local extracted_jdk_dir
  extracted_jdk_dir="$(find "$INSTALL_DIR" -maxdepth 1 -type d -name 'jdk-*' -print -quit || true)"
  [[ -n "$extracted_jdk_dir" ]] || fail "JDK 압축 해제 디렉터리를 찾을 수 없습니다. $INSTALL_DIR 에 'jdk-*' 패턴의 디렉터리가 없습니다."

  run ln -sfn "$(basename "$extracted_jdk_dir")" "$INSTALL_DIR/jre"
  log "JDK 심볼릭 링크 생성 완료: $INSTALL_DIR/jre -> $(basename "$extracted_jdk_dir")"
}

install_snr_package() {
  local snr_zip
  snr_zip="$(find_one 'logpresso-SNR-*.zip' || true)"
  [[ -n "$snr_zip" ]] || fail "Logpresso SNR zip 파일을 찾을 수 없습니다. 위치: $PACKAGE_DIR"
  log "SONA 패키지 압축을 해제합니다: $snr_zip"
  command -v unzip >/dev/null 2>&1 || fail "unzip 명령이 필요합니다. 'sudo yum install -y unzip' 또는 'sudo apt-get install -y unzip'으로 설치하십시오."
  run unzip -o "$snr_zip" -d "$INSTALL_DIR"
  
  # Check for the main logpresso executable after extraction
  [[ -x "$INSTALL_DIR/logpresso" ]] || fail "$INSTALL_DIR/logpresso 런처를 찾을 수 없습니다. SNR zip 구조를 확인하십시오."
}

configure_logpresso_launcher() {
  log "Logpresso config 파일을 생성하고 런처 설정을 수정합니다."
  (cd "$INSTALL_DIR" && run ./logpresso install config) || log "config가 이미 생성되었거나 런처가 비대화형 생성에 실패했을 수 있습니다. 계속 진행합니다."

  local conf="$INSTALL_DIR/etc/logpresso.conf"
  [[ -f "$conf" ]] || fail "런처 설정 파일을 찾을 수 없습니다: $conf"
  cp -a "$conf" "${conf}.bak.$(date +%Y%m%d_%H%M%S)"

  ensure_line_kv "$conf" "LOGDIR" '"$BASEDIR/log"'
  ensure_line_kv "$conf" "MIN_HEAP_SIZE" "$HEAP_SIZE"
  ensure_line_kv "$conf" "MAX_HEAP_SIZE" "$HEAP_SIZE"
  ensure_line_kv "$conf" "MAX_DIRECT_MEM_SIZE" "$DIRECT_MEM_SIZE"
  ensure_line_kv "$conf" "SSH_OPEN" '"enabled"'
  ensure_line_kv "$conf" "DATADIR" "\"$DATA_DIR\""
}

configure_run_user() {
  [[ "$RUN_AS_USER" == "true" ]] || { log "일반 계정 실행 설정을 생략합니다. root 계정 기준으로 설치합니다."; return; }
  log "일반 계정 실행 설정을 적용합니다 (매뉴얼 5-1): $RUN_USER"

  if ! id "$RUN_USER" >/dev/null 2>&1; then
    run useradd -m -s /bin/bash "$RUN_USER"
  fi

  # ulimit 설정 (매뉴얼 권고값)
  append_once /etc/security/limits.conf "$RUN_USER soft nofile 126488"
  append_once /etc/security/limits.conf "$RUN_USER hard nofile 126488"
  append_once /etc/security/limits.conf "$RUN_USER soft nproc 126488"
  append_once /etc/security/limits.conf "$RUN_USER hard nproc 126488"

  # Well-known 포트(443 등) 바인딩 및 원시 소켓 권한 부여 (매뉴얼 5-1. 1-2)
  export JAVA_HOME="$INSTALL_DIR/jre"
  if command -v setcap >/dev/null 2>&1 && [[ -x "$JAVA_HOME/bin/java" ]]; then
    run setcap cap_net_bind_service,cap_net_raw,cap_sys_time=+ep "$JAVA_HOME/bin/java" || log "setcap 적용 실패. libcap 패키지 또는 파일시스템 capability 지원 여부를 확인하십시오."
  fi

  # jemalloc 라이브러리 경로 설정
  local libjli_dir
  libjli_dir="$(find "$JAVA_HOME" -name 'libjli.so' -print -quit || true)"
  if [[ -n "$libjli_dir" ]]; then
    echo "$(dirname "$libjli_dir")" > /etc/ld.so.conf.d/java_jemalloc.conf
    run ldconfig || true
  fi

  # sudoers 설정 (매뉴얼 5-1. 3)
  cat > "/etc/sudoers.d/${RUN_USER}-logpresso" <<EOF
%${RUN_USER} ALL=(ALL) NOPASSWD: /sbin/ifconfig
%${RUN_USER} ALL=(ALL) NOPASSWD: /usr/sbin/tcpdump
%${RUN_USER} ALL=(ALL) NOPASSWD: /usr/sbin/iotop
%${RUN_USER} ALL=(ALL) NOPASSWD: /usr/sbin/lsof
%${RUN_USER} ALL=(ALL) NOPASSWD: /usr/bin/pmap
%${RUN_USER} ALL=(ALL) NOPASSWD: ${INSTALL_DIR}/jre/bin/jstack
%${RUN_USER} ALL=(ALL) NOPASSWD: ${INSTALL_DIR}/jre/bin/jmap
%${RUN_USER} ALL=(ALL) NOPASSWD: /usr/sbin/arping
Defaults:${RUN_USER} !requiretty
EOF
  chmod 440 "/etc/sudoers.d/${RUN_USER}-logpresso"
  run visudo -cf "/etc/sudoers.d/${RUN_USER}-logpresso" || fail "sudoers 설정 검증 실패"

  if command -v setfacl >/dev/null 2>&1; then
    run setfacl -m "u:${RUN_USER}:r--" /etc/hosts || true
  fi

  # 권한 변경: 설치 경로와 데이터 경로 모두 적용
  run chown -R "$RUN_USER:$RUN_USER" "$INSTALL_DIR" "$DATA_DIR"
}

configure_sysctl() {
  log "syslog UDP 커널 유실 방지 sysctl 값을 적용합니다 (매뉴얼 5-2)."
  append_once /etc/sysctl.conf "net.core.rmem_max=52428800"
  append_once /etc/sysctl.conf "net.core.rmem_default=52428800"
  append_once /etc/sysctl.conf "net.ipv4.udp_rmem_min=8192"
  append_once /etc/sysctl.conf "net.ipv4.ipfrag_high_thresh=16777216"
  run sysctl -p || log "일부 sysctl 값 적용에 실패했습니다. 커널/권한 상태를 확인하십시오."
}

register_systemd() {
  [[ "$REGISTER_SYSTEMD" == "true" ]] || { log "systemd 등록을 생략합니다."; return; }
  log "Logpresso systemd 서비스를 등록합니다."
  (cd "$INSTALL_DIR" && run ./logpresso install systemd-service) || log "런처 기반 systemd 등록이 실패했습니다. 수동 확인이 필요할 수 있습니다."
  systemctl daemon-reload || true
  systemctl enable logpresso 2>&1 | tee -a "$LOG_FILE" || log "systemctl enable logpresso 실패. 서비스 파일 생성 여부를 확인하십시오."
}

start_logpresso() {
  [[ "$START_SERVICE" == "true" ]] || { log "서비스 시작을 생략합니다."; return; }
  log "Logpresso SONA 서비스를 시작합니다."
  if [[ "$RUN_AS_USER" == "true" ]]; then
    su - "$RUN_USER" -c "cd '$INSTALL_DIR' && ./logpresso start" 2>&1 | tee -a "$LOG_FILE"
  else
    (cd "$INSTALL_DIR" && run ./logpresso start)
  fi
  sleep 3
  ps -ef | grep -v grep | grep -E 'java|logpresso' | tee -a "$LOG_FILE" || true
}

print_next_steps() {
  cat <<NEXT | tee -a "$LOG_FILE"

설치 자동화 단계가 완료되었습니다.

다음 단계는 웹 UI에서 완료해야 합니다.
  1. SONA 웹 인스톨러 접속: https://<서버IP>
  2. 클러스터 관리자 등록: root, admin, system, administrator, logpresso 계정명은 사용하지 마십시오.
  3. 인증서 암호 설정: 9자 이상, 숫자와 특수문자 포함 조건을 충족해야 합니다.
  4. DB 설정값:
     - 서버 주소: localhost
     - 포트: 3306
     - 데이터베이스: ${DB_NAME}
     - 데이터베이스 계정: ${DB_USER}
     - 데이터베이스 암호: (설치 시 지정한 값)
  5. 설치 완료 후 ENT 웹 UI 접속: https://<서버IP>:8443
     - 초기 계정/암호: root / logpresso 또는 웹 인스톨러에서 생성된 임의 암호 상태일 수 있으므로 문서 절차에 따라 변경하십시오.
  6. 필요 시 SSH 엔진 접속 후 ENT root 암호 초기화:
     ssh -p 7022 root@localhost
     초기 암호: araqne
     명령: dom.resetPassword localhost root
     이후 sonar.setMaster 및 SONA 웹 UI의 시스템 > 노드 설정에도 변경 암호를 반영하십시오.

로그 파일: ${LOG_FILE}
NEXT
}

main() {
  parse_args "$@"
  require_root
  if [[ "$CONFIGURE_DB" == "true" && ( -z "$DB_ROOT_PASS" || -z "$DB_PASS" ) ]]; then
    fail "DB 암호를 지정하십시오: --db-root-pass, --db-pass 또는 환경변수 DB_ROOT_PASS, DB_PASS"
  fi
  prepare_dirs

  log "Logpresso SONA 설치 자동화를 시작합니다."
  log "INSTALL_DIR=$INSTALL_DIR, DATA_DIR=$DATA_DIR, PACKAGE_DIR=$PACKAGE_DIR, RUN_AS_USER=$RUN_AS_USER"

  configure_selinux
  configure_firewall
  install_mariadb_rpms
  configure_mariadb_db
  install_jdk
  install_snr_package
  configure_logpresso_launcher
  configure_run_user
  configure_sysctl
  register_systemd
  start_logpresso
  print_next_steps
}

main "$@"
