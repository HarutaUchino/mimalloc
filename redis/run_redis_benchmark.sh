#!/usr/bin/env bash

# 複数のメモリアロケータをテストするためのRedisベンチマークスクリプト
# 使い方:
# 1. 下の「ユーザ設定」の ALLOCATORS 配列を編集する
# 2. chmod +x run_redis_benchmark_multi.sh
# 3. ./run_redis_benchmark_multi.sh

# --- スクリプト設定 ---
set -x
set -euo pipefail

# --- ユーザ設定 (ここを編集して様々なアロケータをテストします) ---

# 1. Redisの実行ファイルがあるディレクトリのパス
REDIS_SRC_DIR="/home/uchino/software/mimalloc/redis/redis_source_build/redis-6.2.7/src"

# 2. 結果を出力する親ディレクトリ
OUT_DIR_BASE="./redis_bench_results"

# 3. テストしたいアロケータのリストを定義
# フォーマット: "ラベル|ライブラリへの絶対パス|exportする環境変数"
ALLOCATORS=(
#   "system|system|"
#   "mimalloc|/home/uchino/software/mimalloc/out/release/libmimalloc.so.3.1|"
  "mi_PAGEMAP|/home/uchino/software/mimalloc/out/pagemap_commit_1/libmimalloc.so.3.1|"
)
# --------------------------------------------------------------------


# --- スクリプト本体 (ここから下は変更不要) ---

# メモリ使用量を取得する関数
get_memory_stats() {
  local pid=$1
  local label=$2
  local stage=$3

  if [ ! -f "/proc/$pid/status" ]; then
    echo "Process $pid not found, skipping memory stats"
    return
  fi

  local vmsize_kb=$(grep "^VmSize:" /proc/$pid/status | awk '{print $2}')
  local vmrss_kb=$(grep "^VmRSS:" /proc/$pid/status | awk '{print $2}')
  local vmpeak_kb=$(grep "^VmPeak:" /proc/$pid/status | awk '{print $2}')
  local vmhwm_kb=$(grep "^VmHWM:" /proc/$pid/status | awk '{print $2}')

  # kBからMBに変換 (1024で割る)
  local vmsize_mb=$(echo "scale=2; ${vmsize_kb:-0}/1024" | bc -l)
  local vmrss_mb=$(echo "scale=2; ${vmrss_kb:-0}/1024" | bc -l)
  local vmpeak_mb=$(echo "scale=2; ${vmpeak_kb:-0}/1024" | bc -l)
  local vmhwm_mb=$(echo "scale=2; ${vmhwm_kb:-0}/1024" | bc -l)

  echo "--- Memory Stats for $label ($stage) ---"
  echo "VmSize: ${vmsize_mb:-N/A} MB"
  echo "VmRSS:  ${vmrss_mb:-N/A} MB"
  echo "VmPeak: ${vmpeak_mb:-N/A} MB"
  echo "VmHWM:  ${vmhwm_mb:-N/A} MB"
  echo "----------------------------------------"

  # CSVファイルにも記録 (MB単位)
  echo "$label,$stage,$vmsize_mb,$vmrss_mb,$vmpeak_mb,$vmhwm_mb" >> memory-stats.csv
}

# 各アロケータについてループ処理
for allocator_info in "${ALLOCATORS[@]}"; do
( # <--- 安全のために各テストをサブシェルで実行

  # 区切り文字'|'で設定を分割
  IFS='|' read -r label lib_path export_vars <<< "$allocator_info"

  # exportが必要な場合は実行
  if [ -n "$export_vars" ]; then
    export $export_vars
  fi
  
  OUT_DIR="$OUT_DIR_BASE/$label"
  mkdir -p "$OUT_DIR"
  cd "$OUT_DIR"

  # メモリ統計用CSVファイルのヘッダーを作成
  echo "allocator,stage,vmsize_mb,vmrss_mb,vmpeak_mb,vmhwm_mb" > memory-stats.csv

  echo "================================================="
  echo " Benchmarking Allocator: $label"
  echo "================================================="

  # 1. Redisサーバーを起動
  echo "1. Starting Redis Server with $label..."
  SERVER_LOG="redis-server-output.txt"
  
  if [[ "$lib_path" != "system" ]]; then
    LD_PRELOAD="$lib_path" "$REDIS_SRC_DIR/redis-server" > "$SERVER_LOG" 2>&1 &
  else
    "$REDIS_SRC_DIR/redis-server" > "$SERVER_LOG" 2>&1 &
  fi
  SERVER_PID=$!
  sleep 1

  # Redis起動直後のメモリ使用量を記録
  get_memory_stats $SERVER_PID "$label" "after_startup"

  # 2. データベースをクリア
  "$REDIS_SRC_DIR/redis-cli" flushall
  sleep 1

  # 3. ベンチマーク実行 (CSV形式)
  # -r 1000000 -n 100000 -P 16 -t lpush,lrange --csv > "$CSV_OUT_FILE"
  CSV_OUT_FILE="benchmark-result.csv"

  # ベンチマーク開始前のメモリ使用量を記録
  get_memory_stats $SERVER_PID "$label" "before_benchmark"

  "$REDIS_SRC_DIR/redis-benchmark" -n 1000000 -c 50 -P 16 -t lpush,lrange --csv > "$CSV_OUT_FILE"

  # ベンチマーク終了後のメモリ使用量を記録
  get_memory_stats $SERVER_PID "$label" "after_benchmark"

  # 4. データベースを再度クリア
  "$REDIS_SRC_DIR/redis-cli" flushall
  sleep 1

  # 5. Redisサーバーをシャットダウン
  # シャットダウン前の最終メモリ使用量を記録
  get_memory_stats $SERVER_PID "$label" "before_shutdown"

  "$REDIS_SRC_DIR/redis-cli" shutdown
  sleep 1
  wait $SERVER_PID 2>/dev/null || true

  # --- 結果表示 ---
  echo
  echo "--- Benchmark Result for $label (CSV) ---"
  cat "$CSV_OUT_FILE"
  echo "-------------------------------------------"

  THROUGHPUT=$(grep '^"LPUSH",' "$CSV_OUT_FILE" | awk -F',' '{print $2}' | tr -d '"')

  echo "--- Throughput for $label (requests per second) ---"
  echo $THROUGHPUT
  echo "-------------------------------------------------------"

  echo
  echo "--- Memory Statistics Summary for $label ---"
  cat memory-stats.csv
  echo "--------------------------------------------"
  echo
  
  # 親ディレクトリに戻る
  cd ../..

) # <--- サブシェルが終了し、exportした変数は自動的にリセットされる
done

set +x
echo "✅ All benchmarks completed."