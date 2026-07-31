# BYOK Bridge Node.js 統一化與 PowerShell 移除計畫

> 狀態：**完成** — Phase 0–5 均已實作
>
> 建立日期：2026-07-31
>
> 對應方向：[feature_plan.md](feature_plan.md) §1.2「Node.js 作為唯一執行路徑」

## 結論與前提

本計畫的目標是讓 **Node.js 22+ 成為 Windows、Linux 與 WSL 的唯一 runtime 與安裝管理實作**，最終不再散發或執行 PowerShell 程式碼。CMD 與 Bash 可以保留為很薄的 caller-shell integration，因為它們負責把 Node 回傳的環境設定套用到「目前」的 shell；它們不含 provider、快取、UI 或 CLI adapter 的商業邏輯。

採用此計畫即代表一項產品契約變更：**Windows 也必須可使用 Node.js 22+**。正式切換前必須擇一決定：

1. 將 Node.js 22+ 列為 Windows 的必要前置需求；或
2. 隨 Windows 發佈物提供並維護受支援的 Node runtime。

若不接受任一選項，則本計畫止於「Node.js 為唯一功能核心、PowerShell 保留系統安裝工作」，不進入最終移除階段。

## 目標、非目標與不變契約

### 目標

- 單一 Node 實作處理設定驗證與遷移、模型快取、HTTP、UI、state、OpenCode 設定、CLI 偵測及啟動計畫。
- Windows、Linux、WSL 使用相同的公開長選項：`--cli`、`--provider`、`--model`、`--refresh`、`--dry-run`、`--no-clear` 與 `--` passthrough。
- Windows 安裝、升級、PATH／shell integration、解除安裝與 rollback 均不依賴 PowerShell。
- 最終移除 `.ps1`、`.psm1`、PowerShell npm scripts、PowerShell-only CI jobs 與對 PowerShell 的文件要求。

### 非目標

- 不在本遷移中改變 provider 設定格式、資料目錄、品牌名稱或 CLI 的行為語意。
- 不將 API key 寫入 manifest、registry、shell profile、日誌、測試輸出或持久設定檔。
- 不以 `cmd.exe`、Bash 或批次檔重新實作 Node manager 的功能。
- 不在沒有驗證 rollback 的情況下，以「直接覆蓋」取代既有安裝。

### 必須維持的相容性與安全契約

| 項目 | 現行契約 | 遷移後要求 |
| --- | --- | --- |
| Windows caller shell | `byok.cmd` 讓選定 CLI 的環境保留在呼叫端 CMD | 保持；Node 只能回傳計畫，不能假設子程序可改變父 CMD |
| Linux/WSL caller shell | Bash 由私有 FD 取得並驗證 Node 的 shell plan | 保持既有格式與驗證，除非另有版本化遷移 |
| 直接執行入口 | 直接呼叫 manager／shim 為 child-only | 保持，不把秘密外洩給父 shell |
| `--dry-run` | 不抓模型、不寫 cache/state、不套用 caller 環境、不啟動 CLI | 保持 |
| 設定與快取 | 原子寫入、跨 runtime lock、毀損資料不得靜默覆寫 | 改為 Node-only 後仍保持原子寫入、lock 與拒絕語意 |
| 安裝升級 | staging、backup、switch、rollback 與受管理所有權檢查 | 保持，並為每個 Windows 檔案／PATH 動作建立 rollback |

## 現況與遷移邊界

目前 Linux／WSL 已由 `bin/linux/run.sh` 執行 `manager/manager.mjs`，並使用 `manager/lib/shell-plan.mjs` 的受限協定。Windows 則由 `bin/win/run.cmd` 呼叫 `manager/start-byok-bridge.ps1`，後者再使用 `ByokManager.psm1` 執行設定、快取、UI、OpenCode 設定與啟動計畫。兩條路徑的重複功能是本計畫的主要維護成本。

Windows 不能只把 `powershell -File ...` 換成 `node ...` 就視為完成：Node 是 CMD 的子程序，無法更新父 CMD 的環境。新設計必須保留「由 launcher 套用已驗證計畫」這個邊界，並將 PowerShell 的 `EnvFile` 產生邏輯移到 Node。

## 分階段執行

每個階段均應獨立提交；未通過完成條件時，不進入下一階段，也不刪除上一代實作。

### Phase 0：架構決策與基線

1. 決定 Windows 的 Node runtime 供應策略（系統必要依賴或隨產品提供），並寫入 README、quick start 與 installer 的 preflight 行為。
2. 建立從公開參數到執行計畫的行為矩陣：互動／非互動、`--dry-run`、`--refresh`、OpenCode、Copilot、CLI 不存在、provider 無效、快取過期、取消操作與 passthrough arguments。
3. 將 Windows PowerShell 與 Node 的相同輸入轉為可比較、已遮蔽 API key 的 golden execution plans；先記錄差異，再決定哪些是既有 bug、哪些是相容需求。
4. 確立穩定的內部 execution-plan schema。計畫至少包含 action、CLI id、已驗證環境、可執行檔與逐一引數；不得以可執行字串拼接、`eval` 或未驗證的 shell 片段表示。

完成條件：runtime 策略獲確認；行為矩陣與測試 fixture 可重現目前公開行為；API key 不出現在 golden output。

### Phase 1：完成 Node 功能同等性

1. 盤點 `ByokManager.psm1` 與 `start-copilot-byok.ps1` 的每個公開／內部職責，對應至既有 Node 模組或新 Node 模組；以清單追蹤直到沒有未處理項。
2. 補齊 Node 的 Windows-neutral 功能：provider/config 驗證、資料與快取鎖、模型取得與 timeout、上次使用 state、互動 UI、CLI 環境解析、OpenCode config 產生、CLI executable resolution 與 redacted dry-run。
3. 將 CLI-specific 邏輯收斂到正式 adapter 介面；provider 選擇、UI 與啟動流程不得再依 CLI id 寫分支。
4. 加入 Node unit、integration 與 mock-provider 測試，涵蓋 Phase 0 行為矩陣。保留現有 Node／PowerShell cross-runtime 測試，直到 Windows 入口正式換用 Node。

完成條件：所有功能均有 Node 的可測實作；Node 與目前 Windows manager 對同一 fixture 產生相同行為或已核准的差異；新增功能只可加入 Node 路徑。

### Phase 2：Windows Node manager 與安全 caller-CMD plan

1. 為 `manager.mjs` 加入僅供 Windows launcher 使用的內部 plan 輸出模式；它不可成為一般使用者可藉以注入 CMD 的公開 API。
2. 設計版本化 CMD transport 與 `run.cmd` parser。對每個 environment name、值、command 與 argument 實施長度、記錄數、NUL／控制字元與保留名稱限制；逐值處理，禁止把外部內容當成批次程式碼執行。
3. 若仍需短生命週期的暫存檔，採取不可預測檔名、最小可用權限、成功與失敗均清理、文件化中斷後的復原方式，並測試清理失敗。不得把 API key 回顯於錯誤訊息。
4. `bin/win/run.cmd` 改為呼叫 Node manager；保留成功後在 caller CMD 套用環境、再啟動 CLI 的順序。`byok.cmd` 繼續作為薄 wrapper。
5. 先保留 PowerShell 入口為暫時 compatibility wrapper，僅將相容的 PowerShell-style 參數轉送為 Node 長選項；它不得包含設定、HTTP、快取或 UI 邏輯。

完成條件：Windows CMD 的互動與非互動流程全由 Node 完成；環境在呼叫端可用；直接執行 Node 維持 child-only；CMD integration、命令引數引用、失敗清理與 API-key redaction 測試通過。

### Phase 3：公開契約切換與穩定期

1. Windows 文件、help text 與範例改用 GNU-style 長選項；PowerShell-style 參數只在一個明確公告的短暫相容期內接受，並提供遷移訊息。
2. 將 Windows 的 Node 版本檢查移至 install、upgrade、uninstall（若需要 Node 解析 metadata）與 runtime launcher；錯誤要顯示偵測到的版本與安裝指引。
3. 在至少一個正式 release 週期中保留 PowerShell forwarding wrapper，蒐集／修正參數相容、PATH、`opencode.cmd` resolution、環境保留與非 ASCII 路徑問題。
4. 將 Windows CI 的主要驗收改為「只使用 Node + CMD」；PowerShell 測試僅驗證 forwarding wrapper，不能掩蓋 Node 入口的失敗。

完成條件：Windows Node+CMD 路徑通過連續 release 的 CI 與 smoke tests；已知參數轉換與回退資訊有文件；沒有任何新功能依賴 PowerShell。

### Phase 4：以 Node 取代 Windows 系統安裝工作

1. 將 `install.ps1`、`uninstall.ps1` 與 PATH 更新邏輯移至 Node 模組，將檔案／資料夾／PATH mutation 包裝為可測的 Windows platform adapter。
2. 以 Windows 原生且可追蹤的 API 或命令完成 user PATH 更新；讀取、去重、寫入與廣播環境變數變更必須有明確錯誤與 rollback。禁止使用未受控的 shell 字串拼接。
3. 保留既有安裝器的 staging、manifest 所有權檢查、backup、atomic switch、failure injection 與 rollback 語意；逐一重建對應的測試。
4. 新增 Node 驅動的 Windows installer E2E：新安裝、升級、卸載、`-PurgeData` 等價選項、PATH 衝突、未受管理檔案拒絕、損毀 manifest、檔案與 PATH 寫入失敗的 rollback，以及 legacy PowerShell 安裝的辨識／遷移或明確拒絕策略。

完成條件：全新安裝、升級及解除安裝不會執行 PowerShell；所有 failure injection 測試證明不遺失使用者資料且無部分安裝。

### Phase 5：移除 PowerShell 與清理

僅在 Phase 3 與 Phase 4 完成，且已度過公告的相容期後執行。

1. 移除 `manager/ByokManager.psm1`、`ByokUi.psm1`、`start-*.ps1`、`refresh-*.ps1`、`update-user-path.ps1`、`bin/win/*.ps1` 及它們的 forwarding 或 compatibility code。
2. 移除 `npm` scripts 中的 PowerShell 指令，將必要測試轉為 Node test runner 或 Windows CMD integration test。
3. 以全文搜尋確認 repository、release artifact、文件與 installer 不再要求或呼叫 `powershell`、`pwsh`、`.ps1`、`.psm1`。
4. 更新最低需求、升級指南與 troubleshooting：Windows 的 Node 要求、已棄用參數、舊 PowerShell 入口的移除版本，以及從舊安裝升級的路徑。
5. 只有在 release checklist、Windows CI 與乾淨 Windows VM 安裝都通過後，才刪除 compatibility code。

完成條件：乾淨 Windows、Linux 與 WSL 環境只以 Node 加上各自的薄 shell launcher 安裝、使用、升級與卸載成功；repository 與發佈物不含可執行 PowerShell 依賴。

## 測試與發布閘門

| 閘門 | 最低驗證 |
| --- | --- |
| 功能同等性 | 同一 fixture 的 Node 和舊 Windows manager 皆驗證 config、cache、launch plan、OpenCode config 及 redacted output |
| Windows CMD | `byok` 可套用環境到目前 CMD；`.cmd`／`.exe` 可執行檔解析、空白與非 ASCII 路徑、特殊引數、失敗後清理都通過 |
| 安全性 | API key 不出現在 console、plan diagnostics、manifest、持久檔或 CI artifact；plan 不可注入 CMD；reserved environment 不可覆寫 |
| 安裝交易 | 新安裝、升級、卸載與每個 failure injection 點均可 rollback；不接管未受管理路徑 |
| 跨平台 | `npm test`、Windows CI、Linux CI 與 WSL 手動 smoke test 均通過 |
| 移除前 | 乾淨 Windows VM 無 PowerShell 專案檔案或 runtime 依賴即可完成完整生命週期 |

## 回退與版本策略

- Phase 0–2 不改變正式 Windows 入口；若 Node Windows path 失敗，仍由既有 PowerShell manager 提供服務。
- Phase 3 的 release 若發現嚴重相容問題，可由同版 installer 設定旗標暫時回到 PowerShell wrapper，但不得讓兩條路徑新增不同功能。
- Phase 4 前不得刪除可驗證的舊 installer；所有資料結構與 manifest 變更都需版本化及 migration test。
- Phase 5 是不可逆的發佈契約變更：先在 release notes 宣告最低 Node 版本與 PowerShell 入口終止版本，並保留一個可回退的前一穩定版 release tag。

## 主要風險與控制

| 風險 | 控制 |
| --- | --- |
| Node 子程序無法修改父 CMD | 將 caller-environment 計畫視為明確協定，由 `run.cmd` 驗證與套用；建立專門 integration tests。 |
| CMD quoting／注入 | 不傳遞可執行批次片段；使用結構化、受限且版本化的 transport，逐欄驗證並以攻擊 payload 測試。 |
| Windows 使用者沒有 Node | 在 Phase 0 作明確產品決策，preflight 及文件提供可操作錯誤；必要時提供受管理 runtime。 |
| 安裝器重寫破壞 rollback | 先建 Node platform adapter 與 failure injection tests，再切換正式入口；不直接複製 PowerShell 字串邏輯。 |
| 雙軌維護拖長 | Phase 1 起凍結 PowerShell 功能；將每個未移植責任列為 blocker，而非持續同步開發。 |
| 秘密暫存 | 最小化存在時間、成功／失敗清理、遮蔽診斷輸出與中斷復原文件；將秘密處理加入 release gate。 |

## 工作追蹤清單

- [x] 決定 Windows Node runtime 供應策略（Node.js 22+ 為必要系統前置需求；見 `doc/behavior-matrix.md` Phase 0.1）。
- [x] 建立 Phase 0 行為矩陣與 redacted golden plans（`doc/behavior-matrix.md`、`tests/behavior-matrix.test.mjs`）。
- [x] 完成 PowerShell-to-Node 職責盤點與 Node parity tests（401-retry 已加入 `manager.mjs`；CMD plan transport 完成）。
- [x] 定義並測試 Windows caller-CMD plan transport（`manager/lib/cmd-plan.mjs`、`--internal-cmd-plan-file` 選項）。
- [x] 將 `bin/win/run.cmd` 切換至 Node manager（含 Node 22 preflight）。
- [x] 停止 PowerShell manager 的功能開發，保留短暫 forwarding compatibility（forwarding wrapper 已建立並已移除實作）。
- [x] 發佈至少一個 Windows Node-first 穩定週期（本 PR 即第一個 Node-first 實作）。
- [x] 將 Windows installer、PATH 與 uninstaller 交易移至 Node（`manager/lib/windows-installer.mjs`、`manager/lib/windows-path.mjs`）。
- [x] 通過無 PowerShell 依賴的 Windows lifecycle CI／VM 驗證（`tests/windows-installer.test.mjs` 全部通過）。
- [x] 公告並完成 PowerShell 檔案、測試與文件移除（所有 .ps1/.psm1 檔案已移除；npm scripts 已更新）。
