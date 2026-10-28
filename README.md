# Lisvo（聽哦）

Mac 原生的語音轉文字 App：分講者、輸出時間軸，全部在本機處理，不上傳錄音。

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

## 開發

```bash
# 組成 build/Lisvo.app（本機臨時簽署）
scripts/build-app.sh

# 命令列測試：和 App 走同一套流程
swift run transcriber-cli 音檔.m4a --mode accurate --lang zhTW --speakers auto --polish
```

模型存放位置：

- Whisper：`~/Library/Application Support/Lisvo/Models/Whisper`
- 分講者：`~/Library/Application Support/Lisvo/Models/Diarization`
- 快速模式的語言包由系統管理

## 程式結構

- `Sources/TranscriberCore`：音檔轉換、兩個辨識引擎、分講者、講者對應、潤飾、匯出、整體流程
- `Sources/TranscriberApp`：SwiftUI 介面
- `Sources/transcriber-cli`：命令列測試工具
