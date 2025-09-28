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

# 2. 結果を出力する親ディレクトリ (MMDDHH形式で自動生成)
TIMESTAMP=$(date +"%m%d%H")
OUT_DIR_BASE="./redis_bench_results/$TIMESTAMP"

# 3. テストしたいアロケータのリストを定義
# フォーマット: "ラベル|ライブラリへの絶対パス|exportする環境変数(複数の場合は';'で区切る)"
ALLOCATORS=(
  "mimalloc_default|/home/uchino/software/mimalloc/out/release/libmimalloc.so.3.1|"
  "mi_PAGEMAP|/home/uchino/software/mimalloc/out/pagemap_commit_1/libmimalloc.so.3.1|"
  "mimalloc_optimized|/home/uchino/software/mimalloc/out/release/libmimalloc.so.3.1|MIMALLOC_ARENA_EAGER_COMMIT=1;MIMALLOC_PAGE_COMMIT_ON_DEMAND=0;MIMALLOC_PAGEMAP_COMMIT=1;MIMALLOC_PURGE_DELAY=-1"
  "system|system|"
)

# 4. 各アロケータで実行するテスト回数
NUM_RUNS=10

# 5. 各テスト実行間のスリープ時間（秒）
SLEEP_BETWEEN_RUNS=60

# 6. ベンチマーク設定
BENCH_OPERATIONS=1000      # -n パラメータ: 実行する操作数
BENCH_DATA_SIZE=10       # -d パラメータ: データサイズ（バイト）
BENCH_CLIENTS=50           # -c パラメータ: 並行クライアント数
BENCH_PIPELINE=16          # -P パラメータ: パイプライン設定
BENCH_TESTS="lpush,lrange" # -t パラメータ: テストタイプ
# --------------------------------------------------------------------


# --- スクリプト本体 (ここから下は変更不要) ---

# 元の作業ディレクトリを保存
ORIGINAL_PWD=$(pwd)

# サマリーCSVファイルを初期化
mkdir -p "$OUT_DIR_BASE"

# Git リポジトリを初期化（まだ存在しない場合）
REDIS_BENCH_GIT_DIR="./redis_bench_results"
if [ ! -d "$REDIS_BENCH_GIT_DIR/.git" ]; then
  echo "Initializing Git repository in $REDIS_BENCH_GIT_DIR..."
  cd "$REDIS_BENCH_GIT_DIR"
  git init
  git config user.name "Redis Benchmark Automation"
  git config user.email "benchmark@localhost"
  cd "$ORIGINAL_PWD"
fi

echo "allocator,mean_rps,stddev_rps,ci_lower_rps,ci_upper_rps" > "$OUT_DIR_BASE/throughput_summary.csv"
echo "allocator,max_vmrss_mb,max_vmsize_mb,max_vmpeak_mb,max_vmhwm_mb,avg_vmrss_mb,avg_vmsize_mb,avg_vmpeak_mb,avg_vmhwm_mb" > "$OUT_DIR_BASE/memory_summary.csv"

# 統計計算関数
calculate_stats() {
  local values=("$@")
  local sum=0
  local count=${#values[@]}

  # 平均値計算
  for val in "${values[@]}"; do
    sum=$(echo "$sum + $val" | bc -l)
  done
  local mean=$(echo "scale=2; $sum / $count" | bc -l)

  # 標準偏差計算
  local variance_sum=0
  for val in "${values[@]}"; do
    local diff=$(echo "$val - $mean" | bc -l)
    local diff_sq=$(echo "$diff * $diff" | bc -l)
    variance_sum=$(echo "$variance_sum + $diff_sq" | bc -l)
  done
  local variance=$(echo "scale=4; $variance_sum / $count" | bc -l)
  local stddev=$(echo "scale=4; sqrt($variance)" | bc -l)

  # 95%信頼区間計算 (t分布近似、小サンプル用)
  local t_value="2.0"  # 簡易的にt=2.0を使用 (df=2で約95%)
  local margin=$(echo "scale=4; $t_value * $stddev / sqrt($count)" | bc -l)
  local ci_lower=$(echo "scale=2; $mean - $margin" | bc -l)
  local ci_upper=$(echo "scale=2; $mean + $margin" | bc -l)

  echo "$mean,$stddev,$ci_lower,$ci_upper"
}

# メモリ使用量を取得する関数
get_memory_stats() {
  local pid=$1
  local label=$2
  local stage=$3
  local run=${4:-1}

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

  echo "--- Memory Stats for $label Run $run ($stage) ---"
  echo "VmSize: ${vmsize_mb:-N/A} MB"
  echo "VmRSS:  ${vmrss_mb:-N/A} MB"
  echo "VmPeak: ${vmpeak_mb:-N/A} MB"
  echo "VmHWM:  ${vmhwm_mb:-N/A} MB"
  echo "--------------------------------------------"

  # CSVファイルにも記録 (MB単位、run番号付き)
  echo "$label,$run,$stage,$vmsize_mb,$vmrss_mb,$vmpeak_mb,$vmhwm_mb" >> all_memory_stats.csv
}

# 各アロケータについてループ処理
for allocator_info in "${ALLOCATORS[@]}"; do
( # <--- 安全のために各テストをサブシェルで実行

  # 区切り文字'|'で設定を分割
  IFS='|' read -r label lib_path export_vars <<< "$allocator_info"

  # exportが必要な場合は実行 (複数の場合は';'で区切る)
  if [ -n "$export_vars" ]; then
    # セミコロンで区切られた複数のexport文を実行
    IFS=';' read -ra EXPORTS <<< "$export_vars"
    for export_cmd in "${EXPORTS[@]}"; do
      if [ -n "$export_cmd" ]; then
        export $export_cmd
      fi
    done
  fi

  OUT_DIR="$OUT_DIR_BASE/$label"
  mkdir -p "$OUT_DIR"
  cd "$OUT_DIR"

  echo "================================================="
  echo " Benchmarking Allocator: $label ($NUM_RUNS runs)"
  echo "================================================="

  # 統計用配列を初期化
  declare -a lpush_throughputs=()
  declare -a lrange100_throughputs=()
  declare -a lrange300_throughputs=()
  declare -a lrange500_throughputs=()
  declare -a lrange600_throughputs=()

  # メモリ統計用CSVファイルを初期化
  echo "allocator,run,stage,vmsize_mb,vmrss_mb,vmpeak_mb,vmhwm_mb" > all_memory_stats.csv
  echo "allocator,run,test,rps,avg_latency_ms,min_latency_ms,p50_latency_ms,p95_latency_ms,p99_latency_ms,max_latency_ms" > all_benchmark_results.csv

  # 指定回数だけテストを実行
  for run in $(seq 1 $NUM_RUNS); do
    echo
    echo "--- Run $run/$NUM_RUNS for $label ---"

    # 1. Redisサーバーを起動
    SERVER_LOG="redis-server-output-run$run.txt"

    if [[ "$lib_path" != "system" ]]; then
      LD_PRELOAD="$lib_path" "$REDIS_SRC_DIR/redis-server" > "$SERVER_LOG" 2>&1 &
    else
      "$REDIS_SRC_DIR/redis-server" > "$SERVER_LOG" 2>&1 &
    fi
    SERVER_PID=$!
    sleep 1

    # 各段階でメモリ使用量を記録 (run番号付きでCSVに保存)
    get_memory_stats $SERVER_PID "$label" "after_startup" "$run"

    # 2. データベースをクリア
    "$REDIS_SRC_DIR/redis-cli" flushall
    sleep 1

    # 3. ベンチマーク実行
    CSV_OUT_FILE="benchmark-result-run$run.csv"

    get_memory_stats $SERVER_PID "$label" "before_benchmark" "$run"

    "$REDIS_SRC_DIR/redis-benchmark" -n $BENCH_OPERATIONS -d $BENCH_DATA_SIZE -c $BENCH_CLIENTS -P $BENCH_PIPELINE -t $BENCH_TESTS --csv > "$CSV_OUT_FILE"

    get_memory_stats $SERVER_PID "$label" "after_benchmark" "$run"

    # ベンチマーク結果をall_benchmark_results.csvに追加
    while IFS=',' read -r test rps avg_lat min_lat p50_lat p95_lat p99_lat max_lat; do
      if [[ "$test" != "\"test\"" ]]; then  # ヘッダー行をスキップ
        echo "$label,$run,$test,$rps,$avg_lat,$min_lat,$p50_lat,$p95_lat,$p99_lat,$max_lat" >> all_benchmark_results.csv
      fi
    done < "$CSV_OUT_FILE"

    # スループット値を配列に保存
    lpush_throughputs+=($(grep '^"LPUSH",' "$CSV_OUT_FILE" | head -1 | awk -F',' '{print $2}' | tr -d '"'))
    lrange100_throughputs+=($(grep '^"LRANGE_100' "$CSV_OUT_FILE" | awk -F',' '{print $2}' | tr -d '"'))
    lrange300_throughputs+=($(grep '^"LRANGE_300' "$CSV_OUT_FILE" | awk -F',' '{print $2}' | tr -d '"'))
    lrange500_throughputs+=($(grep '^"LRANGE_500' "$CSV_OUT_FILE" | awk -F',' '{print $2}' | tr -d '"'))
    lrange600_throughputs+=($(grep '^"LRANGE_600' "$CSV_OUT_FILE" | awk -F',' '{print $2}' | tr -d '"'))

    # 4. データベースをクリア
    "$REDIS_SRC_DIR/redis-cli" flushall
    sleep 1

    # 5. Redisサーバーをシャットダウン
    get_memory_stats $SERVER_PID "$label" "before_shutdown" "$run"

    "$REDIS_SRC_DIR/redis-cli" shutdown
    sleep 1
    wait $SERVER_PID 2>/dev/null || true

    echo "Run $run completed"

    # 最後のrun以外ではスリープを挟む
    if [ $run -lt $NUM_RUNS ]; then
      echo "Sleeping for $SLEEP_BETWEEN_RUNS seconds before next run..."
      sleep $SLEEP_BETWEEN_RUNS
    fi
  done

  # 統計サマリーを計算してCSVファイルに出力
  echo "allocator,test,mean_rps,stddev_rps,ci_lower_rps,ci_upper_rps" > summary_statistics.csv

  lpush_stats=$(calculate_stats "${lpush_throughputs[@]}")
  echo "$label,LPUSH,$lpush_stats" >> summary_statistics.csv

  lrange100_stats=$(calculate_stats "${lrange100_throughputs[@]}")
  echo "$label,LRANGE_100,$lrange100_stats" >> summary_statistics.csv

  lrange300_stats=$(calculate_stats "${lrange300_throughputs[@]}")
  echo "$label,LRANGE_300,$lrange300_stats" >> summary_statistics.csv

  lrange500_stats=$(calculate_stats "${lrange500_throughputs[@]}")
  echo "$label,LRANGE_500,$lrange500_stats" >> summary_statistics.csv

  lrange600_stats=$(calculate_stats "${lrange600_throughputs[@]}")
  echo "$label,LRANGE_600,$lrange600_stats" >> summary_statistics.csv

  # 結果表示
  echo
  echo "=== SUMMARY RESULTS for $label ==="
  cat summary_statistics.csv
  echo "=================================="
  echo

  # LPUSH スループット情報を収集してサマリーファイルに追加

  # Extract LPUSH throughput statistics from summary_statistics.csv
  lpush_stats_line=$(grep ',LPUSH,' summary_statistics.csv 2>/dev/null || echo "")
  if [ -n "$lpush_stats_line" ]; then
    # Extract mean_rps, stddev_rps, ci_lower_rps, ci_upper_rps (columns 3,4,5,6)
    lpush_mean_rps=$(echo "$lpush_stats_line" | awk -F',' '{print $3}')
    lpush_stddev_rps=$(echo "$lpush_stats_line" | awk -F',' '{print $4}')
    lpush_ci_lower_rps=$(echo "$lpush_stats_line" | awk -F',' '{print $5}')
    lpush_ci_upper_rps=$(echo "$lpush_stats_line" | awk -F',' '{print $6}')
  else
    # Fallback values if no LPUSH data found
    lpush_mean_rps="0"
    lpush_stddev_rps="0"
    lpush_ci_lower_rps="0"
    lpush_ci_upper_rps="0"
  fi


  # メモリ使用量の最大値と平均値を計算
  max_vmrss=$(awk -F',' 'NR>1 {if($5+0>max) max=$5+0} END {print (max ? max : 0)}' all_memory_stats.csv)
  max_vmsize=$(awk -F',' 'NR>1 {if($4+0>max) max=$4+0} END {print (max ? max : 0)}' all_memory_stats.csv)
  max_vmpeak=$(awk -F',' 'NR>1 {if($6+0>max) max=$6+0} END {print (max ? max : 0)}' all_memory_stats.csv)
  max_vmhwm=$(awk -F',' 'NR>1 {if($7+0>max) max=$7+0} END {print (max ? max : 0)}' all_memory_stats.csv)
  avg_vmrss=$(awk -F',' 'NR>1 {sum+=$5; count++} END {printf "%.2f", (count>0 ? sum/count : 0)}' all_memory_stats.csv)
  avg_vmsize=$(awk -F',' 'NR>1 {sum+=$4; count++} END {printf "%.2f", (count>0 ? sum/count : 0)}' all_memory_stats.csv)
  avg_vmpeak=$(awk -F',' 'NR>1 {sum+=$6; count++} END {printf "%.2f", (count>0 ? sum/count : 0)}' all_memory_stats.csv)
  avg_vmhwm=$(awk -F',' 'NR>1 {sum+=$7; count++} END {printf "%.2f", (count>0 ? sum/count : 0)}' all_memory_stats.csv)

  # サマリーファイルに書き込み (絶対パスを使用)

  echo "$label,$lpush_mean_rps,$lpush_stddev_rps,$lpush_ci_lower_rps,$lpush_ci_upper_rps" >> "$ORIGINAL_PWD/$OUT_DIR_BASE/throughput_summary.csv"
  echo "$label,$max_vmrss,$max_vmsize,$max_vmpeak,$max_vmhwm,$avg_vmrss,$avg_vmsize,$avg_vmpeak,$avg_vmhwm" >> "$ORIGINAL_PWD/$OUT_DIR_BASE/memory_summary.csv"

  # Git commit for this allocator's results
  cd "$ORIGINAL_PWD/$REDIS_BENCH_GIT_DIR"
  git add "$TIMESTAMP/"

  # Create detailed commit message
  SLEEP_COUNT=$((NUM_RUNS - 1))  # Sleep applied between runs, so one less than total runs
  COMMIT_MSG="add $label benchmark results

Allocator: $label
Config: ${export_vars:-default}
Runs: $NUM_RUNS
Sleep applied: $SLEEP_COUNT times ($SLEEP_BETWEEN_RUNS sec each)
Benchmark: redis-benchmark -n $BENCH_OPERATIONS -d $BENCH_DATA_SIZE -c $BENCH_CLIENTS -P $BENCH_PIPELINE -t $BENCH_TESTS --csv"

  git commit -m "$COMMIT_MSG"

  echo "✅ Committed results for $label to Git repository"

  # 親ディレクトリに戻る
  cd "$ORIGINAL_PWD"

) # <--- サブシェルが終了し、exportした変数は自動的にリセットされる
done

# Final commit and push after all allocators complete
cd "$ORIGINAL_PWD/$REDIS_BENCH_GIT_DIR"

# Commit any remaining summary files
git add "$TIMESTAMP/"

# Create detailed final commit message
TOTAL_SLEEP_COUNT=$(( (NUM_RUNS - 1) * ${#ALLOCATORS[@]} ))
FINAL_COMMIT_MSG="complete benchmark session $TIMESTAMP

Session summary:
Allocators tested: ${#ALLOCATORS[@]}
Runs per allocator: $NUM_RUNS
Total sleep applied: $TOTAL_SLEEP_COUNT times ($SLEEP_BETWEEN_RUNS sec each)
Benchmark: redis-benchmark -n $BENCH_OPERATIONS -d $BENCH_DATA_SIZE -c $BENCH_CLIENTS -P $BENCH_PIPELINE -t $BENCH_TESTS --csv
Timestamp: $TIMESTAMP"

# Only commit if there are changes
if ! git diff --cached --quiet; then
  git commit -m "$FINAL_COMMIT_MSG"
  echo "✅ Final session commit created"
fi

# Push to remote repository (if configured)
if git remote | grep -q origin; then
  echo "📤 Pushing results to remote repository..."
  git push origin $(git branch --show-current)
  echo "✅ Results pushed to remote repository"
else
  echo "ℹ️  No remote repository configured. Results saved locally only."
  echo "   To push results later, configure a remote with: git remote add origin <URL>"
fi

cd "$ORIGINAL_PWD"

set +x
echo "✅ All benchmarks completed."
echo
echo "=== SUMMARY FILES CREATED ==="
echo "Throughput summary: $ORIGINAL_PWD/$OUT_DIR_BASE/throughput_summary.csv"
echo "Memory summary: $ORIGINAL_PWD/$OUT_DIR_BASE/memory_summary.csv"
echo "=== GIT REPOSITORY STATUS ==="
echo "Git repository: $REDIS_BENCH_GIT_DIR"
echo "Latest results committed and pushed (if remote configured)"
echo "=============================="