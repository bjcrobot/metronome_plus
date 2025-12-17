# Android プリカウント機能 - 調査レポート

## 日付
2025年12月8日

## 問題の概要
Android版メトロノームでプリカウント機能を実装したが、**指定した小節数より +1 小節多く再生される**問題が発生。

### 期待動作
- UI で「1 bar」を選択 → プリカウント 1 小節（4ティック: -4, -3, -2, -1）→ メイン再生（0, 1, 2, 3...）

### 実際の動作
- プリカウント用バッファが **2回出力される** → 実質 2 小節分のプリカウントが再生される
- ログ例:
```
writing buffer #0 (precount)  ← 1回目
writing buffer #1 (precount)  ← 2回目（余分）
writing buffer #2 (main)      ← メイン開始
```

## 技術的な背景

### AudioTrack WRITE_BLOCKING の挙動
- `audioTrack.write(..., WRITE_BLOCKING)` は「バッファ書き込みが完了するまでブロック」する
- バッファ 1 個分（1 小節 = 約 500ms）が AudioTrack の内部キューに入った時点で制御が返る
- しかし、**音声再生はバックグラウンドで継続**している

### startMetronome() のループ構造
```java
while (isPlaying()) {
    synchronized (mLock) {
        if (updated || audioBuffer == null) {
            audioBuffer = generateBuffer();  // バッファ生成
        }
        audioTrack.write(audioBuffer, 0, audioBuffer.length, WRITE_BLOCKING);  // 書き込み
    }
}
```

**問題点:**
1. Loop 1: `updated=true` → プリカウントバッファ生成 → write → 制御が返る
2. Loop 2: `updated=false` だが、条件 `audioBuffer != null` で既存バッファを再度 write
3. 結果: **同じプリカウントバッファが 2 回出力される**

## 試行した対策と結果

### 案A: preCountEnded フラグでスキップ
**アプローチ:** プリカウント終了直後に書き込みをスキップ
```java
if (preCountEnded) {
    preCountEnded = false;
    continue;  // スキップ
}
```
**結果:** ❌ 変化なし。タイミング問題で効果なし。

### 案B: bufferNeedsUpdate フラグで制御
**アプローチ:** プリカウント終了時に明示的に新バッファ生成を要求
```java
if (bufferNeedsUpdate) {
    audioBuffer = generateBuffer();
    bufferNeedsUpdate = false;
}
```
**結果:** ❌ 変化なし。根本原因を解決していない。

### 案C: プリカウント中の updated フラグ固定
**アプローチ:** プリカウント中は `updated=false` を強制
```java
if (isInPreCount) {
    updated = false;
}
```
**結果:** ❌ 状態が悪化。2回目の再生時にプリカウント音が鳴らなくなった。

### 案D: updated フラグのリセットタイミング変更
**アプローチ:** `generateBuffer()` 内ではなく、`startMetronome()` で `updated=false` をセット
```java
if (updated || audioBuffer == null) {
    audioBuffer = generateBuffer();
    updated = false;  // 生成直後にリセット
}
```
**結果:** ❌ 変化なし。

### 案E: 200ms スキップロジック
**アプローチ:** プリカウント終了後 200ms は書き込みをスキップ
```java
if (preCountEndTime > 0 && System.currentTimeMillis() - preCountEndTime < 200) {
    // スキップ
}
```
**結果:** ❌ ループが 10ms 周期で回っているため、スキップロジックが機能しなかった。

## 根本原因の分析

### デバッグログからの発見
```
play() called: bars=1, isInPreCount=true, currentTick=-4
generateBuffer: isInPreCount=true, currentTick=-4
writing buffer #0, isInPreCount=true  ← プリカウントバッファ書き込み（1回目）
tick: -4, -3, -2
writing buffer #1, isInPreCount=true  ← プリカウントバッファ書き込み（2回目）
tick: -1
onPeriodicNotification: precount ended, currentTick=0
tick: 0, 1, 2
bufferNeedsUpdate=true, generating new buffer
generateBuffer: isInPreCount=false, currentTick=2
writing buffer #2, isInPreCount=false  ← メインバッファ書き込み
```

**判明した事実:**
1. プリカウント用バッファは正しく 1 回生成されている
2. しかし、**同じバッファが 2 回 write されている**
3. `onPeriodicNotification` が呼ばれるのは AudioTrack の再生進行に応じて（非同期）
4. `startMetronome()` ループと `onPeriodicNotification` の同期が取れていない

### 真の問題
**AudioTrack の STREAM モードでは、複数のバッファを連続的にキューイングできる。**
- 1回目の write: プリカウントバッファが AudioTrack の内部キューに入る → 再生開始
- WRITE_BLOCKING から制御が返る → ループが次の反復に進む
- 2回目の write: `updated=false` かつ `audioBuffer != null` のため、**同じプリカウントバッファを再度 write**
- 結果: AudioTrack は 2 つのプリカウントバッファを連続再生

## 未解決の課題

### 問題1: バッファの重複出力を防ぐ方法
- `updated` フラグだけでは不十分
- `audioBuffer != null` 条件が常に true になるため、同じバッファが再利用される

### 問題2: 非同期タイミングの同期
- `onPeriodicNotification`（AudioTrack スレッド）と `startMetronome`（別スレッド）の同期が難しい
- フラグベースの制御では、タイミングのずれが発生する

### 問題3: WRITE_BLOCKING の挙動
- WRITE_BLOCKING は「書き込み完了」を待つが、「再生完了」は待たない
- バッファが再生されるまでの待機方法が不明確

## 今後の検討事項

### 代替案1: MODE_STATIC への変更
- `AudioTrack.MODE_STATIC` を使用すれば、バッファを 1 回だけロードして再生
- ただし、動的な BPM 変更やループには不向き

### 代替案2: カスタムペーシング
- AudioTrack の `getPlaybackHeadPosition()` を監視
- バッファ長に相当する再生位置に達するまで、次の write を遅延

### 代替案3: 別スレッドでの制御
- AudioTrack の通知コールバックではなく、独自のタイマーで制御
- より細かいタイミング制御が可能

### 代替案4: プリカウントを別の AudioTrack で処理
- プリカウント専用の AudioTrack を作成
- メイン再生とは独立して制御

## 参考ログ

### 正常なティック進行（期待値）
```
tick: -4  ← プリカウント開始
tick: -3
tick: -2
tick: -1  ← プリカウント終了
tick: 0   ← メイン開始
tick: 1
tick: 2
tick: 3
```

### 実際のティック進行（問題あり）
```
tick: -4  ← プリカウント 1 小節目
tick: -3
tick: -2
tick: -1
tick: 0   ← プリカウント 2 小節目（余分）← ★ここが問題
tick: 1
tick: 2
tick: 3
tick: 0   ← メイン開始
```

## まとめ
- プリカウント API 自体は正しく実装されている
- **AudioTrack の STREAM モードでのバッファ管理が根本原因**
- MODE_STREAM での連続バッファ書き込みと、非同期コールバックの同期が課題
- より根本的なアーキテクチャ変更が必要かもしれない

---

## 解決策（2025年12月17日追記）

### 採用したアプローチ
**バッファ再利用の廃止 + プリカウント小節カウンター導入**

#### 実装内容

1. **`remainingPreCountBarsToWrite` フィールド追加**
   - プリカウント開始時に残り小節数を初期化
   - `generateBuffer()` でプリカウントバッファを生成するたびにデクリメント

2. **バッファの毎回再生成**
   - `updated` フラグに依存せず、ループごとに `generateBuffer()` を必ず呼び出し
   - 同一バッファの再 write を防止

3. **内部再起動時のプリカウント抑制**
   - `setBPM()`, `setTimeSignature()`, `setAudioFile()` の内部再起動時は `play(0)` を使用
   - 再生中のパラメータ変更ではプリカウントをスキップし、即座にメイン拍に移行

#### コード例（Metronome.java）

```java
private int remainingPreCountBarsToWrite = 0;

public void play(int preCountBarsOverride) {
    // ...
    remainingPreCountBarsToWrite = preCountBars;
    // ...
}

private short[] generateBuffer() {
    // ...
    boolean usePrecount = remainingPreCountBarsToWrite > 0;
    if (usePrecount) {
        remainingPreCountBarsToWrite--;
    }
    // ... プリカウント音源 or メイン音源を選択
}

private void startMetronome() {
    while (isPlaying()) {
        synchronized (mLock) {
            // 毎回バッファを再生成（updated 不要）
            audioBuffer = generateBuffer();
            audioTrack.write(audioBuffer, 0, audioBuffer.length, WRITE_BLOCKING);
        }
    }
}
```

### 結果
- ✅ プリカウント +1 小節バグ解決
- ✅ 指定小節数（1/2/4）が正確に再生される
- ✅ 再生中の BPM/拍子/音源変更でプリカウントが鳴らない UX 向上

### タグ
- `v0.1.0-android-mvp`: Android 最低動作版（本修正適用済み）

---

**次のステップ:**
- iOS/macOS プラットフォームでも同様の問題がないか検証
- ドキュメント整備（README への機能説明追加）
