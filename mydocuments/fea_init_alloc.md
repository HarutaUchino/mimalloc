# ドキュメント：mimallocの起動時メモリ完全確保・初期化への変更手順

## 1. 目的

このドキュメントは、`mimalloc` メモリアロケータのデフォルト動作である動的なメモリ管理（オンデマンドコミット、段階的フリーリスト拡張、動的ページ再利用など）を可能な限り抑制し、アプリケーションの起動時に必要なメモリリソースを事前に確保・初期化する手順を記述します。

**目標とする動作**:
-   **起動時に指定量のメモリを一括で確保・コミット**し、物理メモリを割り当てる。
-   ページマップを含む、mimallocの**内部管理構造も完全に事前コミット**する。
-   新しいメモリページが必要になった際、その**ページ内の全ブロックを即座にフリーリストとして構築**する。
-   実行中の**OSへのメモリ返却やスレッド間での動的なページ移動をなくす**。
-   これにより、アプリケーション実行中のメモリアロケーションに伴う**ページフォールトや遅延（ジッター）を最小限に抑え**、性能の予測性を最大限に高める。

## 2. 変更の全体像

このカスタマイズは、**ソースコードの改変**と、複数の**実行時オプション設定**を組み合わせることで実現します。

| レベル | 対象 | 変更内容 | 目的 |
| :--- | :--- | :--- | :--- |
| **実行時設定** | **アリーナ (Arena)** | 起動時に指定量のメモリを確保し、全領域をコミットする。 | OSレベルでのページフォールトを起動時に集約。 |
| **実行時設定** | **ページ (Page)** | ページ確保時のオンデマンドコミットを無効化する。 | ページ単位でのコミット遅延をなくす。 |
| **実行時設定** | **ページマップ** | 内部管理テーブル（ページマップ）を完全コミットする。 | 内部動作に起因する遅延を排除。 |
| **実行時設定** | **動的挙動** | メモリの自動返却やスレッド間再利用を無効化する。 | 実行時の動作を静的かつ決定的にする。 |
| **ソースコード改変** | **ページ内部** | ページ初期化時のフリーリスト拡張を一括で行うようにする。 | ブロック確保時のフリーリスト拡張処理をなくす。 |

### 動作フローの概念図

デフォルトの動的な動作と、変更後の静的な動作の比較です。

```mermaid
graph TD
    subgraph デフォルト動作 (オンデマンド・動的)
        A[起動] --> B(アリーナを予約);
        B --> C{アロケーション要求 #1};
        C --> D(ページを切り出し<br/>& オンデマンドコミット);
        D --> E{フリーリスト枯渇?};
        E -- No --> G[ブロックを返す];
        E -- Yes --> F(フリーリストを少量拡張<br/>& 追加コミット);
        F --> G;
        G --> H{アロケーション要求 #2 ...};
        H --> I{解放};
        I --> J(ページを他スレッドが再利用<br/>or OSに遅延返却);
    end

    subgraph 変更後の動作 (事前確保・静的)
        K[起動] --> L(指定量のアリーナ/ページマップを<br/>完全コミット & 初期化);
        L --> M{アロケーション要求 #1};
        M --> N(ページを切り出し<br/>& フリーリストを完全構築);
        N --> O[ブロックを返す];
        O --> P{アロケーション要求 #2 ...};
        P --> Q{解放};
        Q --> R(ページは元のヒープに留まる);
    end

    style B fill:#f9f,stroke:#333,stroke-width:2px
    style D fill:#f9f,stroke:#333,stroke-width:2px
    style F fill:#f9f,stroke:#333,stroke-width:2px
    style J fill:#f9f,stroke:#333,stroke-width:2px
    
    style L fill:#9cf,stroke:#333,stroke-width:2px
    style N fill:#9cf,stroke:#333,stroke-width:2px
    style R fill:#9cf,stroke:#333,stroke-width:2px
```

## 3. 実施手順

### ステップ1：ソースコードの変更

`mimalloc` のソースコードを一部変更し、フリーリストが一度に最後まで構築されるようにします。

1.  **ファイルの編集**:
    -   対象ファイル: `src/page.c`
    -   対象関数: `mi_page_extend_free`

2.  **変更内容**:
    関数内にある、一度に拡張するフリーブロック数を制限しているロジックを無効化（コメントアウトまたは削除）します。

    ```diff
    --- a/src/page.c
    +++ b/src/page.c
    @@ -559,16 +559,7 @@
       size_t extend = (size_t)page->reserved - page->capacity;
       mi_assert_internal(extend > 0);
     
-      size_t max_extend = (bsize >= MI_MAX_EXTEND_SIZE ? MI_MIN_EXTEND : MI_MAX_EXTEND_SIZE/bsize);
-      if (max_extend < MI_MIN_EXTEND) { max_extend = MI_MIN_EXTEND; }
-      mi_assert_internal(max_extend > 0);
-    
-      if (extend > max_extend) {
-        // ensure we don't touch memory beyond the page to reduce page commit.
-        // the `lean` benchmark tests this. Going from 1 to 8 increases rss by 50%.
-        extend = max_extend;
-      }
-    
+      // Removed extend limit to initialize the full free list at once for the pre-allocation strategy.
       mi_assert_internal(extend > 0 && extend + page->capacity <= page->reserved);
       mi_assert_internal(extend < (1UL<<16));
     
    ```
    > **注意**: 上記の行番号(`559`)はバージョンによって異なる場合があります。`size_t extend` の定義直後にある `max_extend` の計算と `if (extend > max_extend)` のブロックを探してください。

### ステップ2：ライブラリの再ビルド

変更したソースコードから `mimalloc` ライブラリをビルドします。

```bash
# mimallocのソースコードのルートディレクトリに移動
cd /path/to/mimalloc

# ビルド用ディレクトリを作成して移動
mkdir -p out/release
cd out/release

# CMakeでビルド設定を生成 (環境に合わせてオプションを追加)
cmake ../.. -DCMAKE_BUILD_TYPE=Release

# ビルドを実行
make
```

ビルドが完了すると、`out/release` ディレクトリ内に `libmimalloc.so` (Linux), `libmimalloc.dylib` (macOS), `mimalloc.lib` (Windows) などのライブラリファイルが生成されます。

### ステップ3：アプリケーションの実行時設定

再ビルドした `mimalloc` ライブラリをリンクしたアプリケーションを実行する際に、以下の表に示す環境変数を設定します。

#### 実行時オプション設定一覧

| オプション名 (環境変数) | 推奨値 | 目的 |
| :--- | :--- | :--- |
| **`MIMALLOC_RESERVE_OS_MEMORY`** | **`<サイズ(KiB)>`** | **【最重要】** 起動時にメモリを一括確保。アプリケーションの最大使用量をKiB単位で指定。 |
| **`MIMALLOC_ARENA_EAGER_COMMIT`** | **`1`** | **【必須】** アリーナ全体を完全コミット。 |
| **`MIMALLOC_PAGE_COMMIT_ON_DEMAND`** | **`0`** | **【必須】** ページ単位のオンデマンドコミットを無効化。 |
| **`MIMALLOC_PAGEMAP_COMMIT`** | **`1`** | **【推奨】** 内部管理テーブル（ページマップ）を完全コミットし、内部動作の遅延を排除。 |
| **`MIMALLOC_PURGE_DELAY`** | **`-1`** | **【推奨】** OSへのメモリ自動返却を完全に無効化し、再利用時のページフォールトを防止。 |
| `MIMALLOC_PAGE_RECLAIM_ON_FREE` | `-1` | （オプション）スレッド間での動的なページ再利用を無効化し、動作をより決定的にする。 |
| `MIMALLOC_PAGE_FULL_RETAIN` | `0` | （オプション）いっぱいになったページのヒープ内保持を無効化し、メモリ状態をシンプルに保つ。 |
| `MIMALLOC_ALLOW_LARGE_OS_PAGES` | `1` or `2` | （性能最適化）TLB効率を向上させる。`RESERVE_OS_MEMORY`のサイズを2MiBの倍数にすると効果的。 |

#### 実行例（Linux/macOS）

アプリケーションが最大で **4GiB** のメモリを使用すると仮定した場合。
(4GiB = 4 * 1024 * 1024 KiB = 4194304 KiB)

```bash
# 事前にビルドしたライブラリをロードパスに追加
export LD_LIBRARY_PATH=/path/to/mimalloc/out/release:$LD_LIBRARY_PATH

# 必須の実行時オプションを設定
export MIMALLOC_RESERVE_OS_MEMORY=4194304
export MIMALLOC_ARENA_EAGER_COMMIT=1
export MIMALLOC_PAGE_COMMIT_ON_DEMAND=0

# 推奨の追加オプションを設定
export MIMALLOC_PAGEMAP_COMMIT=1
export MIMALLOC_PURGE_DELAY=-1
export MIMALLOC_ALLOW_LARGE_OS_PAGES=2

# アプリケーションを実行
./your_application
```

**API呼び出しによる設定**:
環境変数の代わりに、プログラムの `main` 関数の冒頭で `mi_option_set` を呼び出して設定することも可能です。

```c
#include <mimalloc.h>
#include <stdio.h>

void setup_mimalloc_for_preallocation(void) {
  // 必須設定
  mi_option_set(mi_option_arena_eager_commit, 1);
  mi_option_set(mi_option_page_commit_on_demand, 0);
  
  // 推奨設定
  mi_option_set(mi_option_pagemap_commit, 1);
  mi_option_set(mi_option_purge_delay, -1);
  mi_option_set(mi_option_allow_large_os_pages, 2); // Linuxの場合
}

int main() {
  setup_mimalloc_for_preallocation();

  // 4GiBのメモリを事前に確保・コミット
  size_t reserve_size = 4UL * 1024 * 1024 * 1024;
  if (mi_reserve_os_memory(reserve_size, true, true) != 0) {
    fprintf(stderr, "Failed to reserve OS memory\n");
    return 1;
  }
  
  // ... アプリケーション本体のコード ...
  
  return 0;
}
```

---

以上の手順により、`mimalloc` はアプリケーションの実行中の性能変動要因を極力排除し、より予測可能で安定したレイテンシで動作するようになります。