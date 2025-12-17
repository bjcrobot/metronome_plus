# iOS/macOS プリカウント実装ガイド

## 現状
- ✅ Android: プリカウント機能実装済み（v0.1.0-android-mvp）
- ❌ iOS/macOS: プリカウント機能未実装

## Android で適用した修正内容

### 1. 主な問題
プリカウントバッファが+1小節多く再生される（同一バッファの重複 write）

### 2. 解決策
1. **`remainingPreCountBarsToWrite` カウンター導入**
   - プリカウント開始時に残り小節数を設定
   - バッファ生成ごとにデクリメント
   - 0 になったらメイン音源に切り替え

2. **バッファの毎回再生成**
   - `updated` フラグに依存せず、ループごとに必ず `generateBuffer()` を呼び出し
   - 古いバッファの再利用を防止

3. **内部再起動時のプリカウント抑制**
   - `setBPM()`, `setTimeSignature()`, `setAudioFile()` での再起動時は `play(0)` を使用
   - 再生中のパラメータ変更ではプリカウントをスキップ

## iOS/macOS で確認すべき点

### ファイル: `darwin/metronome_plus/Sources/metronome_plus/Metronome.swift`

#### 1. プリカウント実装の有無
現時点で `preCount` 関連のコードが見当たらない → **まず機能実装が必要**

#### 2. 実装する場合の注意点

**AVAudioPlayerNode のバッファスケジューリング:**
- `scheduleBuffer(_:completionHandler:)` の動作を確認
- Android の `AudioTrack.write()` とは異なるタイミング制御の可能性
- バッファの連続スケジュールで重複が起きないか検証

**現在の setBPM/setTimeSignature/setAudioFile:**
```swift
func setBPM(bpm: Int) {
    if audioBpm != bpm {
        audioBpm = bpm
        if isPlaying {
            pause()
            play()  // ← 内部再起動
        }
    }
}
```

**Android の対応版（参考）:**
```java
public void setBPM(int bpm) {
    if (audioBpm != bpm) {
        audioBpm = bpm;
        if (isPlaying()) {
            pause();
            play(0);  // ← プリカウントをスキップ
        }
    }
}
```

#### 3. 推奨実装手順

1. **プリカウント基本機能を追加**
   - `preCountBars` プロパティ
   - `preCountMainSound`, `preCountAccentedSound` 音源
   - `play(preCountBarsOverride: Int = -1)` メソッド

2. **バッファ生成ロジック修正**
   - `remainingPreCountBarsToWrite` カウンター導入
   - `generateBuffer()` 内で残りカウントに応じて音源を切り替え

3. **内部再起動の修正**
   - `setBPM()`, `setTimeSignature()`, `setAudioFile()` を `play(0)` に変更

4. **動作確認**
   - プリカウント 1/2/4 小節が正確に再生されるか
   - BPM/拍子変更時にプリカウントが鳴らないか
   - 音源変更時にプリカウントが鳴らないか

## 参考コミット（Android実装）

- `cf7c133`: プリカウント+1小節バグ修正（`remainingPreCountBarsToWrite` 導入）
- `d133eb1`: setBPM/setTimeSignature を `play(0)` に変更
- `2d34d8a`: setAudioFile を `play(0)` に変更

## Mac環境での作業開始

```bash
# リポジトリをクローン
git clone https://github.com/bjcrobot/metronome_plus.git
cd metronome_plus

# feature ブランチをチェックアウト
git checkout feature/android-precount-rework

# 最新を取得
git pull origin feature/android-precount-rework

# iOS/macOS 実装用の新ブランチを作成（推奨）
git checkout -b feature/ios-precount

# Android実装を参考に進める
# ファイル: android/src/main/java/com/sumsg/metronome_plus/Metronome.java
```

## 完了基準
- [ ] プリカウント機能が iOS/macOS で動作
- [ ] 指定小節数（1/2/4）が正確に再生される
- [ ] BPM/拍子/音源変更時にプリカウントが鳴らない
- [ ] example アプリで動作確認（iOS Simulator/実機）
- [ ] コミット＆プッシュ
- [ ] README.md 更新（iOS: ✅ Completed）

---

**質問・不明点があれば、Android実装のコミット履歴と `PRECOUNT_INVESTIGATION.md` を参照してください。**
