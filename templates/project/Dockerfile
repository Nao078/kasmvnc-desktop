# kasmvnc-desktop ベースイメージを使う最小例。
# タグは <distro>（可変・最新）または <distro>-<semver>（不変・固定推奨）を指定する。
FROM ghcr.io/nao078/kasmvnc-desktop:ubuntu-24.04

# 追加パッケージが必要な場合はここでインストールする（root権限）。
# USER root
# RUN apt-get update && apt-get install -y --no-install-recommends <package> \
#     && rm -rf /var/lib/apt/lists/*

# コンテナ起動時に処理を追加したい場合は /docker-entrypoint.d/ にフックスクリプトを追加する
# （root権限・辞書順・実行可能ファイルのみ実行される）。
# COPY --chmod=755 my-app-setup.sh /docker-entrypoint.d/50-my-app-setup.sh

# entrypoint.sh はrootとして起動し、VNCセットアップ後にappuserへ降格するため
# USER appuser には切り替えない（ENTRYPOINTはベースイメージのものを継承する）。
