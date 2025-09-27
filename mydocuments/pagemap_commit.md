
### mimallocのページマップ・コミット戦略解説

mimallocは、ポインタからそれが属するメモリページ（`mi_page_t`）のメタデータを高速に逆引きするため、「ページマップ」という巨大なルックアップテーブルを利用します。特に64-bit環境では、このページマップがカバーする仮想アドレス空間は広大（最大128TiB以上）であり、その管理方法が性能とメモリ効率の鍵となります。

`mi_option_pagemap_commit`オプションは、この巨大なページマップにいつ物理メモリを割り当てる（コミットする）かを制御します。

#### 設計思想：オンデマンドコミットによる効率化

-   **課題**: 64-bitの広大なアドレス空間全体に対応するページマップ（最大数GiB）をプロセス起動時に一括でコミットすると、膨大な物理メモリを消費し、起動時間が大幅に悪化します。
-   **解決策**: デフォルト設定（`mi_option_pagemap_commit=0`）では、ページマップ用の仮想アドレス空間を**予約（reserve）**するだけに留め、物理メモリの割り当て（**コミット, commit**）は、その領域が実際に必要になったときに**オンデマンド**で行います。

これにより、アプリケーションが実際に使用するアドレス範囲に対応する部分だけが物理メモリを消費するため、起動が高速でメモリフットプリントを劇的に削減できます。

#### 実装：コミット状態を追跡するビットマップ

オンデマンドコミットを実現するため、mimallocは以下の巧妙な実装を用いています。

1.  **`_mi_page_map`**: ページマップ本体。巨大なバイト配列で、仮想アドレス空間を64KiBのスライス単位でマッピングします。最初は予約されているだけで、ほとんどコミットされていません。
2.  **`mi_page_map_commit`**: `_mi_page_map`自体のコミット状態を管理するための、もう一段階上のビットマップです。このビットマップの各ビットが、`_mi_page_map`の大きなチャンク（例: 64KiB分のエントリ）に対応します。これにより、どの部分がコミット済みかを非常に効率的に追跡できます。

### 動作シーケンス

以下に、新しいメモリページが確保され、ページマップに登録される際の関数の呼び出しシーケンスと、`mi_free`時にポインタからページを安全に逆引きするシーケンスを図解します。

#### 1. 新規ページ確保とページマップへの登録

アプリケーションがメモリを要求し、mimallocが新しいページをOSから確保した後、そのページを内部的に管理するためにページマップへ登録する際のフローです。

```mermaid
sequenceDiagram
    participant App as アプリケーション
    participant mimalloc as mimalloc内部
    participant PageMap as _mi_page_map
    participant CommitMap as mi_page_map_commit
    participant OS as オペレーティングシステム

    App->>mimalloc: mi_malloc(size)
    Note over mimalloc: 新規ページが必要と判断
    mimalloc->>OS: 新しいメモリページを確保
    OS-->>mimalloc: ページ(page)を返す
    mimalloc->>mimalloc: _mi_page_map_register(page)
    Note right of mimalloc: ページを管理下に置く
    
    mimalloc->>mimalloc: mi_page_map_ensure_committed(idx, ...)
    Note right of mimalloc: ページマップの該当領域が<br>コミット済みか確認
    
    mimalloc->>CommitMap: mi_bitmap_is_clear(commit_idx) ?
    Note over CommitMap: ビットマップをチェック
    
    alt 未コミットの場合
        CommitMap-->>mimalloc: true (未コミット)
        mimalloc->>OS: _mi_os_commit(map_chunk_addr, size)
        Note right of mimalloc: ページマップのチャンクをコミット
        OS-->>mimalloc: 成功
        mimalloc->>CommitMap: mi_bitmap_set(commit_idx)
        Note over CommitMap: コミット済みフラグを立てる
    else コミット済みの場合
        CommitMap-->>mimalloc: false (コミット済み)
    end
    
    mimalloc->>PageMap: _mi_page_map[idx] = offset
    Note right of PageMap: 安全にページ情報を書き込む
    
    mimalloc-->>App: ポインタを返す
```

#### 2. メモリ解放時の安全なポインタ逆引き

`mi_free`が呼ばれた際、渡されたポインタが本当にmimallocが管理するものか、安全かつ高速に確認するためのフローです。

```mermaid
sequenceDiagram
    participant App as アプリケーション
    participant mimalloc as mimalloc内部
    participant PageMap as _mi_page_map
    participant CommitMap as mi_page_map_commit

    App->>mimalloc: mi_free(p)
    mimalloc->>mimalloc: page = _mi_safe_ptr_page(p)
    Note right of mimalloc: ポインタからページ情報を逆引き
    
    mimalloc->>CommitMap: mi_bitmap_is_set(commit_idx) ?
    Note over CommitMap: ページマップの該当領域が<br>コミット済みかチェック
    
    alt 未コミットの場合
        CommitMap-->>mimalloc: false (未コミット)
        Note right of mimalloc: mimalloc管理外のポインタと判断
        mimalloc-->>App: 何もせずに関数を終了
    else コミット済みの場合
        CommitMap-->>mimalloc: true (コミット済み)
        mimalloc->>PageMap: offset = _mi_page_map[idx]
        Note right of PageMap: 安全にページマップにアクセス
        
        alt offsetが0の場合
             PageMap-->>mimalloc: 0
             Note right of mimalloc: 解放済み or mimalloc管理外
             mimalloc-->>App: 何もせずに関数を終了
        else offsetが0でない場合
             PageMap-->>mimalloc: offset > 0
             mimalloc->>mimalloc: pageアドレスを計算
             Note right of mimalloc: ページメタデータを取得し、<br>解放処理を続行
        end
    end
```

このオンデマンドコミット戦略により、mimallocは広大な64-bitアドレス空間を効率的に利用しつつ、起動時のオーバーヘッドとメモリフットプリントを最小限に抑えるという、相反する要求を両立させています。