# Lisvo（聽字）

Mac 原生的語音轉文字 App：分講者、輸出時間軸。辨識、分講者與潤飾全部在本機處理；
只有從 iPhone 分享的音檔和它的逐字稿會經過 iCloud 雲碟（見下方「從 iPhone 傳音檔」）。

- 產品介紹：<https://archcross.com/tools/lisvo/>（English: <https://archcross.com/en/tools/lisvo/>）
- 下載：[GitHub Releases](https://github.com/Archcross/lisvo/releases/latest)，免費。第一次打開的步驟見下方「安裝」。

Free, open-source speech-to-text app for Mac. Transcribes recordings with speaker labels and timestamps,
and shows live captions with translation, all on your Mac.

## 功能

- **兩種辨識模式**
  - 快速：Mac 內建語音辨識（Speech 框架的 SpeechTranscriber）。不用下載模型，要指定語言。
  - 精準：Whisper large-v3-turbo（WhisperKit，Core ML 版）。第一次使用會下載模型，可以自動偵測語言。
- **兩種模式對講者的方式不同**
  - 快速：先轉整個檔案，再用每個片語的時間對到講者，一句話中途換人會切開。文字最早出現。
  - 精準：先分講者，再把每位講者連續說話的那段聲音分別交給 Whisper。WhisperKit 對中文的逐字時間不可靠，
    用字詞時間對講者會錯，所以改成這樣；代價是少了跨講者的前後文，偶爾會有錯字。
- **分講者**：FluidAudio 的離線 VBx 流程（pyannote 分段＋WeSpeaker 聲紋），跑在 Neural Engine。可自動判斷人數或指定人數。
- **AI 潤飾**（選用）：Mac 內建 Foundation Models，修錯字、補標點、刪口頭禪。潤飾版另存，原文與時間軸不變。
- **點句播放**：點逐字稿任何一句，只播那一句的原始音檔，播到句尾自動停；那句會標底色。空白鍵暫停／繼續，播完再按會重播同一句。右鍵可拷貝該句。
- **邊轉邊看**：辨識出來的句子即時顯示。精準模式一開始就帶講者；快速模式的講者等分講者完成後補上。
- **即時字幕**：即時轉成字幕顯示在浮動視窗。「來源」選聽哪裡的聲音：
  - 電腦聲音：Mac 正在播放的聲音（網頁、線上會議、任何 App；不含 Lisvo 自己的播放）。第一次使用要允許「螢幕與系統錄音」。
  - 麥克風：現場演講、面對面談話。用「系統設定 → 聲音 → 輸入」選的麥克風，中途接上或拔掉耳機會自動改接新裝置。第一次使用要允許「麥克風」。

  只用快速模式（Mac 內建辨識，暫定文字約 0.1 秒更新），不分講者、不潤飾；停止時存成「即時字幕」逐字稿到本機輸出資料夾。
  浮動視窗的字幕從底部往上滾：新字出現在最後一行，舊的從上緣捲出去，不會用「…」省略。
  主視窗有獨立的「即時字幕」列：「聽」選說話的語言（和檔案轉錄的語言分開設定），按「開始字幕」或 ⇧⌘L。
- **即時翻譯**（選用）：「譯成」選繁體中文、英文、日文或韓文，用 Mac 內建翻譯（Translation 框架）在本機翻，
  浮動視窗上面一行淡色原文、下面兩行黃色譯文。遇到逗號、冒號或句號的那一段就先翻；Apple 即時辨識常常一長串不加標點，
  所以沒標點的部分超過 12 個中日文字（英韓文 8 個字）時也先暫時翻，最快每秒更新一次，之後遇到標點再換成正式譯文。
  每句定案後再按整句重翻一次，存檔的譯文用整句的版本，前後文完整、比較準。
  第一次用某組語言時主視窗會跳出系統的語言包下載提示，下載完自動開始翻，期間已定案的句子會補翻。
  停止時另存「即時字幕_翻譯.txt」（每句前面是開始時間）。和「聽」相同的語言不會出現在「譯成」選單。
- **中英互譯**（「聽」選中文（台灣）時，「譯成」多一個「中英互譯」）：給中英夾雜的講者用。中文的段落翻成英文、英文的段落翻成繁體中文，
  每段看有沒有兩個以上的漢字決定方向。
  - 同時跑中文和英文兩個辨識器。中文辨識器會把整句英文聽成亂碼（「I thinke shoudanist bcauseh…」），
    所以中文結果裡沒有中文字的段落，換成英文辨識器同一段、信心夠高的句子；中文句子裡夾的英文單字（「這個 project 的 deadline」）維持中文辨識器的結果。
  - 整句英文講完約 1～2 秒後才換成正確的英文（要等英文辨識器那句定案），之前字幕上先是中文辨識器的版本。
  - 每段定案最多多等 1.5 秒，等英文辨識器跟上再合併，所以主視窗的定案句子比只聽中文晚一點出現；浮動字幕不受影響。
- **iPhone 收件**：iPhone 分享到 iCloud 雲碟「Lisvo/收件」的音檔，Lisvo 收到就自動轉錄，逐字稿存回 iCloud。

## 從 iPhone 傳音檔

不需要付費開發者帳號，用 iCloud 雲碟當收件匣：

```
iCloud 雲碟/Lisvo/
├── 收件/     iPhone 存進來的音檔
├── 已處理/   轉完的音檔移到這裡，不會重複轉錄
└── 逐字稿/   轉好的逐字稿，iPhone「檔案」App 直接看得到
```

- Lisvo 開著時每 3 秒看一次「收件」。檔案同步完整（大小連續兩次相同）才開始轉，用當下的模式、語言、講者與潤飾設定。
- 正在轉錄或正在播放時不會打斷，排隊等候；Lisvo 沒開時進來的檔案，下次打開會補轉。
- 轉失敗或按了停止的檔案留在「收件」，這次開著期間不再自動重試，下次打開 App 再試。
- 只有手機來的檔案逐字稿存到 iCloud；在 Mac 上拖進來的檔案照舊存到設定的輸出資料夾。
- 選單「檔案 > 打開 iCloud 收件資料夾」可以直接打開。

### iPhone 捷徑設定（只需一次）

iOS 版本不同，選項名稱可能略有差異。

1. 打開「捷徑」App，點右上「＋」建立新捷徑，名稱改成「傳到 Lisvo」。
2. 加入動作「儲存檔案」，輸入選「捷徑輸入」。
3. 展開「儲存檔案」，關閉「詢問儲存位置」，資料夾選「iCloud 雲碟 > Lisvo > 收件」。
4. 打開捷徑的詳細資訊（ⓘ），開啟「在分享表單中顯示」。
5. 使用時：在「語音備忘錄」點一則錄音，按分享，選「傳到 Lisvo」。

如果分享選單裡找不到這個捷徑，也可以直接選「儲存到檔案」，存到同一個「收件」資料夾。

## 輸出

每次轉錄在輸出資料夾下建立一個子資料夾「檔名 日期 時間」，內含：

| 檔案 | 內容 |
|---|---|
| `檔名.txt` | 依講者分段的純文字 |
| `檔名_時間軸.txt` | 每句一行：`[00:01:23] 講者 1：……` |
| `檔名_maxqda.txt` | 與 aTrain 相同的 MAXQDA 匯入格式 |
| `檔名.srt`、`檔名.vtt` | 字幕檔，含講者 |
| `檔名.json` | 完整資料（每句、每個字詞的時間） |
| `檔名_潤飾.txt` | 開啟 AI 潤飾時才有 |

## 系統需求

- Apple 晶片的 Mac，macOS 26 以上
- AI 潤飾需要開啟 Apple Intelligence

## 安裝

到 [Releases](https://github.com/Archcross/lisvo/releases) 下載 `Lisvo-版本.zip`，解壓縮後把 `Lisvo.app` 拖進「應用程式」資料夾。
繁體中文系統上，App 會顯示成「聽字」。

### 第一次打開會被 macOS 擋下

Lisvo 沒有經過 Apple 公證（notarization）。公證要先加入 Apple 付費開發者計畫（每年 99 美元），
這個專案目前沒有付費，所以第一次打開時 macOS 會跳出「無法打開」的警告。許多個人開發的免費、開源 Mac App 也是這樣發佈。
程式碼全部公開在這裡，不放心的話可以自己從原始碼建置（見下方「開發」）。

照下面做一次就好，之後可以直接打開：

1. 在「應用程式」資料夾雙按 Lisvo，出現警告時按「完成」。
2. 選擇「蘋果」選單 >「系統設定」，在側邊欄按「隱私權與安全性」。
3. 往下捲到「安全性」，Lisvo 那一行按「打開」，再按「強制打開」。這個按鈕在嘗試打開後約一小時內才會出現，過了就回到第 1 步重來。
4. 輸入登入密碼，按「好」。

步驟依照 Apple 的說明〈[打開未識別開發者的 Mac App](https://support.apple.com/zh-tw/guide/mac-help/mh40616/mac)〉。

### 其他限制

- 只支援 Apple 晶片的 Mac、macOS 26 以上（見「系統需求」）。
- 每次更新到新版，macOS 都會把它當成新的 App：「螢幕與系統錄音」與「麥克風」權限要重新允許，上面的打開步驟可能也要再做一次。
- 精準模式第一次使用會下載 Whisper 模型，分講者第一次使用會下載分講者模型，都要連網。
- 第三方套件的授權全文放在 App 裡：在 `Lisvo.app` 按右鍵「顯示套件內容」，位置是 `Contents/Resources/Licenses`。

## 開發

需要 Xcode 26 以上（macOS 26 SDK）。

```bash
# 組成 build/Lisvo.app
scripts/build-app.sh

# 組成發佈用的 build/Lisvo-版本.zip（上傳到 GitHub Releases）
scripts/package-release.sh

# 改了 Resources/Icon/AppIcon.svg 之後，重新產生 App 圖示（需要 brew install librsvg）
scripts/make-icon.sh

# 命令列測試：和 App 走同一套流程
swift run transcriber-cli 音檔.m4a --mode accurate --lang zhTW --speakers auto --polish

# 模擬即時字幕：照真實速度一段一段送進辨識器，印出暫定與定案文字和延遲（加 --bilingual 同時跑英文辨識器）
swift run transcriber-cli 音檔.m4a --live --speed 1
```

模型存放位置：

- Whisper：`~/Library/Application Support/Lisvo/Models/Whisper`
- 分講者：`~/Library/Application Support/Lisvo/Models/Diarization`
- 快速模式與即時翻譯的語言包由系統管理

簽署：鑰匙圈裡有名為「Lisvo Local Signing」的自簽程式碼簽署憑證時用它簽，否則用臨時簽署（ad-hoc）。
臨時簽署每次重新建置，macOS 都當成新的 App，「螢幕與系統錄音」權限要重新允許；用固定憑證就不用。
也可以用環境變數 `LISVO_SIGN_IDENTITY` 指定其他憑證名稱。

## 程式結構

- `Sources/TranscriberCore`：音檔轉換、兩個辨識引擎、分講者、講者對應、潤飾、匯出、整體流程、即時字幕與即時翻譯、iPhone 收件
- `Sources/TranscriberApp`：SwiftUI 介面
- `Sources/transcriber-cli`：命令列測試工具

## 第三方元件

都不放在本專案裡：套件由 Swift Package Manager 建置時下載，模型由 App 第一次使用時下載。

| 元件 | 用途 | 授權 |
|---|---|---|
| [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) | 精準模式的 Whisper 執行環境 | MIT |
| [Whisper large-v3-turbo（Core ML 版）](https://huggingface.co/argmaxinc/whisperkit-coreml) | 精準模式的辨識模型，原始模型為 OpenAI Whisper | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 分講者流程 | Apache 2.0 |
| [speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml) | 分講者模型，由 [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) 轉換 | CC BY 4.0 |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | WhisperKit 的相依套件 | Apache 2.0 |

分講者方法出自 pyannote 分段（Plaquet & Bredin, 2023）、WeSpeaker 聲紋（Wang et al., 2023）與 VBx 分群（Landini et al., 2022）。

## 授權

[Apache License 2.0](LICENSE)，© 2026 ArchCross。「Lisvo」「聽字」名稱與 App 圖示不隨授權開放當作商標使用，見 [NOTICE](NOTICE)。
