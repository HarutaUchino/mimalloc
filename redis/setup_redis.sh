#!/usr/bin/env bash

# mimalloc-benchリポジトリのRedisビルド手順を再現するスクリプト
# 使い方: ./setup_redis.sh

# エラーが発生したら即座にスクリプトを終了する
set -e

# --- 設定項目 ---

# mimalloc-benchで指定されているRedisのバージョン
readonly REDIS_VERSION="6.2.7"

# Redisのソースコード等をダウンロード・展開する作業ディレクトリ
readonly WORK_DIR="$HOME/redis_source_build"

# --- スクリプト本体 ---

echo "=== Redis ${REDIS_VERSION} のセットアップを開始します ==="
echo "作業ディレクトリ: ${WORK_DIR}"
echo

# 1. 必要なビルドツールの確認とインストール (Ubuntu/Debian系)
# Cコンパイラ(gcc)やmakeコマンドが必要です
echo "1. 必要なパッケージ (build-essential, tcl, curl) を確認しています..."
sudo apt-get update
sudo apt-get install -y build-essential tcl curl
echo

# 2. 作業ディレクトリの作成
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 3. Redisソースコードのダウンロード
SOURCE_ARCHIVE="redis-${REDIS_VERSION}.tar.gz"
DOWNLOAD_URL="http://download.redis.io/releases/${SOURCE_ARCHIVE}"

if [ ! -f "$SOURCE_ARCHIVE" ]; then
  echo "2. Redis ${REDIS_VERSION} のソースコードをダウンロードします..."
  curl -L -O "$DOWNLOAD_URL"
else
  echo "2. Redisのソースコードアーカイブは既に存在します。ダウンロードをスキップします。"
fi
echo

# 4. ソースコードの展開
SOURCE_DIR="redis-${REDIS_VERSION}"
if [ ! -d "$SOURCE_DIR" ]; then
  echo "3. アーカイブを展開します..."
  tar xzf "$SOURCE_ARCHIVE"
else
  echo "3. ソースディレクトリは既に存在します。展開をスキップします。"
fi
echo

# 5. Redisのビルド
cd "$SOURCE_DIR"
echo "4. Redisをビルドします (make)..."
# MALLOC=libc を指定するのは、ビルド時にjemallocをリンクしないようにするため。
# これにより、後からLD_PRELOADで任意のアロケータを差し替えやすくなる。
make MALLOC=libc
echo

# --- 完了 ---
echo "✅ Redisのビルドが完了しました。"
echo
echo "実行ファイルは以下の場所にあります:"
echo "  サーバー:     $(pwd)/src/redis-server"
echo "  ベンチマーク: $(pwd)/src/redis-benchmark"
echo "  CLI:          $(pwd)/src/redis-cli"
echo