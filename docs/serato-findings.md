# Serato 資料來源實測結論（Phase 0）

> 狀態：**完成，資料來源可行**。唯一未在現場觀察到的是「接器材時開始播放的更新」，目前由有器材 session 的 log 推得（§3.4），建議 Phase 3 前接 DJM-S11 再確認一次。

## 0. 環境與工具

- Serato DJ Pro **4.0.1.1508**（bundle id `com.serato.seratodj`），macOS 27；平常搭配 Pioneer DJM-S11
- 工具：`Packages/AmaterasuCore` 的 `serato-probe`
  - `schema` / `sessions` / `dump [--full]`：Serato 執行中以唯讀方式讀即時資料庫，否則讀暫存副本
  - `watch`：偵測 `-wal` / 資料庫檔的變動，有變動才開唯讀連線查詢、查完即關；印出每次變動的欄位差異，同時追蹤 Serato 自己的 log 計算延遲
- 資料：
  - 離線：`master.sqlite` 副本、session #85（2026-11-06 19:59–21:00，有接 DJM-S11，25 筆）與當次 Serato log
  - 現場第一輪：session #86（23:03–23:06，沒接器材，4 筆）
  - 現場第二輪：session #87（23:57–23:59，沒接器材，1 筆）

## 1. 結論

| 問題 | 結論 |
|---|---|
| 資料來源可行嗎？ | **可行**。Serato 在事件當下就 commit，延遲只取決於我們多久檢查一次 |
| 延遲 | Serato log 時間戳 → 我們讀到：**+0.01 ～ +0.24 秒**（每 0.25 秒檢查一次） |
| 每次查詢成本 | 真實資料庫（80 MB）上 **1–7 ms**（第一次含結構檢查 11 ms） |
| 有 deck 編號嗎？ | 有，`deck` = `"1"`–`"4"` |
| 載入 | 立即新增一列；deck 停著時 `played = 0`，deck 已在播放時直接 `played = 1` |
| 開始播放 | `played` 0 → 1 的 UPDATE，時間點即開始播放（推論自有器材 session，§3.4） |
| 暫停 / 繼續 | **不寫入**，無法得知 |
| 換歌 / 退出 | 立即寫入舊列的 `end_time`；換歌時約 50 ms 後新增新列 |
| 目前 session | 最新一筆且 `end_time = -1`；session 在第一次載入時才建立 |
| 音檔路徑 | 本機檔案為 `"/" + portable_id`；Spotify 為 `streaming://…` 無檔案；外接硬碟未驗證 |
| 讀取會影響 Serato 嗎？ | 常駐連線會讓 Serato 結束時無法清除 WAL；**改為不常駐連線後無影響** |

## 2. 已確認（離線）

### 2.1 位置與格式
- `~/Library/Application Support/Serato/Library/master.sqlite`，**WAL 模式**；`serato-probe schema` 檢查結果相容
- 舊版 `~/Music/_Serato_/History/Sessions/` 不存在
- 歷史資料表：`history_session`、`history_entry`（欄位見 spec §4）

### 2.2 Deck 編號
- `history_entry.deck` 為 TEXT `"1"`–`"4"`；全部歷史中 deck 1：2154 筆、deck 2：1062 筆、deck 3：8 筆、deck 4：1 筆（3、4 只出現在 session #79）

### 2.3 Serato log 與資料庫一一對應
- Serato log（`~/Music/_Serato_/Logs/DJ.INFO` → 當次 log 檔，時間精度到微秒）每次寫入歷史都留下 `[Library]` 紀錄：`Adding entry to history session with id <session>`、`Updating entry with id <entry>`、`Ending history session with id <session>`
- session #85：25 次 Adding、40 次 Updating，對應 25 筆 entry

### 2.4 孤兒列
- #3207（deck 2、`played = 0`、`end_time = -1`）與 #3208（deck 2、`played = 1`）`start_time` 相同；log 中 #3207 **從未被更新**，session 結束後仍是 `end_time = -1`
- 兩組重複（#3207/#3208、#3210/#3211）都發生在 deck 2 載入「deck 1 正在放的同一首」時；沒接器材時用 instant doubles 未能重現
- 結論：**不能只用 `end_time = -1` 判斷「目前在 deck 上」**，以每個 deck 最新一列（最大 `id`）為準

### 2.5 曲目資訊
- `name`、`artist`、`bpm`、`key`、`key_value` 都在同一列，**不需要另外 join `asset`**
- `key_value`：0–11 = 1A–12A、12–23 = 1B–12B、-1 = 未分析，已與 spec §6 對照表逐一核對；`key` 字串格式混雜（`Abm`、`G#m`、`1A`、`C#m`、`Dbm`…）
- 全部 3225 筆中：`bpm` 為 NULL 11 筆、`key_value = -1` 4 筆，**全部是本機檔案**；Spotify 串流的 11 筆 BPM / Key 都有值
- BPM 常是 half-time 的分析結果（例：62.5、62.0、58.0）

### 2.6 音檔路徑
- `location.path` 全部為 NULL，location 以 `uuid`（推測為磁碟區 UUID）識別
  - location 1：本機磁碟，3214 筆；完整路徑 = `"/" + portable_id`（session #85 的 25 筆檔案全部存在）
  - location 2：Spotify，`portable_id` 形如 `streaming://spotify/<id>`，沒有本機檔案
- 外接硬碟上的歌：歷史中沒有樣本，**路徑規則未驗證**

## 3. 現場實測

### 3.1 第一輪（session #86，沒接器材）

| 時間 | 動作（由資料推得） | 資料庫 | Serato log → 我們讀到 |
|---|---|---|---|
| 23:03:31 | 啟動 Serato | 約 11 次與歷史無關的 commit（曲庫、iTunes 匯入）；**還沒有新 session** | — |
| 23:03:44 | 載入 deck 1 | **新 session #86 建立**；#3226 新增，`played = 1` | +0.22 s |
| 23:04:12 | 載入 deck 2 | #3227 新增，`played = 1` | +0.09 s |
| 23:05:40 | 同一首載入 deck 2（instant doubles） | #3227 寫入 `end_time`；#3228 新增（只有一列） | +0.19 s / +0.14 s |
| 23:05:56 | 換 deck 1 的歌 | #3226 寫入 `end_time`；#3229 新增 | +0.11 s / +0.06 s |
| 23:06:01 | 退出 deck 2 | #3228 寫入 `end_time`，沒有新增 | +0.24 s |
| 23:06:08 | 關閉 Serato | #3229 寫入 `end_time`；session `end_time` 寫入；接著備份資料庫 | +0.01 s |

### 3.2 第二輪（session #87，沒接器材）
- 23:57:46 載入 deck 1 → #3230 新增，`played = 1`（+0.08 s）
- 之後播放、暫停、繼續播放期間（約 1 分 40 秒），`history_entry` **沒有任何變動**
- 23:59:29 關閉 Serato → 寫入 `end_time`、session 結束；**2 秒後 `-wal` 已被清除**
- 每次查詢 1–7 ms

### 3.3 沒接器材時的行為不具代表性
- Serato log 的 `AudioRenderSummary`：有器材的 session 是 `Online`（123 次），兩輪實測都是 `Offline`
- 沒接器材時，每次載入都直接標為 `played = 1`，之後不再更新
- Serato 在提示「To play or pause decks use the W key…」時也會 commit（第一輪 23:03:53、23:04:21，第二輪 23:58:18），與歷史無關

### 3.4 開始播放與暫停：由有器材的 session #85 推得
比對 Serato log 中每筆 entry 的 `Updating entry` 次數：

| 類型 | 筆數 | 更新 | 解讀 |
|---|---|---|---|
| 新增時 `played = 0`，最後 `played = 1` | 16 | 2 次：載入後 0–37 秒一次、換下時一次 | 第一次更新 = 開始播放（`played` 0 → 1） |
| 新增時就是 `played = 1` | 6 | 1 次：換下時 | 載入到已在播放的 deck（例：DVS 唱盤持續轉動） |
| 從未播放 `played = 0` | 3 | 0–1 次 | 載入後沒播就被換下（含 1 筆孤兒列） |

- **每筆最多 2 次更新**，即使在 deck 上 25 分鐘也一樣 → 暫停 / 繼續不寫入
- 待確認：接 DJM-S11 時現場觀察 `played` 0 → 1 的那次更新（預期延遲與其他寫入相同，< 0.25 s）

### 3.5 讀取端對 Serato 的影響
- 第一輪 probe 常駐一條唯讀連線，Serato 結束時無法清除 WAL，`master.sqlite-wal`（5.5 MB）與 `-shm` 殘留；同時間 probe 沒開過的 `root.sqlite` 正常清除 → 確定是 probe 造成
- 殘留的 WAL 不會損壞資料：第二輪 Serato 開啟時正常接手（啟動時 WAL 5.5 MB），結束時正常清除
- 改為**不常駐連線**後，第二輪結束 2 秒內 `-wal` 已清除

## 4. Serato log 的定位
- 優點：微秒時間戳；`Updating entry with id <entry>` 帶有 entry id
- 缺點：私有格式、可能隨版本改變；寫入檔案有 0.1–1.5 秒緩衝，比資料庫慢
- 定位：只在 Phase 0 用來量測延遲；v1 不使用

## 5. 對後續 Phase 的影響
- 變動偵測：**不常駐連線**；監聽 `-wal` 與資料庫檔的 mtime / size，有變動才開唯讀連線查詢、立刻關閉
- 目前 session：最新一筆且 `end_time = -1`；否則代表 Serato 開著但還沒載入任何歌 → 面板顯示「等待 Serato…」
- 目前在 deck 上：每個 deck 取目前 session 中最新一列，且該列 `end_time = -1`（退出後即清空該 deck）
- 播放狀態：只能知道「這首已開始播放過」（`played = 1`），**無法知道是否暫停中**
- 開始播放時間：觀察到 `played` 0 → 1 的時間；新增時就是 `played = 1`、或 App 中途啟動時，用 `start_time`
- 主 deck：已開始播放的 deck 中，開始播放時間最晚者；使用者可手動指定
- BPM / Key 補值：只對本機檔案（location 1）讀 tag；串流曲目不補
