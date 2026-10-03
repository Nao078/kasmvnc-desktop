#!/bin/bash
# distro非依存のスモークテスト。
#
# Usage:
#   tests/smoke.sh <image-ref>       既存イメージを直接テストする
#   tests/smoke.sh <distro-name>     distros/<distro-name>.env を使って docker/ からビルドしてテストする
#
# 環境変数:
#   EXPECTED_UID / EXPECTED_GID  appuserの期待UID/GID（既定 1000）
#   SMOKE_PORT                   ホスト側の一時公開ポート（既定 18543）
#   KEEP_IMAGE=true              distro指定でビルドしたイメージをテスト後も残す
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tests/smoke.sh <image-ref>|<distro-name>
EOF
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
readonly target="$1"
readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly distro_env="${repo_root}/distros/${target}.env"

image=""
built_image=false
if [[ -f "${distro_env}" ]]; then
  image="kasmvnc-desktop-smoke:${target}"
  echo "==> Building ${image} from distros/${target}.env"
  set -a
  # shellcheck disable=SC1090
  source "${distro_env}"
  set +a
  docker build \
    --build-arg "BASE_IMAGE=${BASE_IMAGE:?BASE_IMAGE missing in ${distro_env}}" \
    --build-arg "KASMVNC_VERSION=${KASMVNC_VERSION:?KASMVNC_VERSION missing in ${distro_env}}" \
    --build-arg "KASMVNC_CODENAME=${KASMVNC_CODENAME:?KASMVNC_CODENAME missing in ${distro_env}}" \
    --build-arg "KASMVNC_SHA256=${KASMVNC_SHA256:?KASMVNC_SHA256 missing in ${distro_env}}" \
    -t "${image}" "${repo_root}/docker"
  built_image=true
else
  image="${target}"
fi

readonly EXPECTED_UID="${EXPECTED_UID:-1000}"
readonly EXPECTED_GID="${EXPECTED_GID:-1000}"
readonly host_port="${SMOKE_PORT:-18543}"
readonly container="kasmvnc-smoke-$$"
readonly vnc_pass="smoke-test-$$-$(date +%s)"

readonly hook_dir="$(mktemp -d)"
readonly hook_marker_name="smoke-hook-ran"
cat > "${hook_dir}/50-smoke-hook.sh" <<EOF
#!/bin/sh
touch "/tmp/${hook_marker_name}"
EOF
chmod 755 "${hook_dir}/50-smoke-hook.sh"

failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }
pass() { echo "PASS: $1"; }

cleanup() {
  docker rm -f "${container}" >/dev/null 2>&1 || true
  rm -rf "${hook_dir}"
  if [[ "${built_image}" == true && "${KEEP_IMAGE:-false}" != true ]]; then
    docker rmi "${image}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "==> Starting ${container} from ${image}"
docker run -d --name "${container}" \
  --init \
  -e "VNC_PASS=${vnc_pass}" \
  -p "127.0.0.1:${host_port}:8443" \
  -v "${hook_dir}/50-smoke-hook.sh:/docker-entrypoint.d/50-smoke-hook.sh:ro" \
  "${image}" >/dev/null

# 1. healthcheck healthy（もしくは 127.0.0.1:8443 が 200/401）
echo "==> Waiting for healthcheck"
status=""
healthy=false
for _ in $(seq 1 30); do
  status="$(docker inspect --format='{{.State.Health.Status}}' "${container}" 2>/dev/null || echo "")"
  [[ "${status}" == "healthy" ]] && { healthy=true; break; }
  sleep 2
done
if [[ "${healthy}" == true ]]; then
  pass "healthcheck became healthy"
else
  http_status="$(curl -k -s -o /dev/null -w '%{http_code}' "https://127.0.0.1:${host_port}/" || echo "000")"
  if [[ "${http_status}" == "200" || "${http_status}" == "401" ]]; then
    pass "endpoint responded ${http_status} (healthcheck status was '${status:-unknown}')"
  else
    fail "endpoint did not respond 200/401 (got '${http_status}', healthcheck status '${status:-unknown}')"
  fi
fi

# 2. locale が ja_JP.UTF-8
echo "==> Checking locale"
locale_out="$(docker exec "${container}" bash -c 'locale | grep ^LANG=' || true)"
if [[ "${locale_out}" == "LANG=ja_JP.UTF-8" ]]; then
  pass "locale is ja_JP.UTF-8"
else
  fail "unexpected locale: '${locale_out}'"
fi

# 3. 日本語フォントが入っている
echo "==> Checking Japanese fonts"
ja_fonts="$(docker exec "${container}" bash -c 'fc-list :lang=ja' || true)"
if [[ -n "${ja_fonts}" ]]; then
  pass "Japanese fonts installed ($(echo "${ja_fonts}" | wc -l | tr -d ' ') matches)"
else
  fail "no Japanese fonts found via fc-list :lang=ja"
fi

# 4. 実行ユーザーのUID/GIDが期待値どおり
echo "==> Checking appuser UID/GID"
id_out="$(docker exec "${container}" id appuser 2>&1 || true)"
if echo "${id_out}" | grep -q "uid=${EXPECTED_UID}(appuser) gid=${EXPECTED_GID}(appuser)"; then
  pass "appuser is uid=${EXPECTED_UID} gid=${EXPECTED_GID}"
else
  fail "unexpected id: '${id_out}' (expected uid=${EXPECTED_UID} gid=${EXPECTED_GID})"
fi

# 5. /docker-entrypoint.d の拡張フックが実行される
echo "==> Checking /docker-entrypoint.d hook execution"
if docker exec "${container}" test -f "/tmp/${hook_marker_name}"; then
  pass "docker-entrypoint.d hook executed"
else
  fail "docker-entrypoint.d hook did not run (marker file missing)"
fi

# 6. SIGTERMでコンテナが猶予時間内に停止する
echo "==> Checking SIGTERM stops the container within the grace period"
start_ts=$(date +%s)
docker kill --signal=TERM "${container}" >/dev/null
stopped=false
for _ in $(seq 1 20); do
  running="$(docker inspect --format='{{.State.Running}}' "${container}" 2>/dev/null || echo false)"
  [[ "${running}" != "true" ]] && { stopped=true; break; }
  sleep 1
done
elapsed=$(( $(date +%s) - start_ts ))
if [[ "${stopped}" == true ]]; then
  pass "container stopped ${elapsed}s after SIGTERM"
else
  fail "container did not stop within 20s of SIGTERM"
fi

# 7. VNC_PASS未指定: 初回は乱数のパスワードをログへ出してそれでログインでき、再起動しても維持される
echo "==> Checking VNC_PASS-less startup (generated password, kept across restart)"
readonly nopass_container="${container}-nopass"
docker run -d --name "${nopass_container}" --init -p "127.0.0.1:${host_port}:8443" "${image}" >/dev/null
nopass_cleanup() { docker rm -f "${nopass_container}" >/dev/null 2>&1 || true; }
trap 'nopass_cleanup; cleanup' EXIT
http_code() { curl -k -s -o /dev/null -w '%{http_code}' -u "$1:$2" "https://127.0.0.1:${host_port}/" || echo 000; }
generated_pass=""
for _ in $(seq 1 30); do
  generated_pass="$(docker logs "${nopass_container}" 2>&1 | sed -n 's/^entrypoint: initial VNC login: user=[^ ]* password=//p' | head -1)"
  [[ -n "${generated_pass}" ]] && break
  sleep 1
done
if [[ -z "${generated_pass}" ]]; then
  fail "no generated password in the log"
else
  sleep 8
  [[ "$(http_code desktop "${generated_pass}")" == "200" ]] \
    && pass "generated password logs in" || fail "generated password was rejected"
  docker restart "${nopass_container}" >/dev/null
  sleep 12
  if [[ "$(http_code desktop "${generated_pass}")" == "200" ]] \
     && [[ "$(docker logs --since 10s "${nopass_container}" 2>&1 | grep -c 'initial VNC login')" == "0" ]]; then
    pass "password kept across restart (no new password generated)"
  else
    fail "password was not kept across restart"
  fi
fi

echo
if [[ ${failures} -eq 0 ]]; then
  echo "All smoke checks passed."
  exit 0
else
  echo "${failures} smoke check(s) failed."
  exit 1
fi
