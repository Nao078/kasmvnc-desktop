#!/bin/bash
set -euo pipefail

readonly APP_USER="${APP_USER:-appuser}"
readonly APP_HOME="/home/${APP_USER}"
readonly VNC_LOGIN_USER="${VNC_LOGIN_USER:-desktop}"
readonly VNC_PASS="${VNC_PASS:-}"
readonly VNC_GEOMETRY="${VNC_GEOMETRY:-1920x1080}"
readonly VNC_DEPTH="${VNC_DEPTH:-24}"
readonly VNC_DISPLAY="${VNC_DISPLAY:-:1}"
readonly KASMVNC_TEMPLATE="/opt/kasmvnc/config/kasmvnc.yaml.template"
readonly HOOK_DIR="/docker-entrypoint.d"

validate_display() {
  # 削除するX lock/socketを単一displayへ限定するため、数値displayだけを許可する。
  [[ "${VNC_DISPLAY}" =~ ^:[0-9]+$ ]]
}

validate_geometry() {
  # 異常な画面サイズによるKasmVNCの過剰なメモリ消費を起動前に防ぐ。
  [[ "${VNC_GEOMETRY}" =~ ^([0-9]+)x([0-9]+)$ ]] || return 1
  local width="${BASH_REMATCH[1]}"
  local height="${BASH_REMATCH[2]}"
  (( width >= 800 && width <= 7680 && height >= 600 && height <= 4320 )) || return 1
  [[ "${VNC_DEPTH}" =~ ^(16|24|32)$ ]]
}

setup_vnc_password() {
  # VNC_PASSの指定あり: 従来どおり起動のたびに.kasmpasswdを作り直す。
  # 指定なし: 既存の.kasmpasswdがあれば維持する（パスワードの変更はkasmvncpasswdで行い、
  #           /home/appuserのvolumeに残る。KasmVNCは再起動なしで読み直す）。
  #           無ければ乱数のパスワードを作り、初回の1回だけログへ出す。
  local pass="${VNC_PASS}" generated=0
  if [[ -z "${pass}" ]]; then
    [[ -s "${APP_HOME}/.kasmpasswd" ]] && return 0
    pass="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
    generated=1
  fi
  printf '%s\n%s\n' "${pass}" "${pass}" \
    | gosu "${APP_USER}" kasmvncpasswd -u "${VNC_LOGIN_USER}" -w "${APP_HOME}/.kasmpasswd"
  chown "${APP_USER}:${APP_USER}" "${APP_HOME}/.kasmpasswd"
  chmod 600 "${APP_HOME}/.kasmpasswd"
  if (( generated )); then
    echo "entrypoint: initial VNC login: user=${VNC_LOGIN_USER} password=${pass}"
    echo "entrypoint: change it after logging in (kasmvncpasswd -u ${VNC_LOGIN_USER} -w ~/.kasmpasswd)"
  fi
}

run_hooks() {
  # 利用側プロジェクトがこのベースを変更せずに処理を追加できる拡張ポイント。
  # nginx公式イメージのdocker-entrypoint.dと同じ流儀（root権限・辞書順・実行可能ファイルのみ）。
  [[ -d "${HOOK_DIR}" ]] || return 0
  local hook
  for hook in "${HOOK_DIR}"/*.sh; do
    [[ -e "${hook}" ]] || continue
    if [[ -x "${hook}" ]]; then
      echo "entrypoint: running ${hook}"
      "${hook}"
    else
      echo "entrypoint: skipping non-executable ${hook}" >&2
    fi
  done
}

validate_display || { echo "Unsupported VNC_DISPLAY" >&2; exit 1; }
validate_geometry || { echo "Unsupported VNC geometry/depth" >&2; exit 1; }

display_number="${VNC_DISPLAY#:}"
rm -f "/tmp/.X${display_number}-lock" "/tmp/.X11-unix/X${display_number}"

mkdir -p "${APP_HOME}/.vnc"
chown -R "${APP_USER}:${APP_USER}" "${APP_HOME}/.vnc"

width="${VNC_GEOMETRY%x*}"
height="${VNC_GEOMETRY#*x}"
sed -e "s/__VNC_WIDTH__/${width}/g" \
    -e "s/__VNC_HEIGHT__/${height}/g" \
    -e "s/__VNC_DEPTH__/${VNC_DEPTH}/g" \
    "${KASMVNC_TEMPLATE}" > "${APP_HOME}/.vnc/kasmvnc.yaml"
chown "${APP_USER}:${APP_USER}" "${APP_HOME}/.vnc/kasmvnc.yaml"
chmod 600 "${APP_HOME}/.vnc/kasmvnc.yaml"

setup_vnc_password

run_hooks

gosu "${APP_USER}" env HOME="${APP_HOME}" DISPLAY="${VNC_DISPLAY}" LANG="${LANG}" LC_ALL="${LC_ALL}" TZ="${TZ}" \
  kasmvncserver "${VNC_DISPLAY}" -geometry "${VNC_GEOMETRY}" -depth "${VNC_DEPTH}" \
  -xstartup "${APP_HOME}/.vnc/xstartup" -fg &
vnc_pid=$!

# kasmvncserverラッパー(perl)はSIGTERMハンドラを持たず、直接送っても終了しない
# （実機確認済み）。ラッパー自身が案内する正規の停止手順`-kill`を使う。
shutdown() {
  echo "entrypoint: received stop signal, running kasmvncserver -kill ${VNC_DISPLAY}"
  gosu "${APP_USER}" env HOME="${APP_HOME}" kasmvncserver -kill "${VNC_DISPLAY}" || true
  wait "${vnc_pid}" 2>/dev/null || true
  exit 0
}
trap shutdown SIGTERM SIGINT

wait "${vnc_pid}"
