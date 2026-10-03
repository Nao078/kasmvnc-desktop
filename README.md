# kasmvnc-desktop

Ubuntu / Debian + XFCE デスクトップを [KasmVNC](https://github.com/kasmtech/KasmVNC) 経由でブラウザから使うための、他プロジェクトが `FROM` して使う共通ベースイメージ。

単一のDockerfileと、ディストリごとの設定ファイル(`distros/*.env`)で複数ディストリをビルド・配布する。ディストリごとにDockerfileを複製する方式は採らない。

Wine/MT5など特定用途の要素はベースに含めない（もとは `ukanomitama-trader.v1` のWine/MT5実行環境から、Linux+KasmVNC+デスクトップ部分のみを切り出したもの）。

## 対応ディストリとタグ

| ディストリ | ステータス | 可変タグ(最新) | 固定タグ(推奨) |
| --- | --- | --- | --- |
| Ubuntu 24.04 (noble) | 対応 | `ghcr.io/nao078/kasmvnc-desktop:ubuntu-24.04` | `ghcr.io/nao078/kasmvnc-desktop:ubuntu-24.04-<semver>` |
| Debian 12 (bookworm) | 未対応（Phase 2で追加予定） | - | - |

`<semver>` はKasmVNCのバージョンではなく、この `kasmvnc-desktop` 自体のリリースバージョン（gitタグ `v<semver>`）を指す。`latest` タグは提供しない。常用するプロジェクトは固定タグを使うこと。

## 利用側プロジェクトでの使い方

`templates/project/` に最小構成の雛形がある。

```dockerfile
# Dockerfile
FROM ghcr.io/nao078/kasmvnc-desktop:ubuntu-24.04-<semver>

# 追加パッケージが必要な場合（root権限）
# RUN apt-get update && apt-get install -y --no-install-recommends <package> \
#     && rm -rf /var/lib/apt/lists/*

# 起動時に処理を追加したい場合は /docker-entrypoint.d/ にフックを追加する
# （root権限・辞書順・実行可能ファイルのみ実行される。ベースイメージ自体は変更しない）
# COPY --chmod=755 setup.sh /docker-entrypoint.d/50-setup.sh
```

```bash
cp templates/project/.env.example .env
# 必要なら .env を編集する（VNC_PASS を空のままにすると、初回に乱数のパスワードがログへ出る）

docker compose -f templates/project/compose.yml up -d --build
```

ブラウザで `https://127.0.0.1:8443` にアクセスし、`VNC_LOGIN_USER`（既定 `desktop`）と `VNC_PASS` でログインする。`VNC_PASS` を指定していない場合は、初回起動時のログ（`docker compose logs`）に出るパスワードでログインし、VNCデスクトップ上の`kasmvncpasswd`で変更する（変更は再起動なしで反映され、volumeに残る）。自己署名証明書のため初回接続時はブラウザの警告を許可する。

## このリポジトリ自体の動作確認

```bash
cp .env.example .env
# VNC_PASS を編集する

docker compose --env-file .env --env-file distros/ubuntu-24.04.env up -d --build
```

`--env-file` は複数指定でき、後から指定したファイルが同名キーを上書きする（Docker Compose v2.24+で確認）。`distros/*.env` を差し替えるだけでビルド対象ディストリを切り替えられる。

## 主なビルド引数・環境変数

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `BASE_IMAGE` | (distros/*.envで指定) | `tag@sha256:...` 形式で固定する |
| `KASMVNC_VERSION` / `KASMVNC_CODENAME` / `KASMVNC_SHA256` | (distros/*.envで指定) | KasmVNCの `.deb` のバージョン・コードネーム・SHA256 |
| `APP_USER` / `APP_UID` / `APP_GID` | `appuser` / `1000` / `1000` | コンテナ内ユーザー。全ディストリで同一UID/GIDになるよう、ベースイメージの既定ユーザー（例: `ubuntu:24.04`の`ubuntu`ユーザー）と衝突する場合は削除してから作成する |
| `ENABLE_SUDO` | `true` | `appuser`にNOPASSWDのsudoを与えるか。**常用時は`false`を推奨** |
| `VNC_PASS` | (空) | KasmVNC接続パスワード。指定すると起動のたびにこの値へ設定し直す。空なら初回に乱数を作ってログへ出し、以後は`~/.kasmpasswd`を維持する（`/home/appuser`をvolumeにしていない場合は、コンテナを作り直すたびに新しく作る） |
| `VNC_LOGIN_USER` | `desktop` | ログインユーザー名 |
| `VNC_GEOMETRY` / `VNC_DEPTH` | `1920x1080` / `24` | 画面解像度・色深度 |
| `VNC_PORT` / `VNC_BIND_ADDRESS` | `8443` / `127.0.0.1` | ホスト側の公開ポート・バインドアドレス |

## 起動・停止の仕組み

- `docker/entrypoint.sh` はrootで起動し、KasmVNCの設定・パスワードを準備した後、`/docker-entrypoint.d/*.sh`（存在すれば辞書順・実行可能ファイルのみ）を実行し、最後に`gosu`で`appuser`として`kasmvncserver`をバックグラウンド起動してPID1として`wait`する。
- `kasmvncserver`（KasmVNC付属のperlラッパー）は`SIGTERM`ハンドラを持たず、直接送っても終了しないことを確認している。そのため`entrypoint.sh`は`SIGTERM`/`SIGINT`をtrapし、ラッパー自身が案内する正規の停止コマンド`kasmvncserver -kill <display>`を実行して終了させる。
- ゾンビプロセス回収とシグナル転送は、イメージに`tini`等を組み込む代わりに、compose側の`init: true`（Docker組み込みのtini相当機能）に任せる方針。このリポジトリの`compose.yml`と`templates/project/compose.yml`の両方で設定済み。利用側で`docker run`する場合は`--init`を付けること。

## ディストリを追加する手順

1. `distros/<name>.env` を作成する。`BASE_IMAGE`はdigest固定（`docker pull <image> && docker inspect <image> --format='{{index .RepoDigests 0}}'`で取得）。
2. 対象ディストリのコードネーム向けKasmVNC `.deb` が [GitHub Releases](https://github.com/kasmtech/KasmVNC/releases) に実在するか確認する。KasmVNCは公式チェックサムを公開していないため、実際にダウンロードして`sha256sum`で計算した値を`KASMVNC_SHA256`に設定する（推測・流用は禁止）。
3. `docker build --build-arg ...` で実際にビルドが通ることを確認する。パッケージ名の差異が出た場合のみ `docker/scripts/setup-<family>.sh` を追加し、Dockerfileから`DISTRO_FAMILY`で分岐して呼ぶ（差異がなければ追加しない）。
4. `tests/smoke.sh <name>` を通す。
5. `.github/workflows/build.yml` の `matrix.distro` に追加する。

## セキュリティ方針

- ポートは既定で `127.0.0.1` にのみバインドする。インターネットに直接公開せず、SSHトンネルやプライベートネットワーク経由で接続する。
- 常用環境では `ENABLE_SUDO=false` でビルドし、コンテナ内でのroot昇格を無効化することを推奨する。
- `--privileged` やDocker socketのマウント (`/var/run/docker.sock`) は行わない。
- ベースイメージ・KasmVNCの `.deb` はいずれもタグ/バージョン+ハッシュで固定し、`latest`相当の可変参照は使わない。

## ディレクトリ構成

```
docker/
  Dockerfile      # 共通Dockerfile（BASE_IMAGE等をARGで受ける）
  entrypoint.sh   # VNCサーバー初期化・起動・SIGTERM対応
  xstartup        # VNCセッション開始時に呼ばれるXFCE起動スクリプト
  kasmvnc.yaml    # KasmVNC設定テンプレート
distros/
  ubuntu-24.04.env  # Ubuntu 24.04向けビルド設定
compose.yml         # このリポジトリ自体の動作確認用（distro切替可）
.env.example        # ランタイム変数のサンプル
templates/project/  # 利用側プロジェクトの雛形
tests/smoke.sh       # スモークテスト
.github/workflows/build.yml  # CI（ビルド・テスト・GHCR push）
```
