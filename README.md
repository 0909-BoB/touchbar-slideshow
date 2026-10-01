# 幻燈片播放器

讀取資料夾裡的圖片並以幻燈片輪播。資料夾本身沒有圖片時，會自動讀取子資料夾。

## 內容

| 檔案 | 說明 |
|---|---|
| `Slideshow.app` | 原生 Mac App，支援 Touch Bar（執行 `build.sh` 產生） |
| `TouchBarSlideshow/main.m` | App 原始碼（Objective-C） |
| `TouchBarSlideshow/build.sh` | 重新編譯成 `Slideshow.app` |
| `slideshow.py` | Python + Tkinter 版本（不支援 Touch Bar，需要 Pillow） |

## 使用

先編譯出 App（需要 Xcode Command Line Tools）：

```bash
./TouchBarSlideshow/build.sh
```


```bash
open Slideshow.app                                  # 跳出視窗選資料夾和每張秒數
open Slideshow.app --args ~/Pictures -i 5 -s -f     # 指定資料夾、每 5 秒、隨機、全螢幕
python3 slideshow.py ~/Pictures -i 5 -s -f          # Python 版，參數相同
```

每次開啟都會先跳出選擇視窗，可以選資料夾、設定每張圖片顯示幾秒（0.5–60）。
會記住上次的資料夾和秒數；命令列參數會當成視窗裡的預設值。

| 參數 | 說明 |
|---|---|
| `-i 秒數` | 每張秒數（預設 3） |
| `-r` | 包含子資料夾 |
| `-s` | 隨機順序 |
| `-f` | 全螢幕開始 |

## Touch Bar

| ◀ ⏯ ▶ | − 3.0 秒 + | 🔀 | 📌 | ⛶ | 12/2217 | 縮圖列 |
|---|---|---|---|---|---|---|
| 上一張 / 播放暫停 / 下一張 | 每張秒數 | 隨機 | 置頂 | 全螢幕 | 張數 | 跟著播放捲動，點縮圖跳過去 |

開啟中的設定（隨機、置頂）按鈕會變藍色。Touch Bar 左邊的 esc 可以離開全螢幕或關閉程式。

## 小視窗

視窗只顯示圖片，沒有標題列、按鈕或文字，所有設定都在 Touch Bar 上。
預設是置頂的小視窗（360×270），放在螢幕右下角，會記住上次的位置和大小。

- 拖曳圖片：移動視窗
- 拉邊緣：縮放
- 雙擊：全螢幕 / 回到小視窗

## 鍵盤

| 按鍵 | 功能 |
|---|---|
| 空白鍵 | 暫停 / 繼續 |
| ← → ↑ ↓ | 上一張 / 下一張 |
| `+` / `-` | 加快 / 放慢 |
| `F` | 全螢幕 |
| `S` | 隨機 |
| `T` | 切換視窗置頂 |
| `Esc` / `Q` | 離開 |

## 重新編譯

```bash
./TouchBarSlideshow/build.sh
```

用 clang 編譯 Objective-C（這台 Mac 的 Swift 工具鏈和 SDK 版本不合，所以沒用 Swift）。
