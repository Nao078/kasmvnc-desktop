ARG BASE_IMAGE=ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3
FROM ${BASE_IMAGE}

ARG APP_USER=appuser
ARG APP_UID=1000
ARG APP_GID=1000
ARG ENABLE_SUDO=true

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=ja_JP.UTF-8 \
    LC_ALL=ja_JP.UTF-8 \
    LANGUAGE=ja_JP:ja \
    TZ=Asia/Tokyo \
    APP_USER=${APP_USER} \
    HOME=/home/${APP_USER} \
    DISPLAY=:1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       bash ca-certificates curl dbus-x11 fonts-ipafont-gothic fonts-ipafont-mincho \
       fonts-noto-cjk fonts-noto-core fonts-noto-ui-core fonts-vlgothic gosu gnupg \
       locales procps ssl-cert sudo tzdata wget x11-xkb-utils x11-xserver-utils xauth \
       xkb-data xfce4 xfce4-terminal \
    && ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime \
    && echo "Asia/Tokyo" > /etc/timezone \
    && echo "ja_JP.UTF-8 UTF-8" > /etc/locale.gen \
    && locale-gen ja_JP.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

RUN make-ssl-cert generate-default-snakeoil --force-overwrite \
    && chmod 755 /etc/ssl/private \
    && chmod 640 /etc/ssl/private/ssl-cert-snakeoil.key \
    && chmod 644 /etc/ssl/certs/ssl-cert-snakeoil.pem

ARG KASMVNC_VERSION=1.5.0
ARG KASMVNC_CODENAME=noble
ARG KASMVNC_SHA256=f599fe02e2175b9817b6165f74a5d2bebdc73118dde9181ba3410963bed7ae1e
RUN wget "https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/kasmvncserver_${KASMVNC_CODENAME}_${KASMVNC_VERSION}_amd64.deb" -O /tmp/kasmvnc.deb \
    && echo "${KASMVNC_SHA256}  /tmp/kasmvnc.deb" | sha256sum -c - \
    && apt-get update \
    && apt-get install -y /tmp/kasmvnc.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/kasmvnc.deb

# ベースイメージが既定でAPP_UID/APP_GIDと同じID(例: ubuntu:24.04の`ubuntu`ユーザー)を
# 使用済みの場合があるため、全ディストリで同一UID/GIDを保証するために先に削除する。
RUN if getent passwd "${APP_UID}" >/dev/null 2>&1; then \
      userdel -f "$(getent passwd "${APP_UID}" | cut -d: -f1)"; \
    fi \
    && if getent group "${APP_GID}" >/dev/null 2>&1; then \
      groupdel "$(getent group "${APP_GID}" | cut -d: -f1)" || true; \
    fi \
    && groupadd -g "${APP_GID}" "${APP_USER}" \
    && useradd -m -u "${APP_UID}" -g "${APP_GID}" -s /bin/bash "${APP_USER}" \
    && usermod -aG ssl-cert "${APP_USER}" \
    && mkdir -p "/home/${APP_USER}/.vnc" "/home/${APP_USER}/Desktop" /opt/kasmvnc/config /docker-entrypoint.d \
    && if [ "${ENABLE_SUDO}" = "true" ]; then \
      printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${APP_USER}" > "/etc/sudoers.d/${APP_USER}" \
      && chmod 440 "/etc/sudoers.d/${APP_USER}"; \
    fi \
    && chown -R "${APP_USER}:${APP_USER}" "/home/${APP_USER}"

COPY --chown=${APP_USER}:${APP_USER} xstartup /home/${APP_USER}/.vnc/xstartup
COPY --chown=${APP_USER}:${APP_USER} kasmvnc.yaml /opt/kasmvnc/config/kasmvnc.yaml.template
COPY entrypoint.sh /entrypoint.sh

RUN chmod 755 /entrypoint.sh "/home/${APP_USER}/.vnc/xstartup" \
    && chmod 644 /opt/kasmvnc/config/kasmvnc.yaml.template \
    && chmod 755 /docker-entrypoint.d

EXPOSE 8443
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=6 \
    CMD status="$(curl --insecure --silent --output /dev/null --write-out '%{http_code}' https://127.0.0.1:8443/)"; \
        test "${status}" = "200" || test "${status}" = "401"
ENTRYPOINT ["/entrypoint.sh"]
