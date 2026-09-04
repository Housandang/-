#Requires AutoHotkey v2.0
#SingleInstance Force   ; 既存のインスタンスを確認なしで自動終了・上書き

; ================================================================
; ★ DPI認識（変更不要・スクリプト内で一番最初に実行される必要がある）
;    これを宣言しないと、ディスプレイの拡大率が100%以外（125%/150%など）
;    の環境で、参照ウィンドウをドラッグでリサイズした際に「マウスの移動量」
;    と「実際に変化するウィンドウサイズ」が一致しない（Windowsが座標を
;    仮想的にスケーリングして扱うため）。必ず最初のGui作成より前、
;    スクリプトのできるだけ早い位置に置くこと。
;    Windows 10 1703+ → Windows 8.1+ → Vista+ の順にフォールバックする。
; ================================================================
try DllCall("SetProcessDpiAwarenessContext", "ptr", -4)          ; Per-Monitor V2
catch {
    try DllCall("Shcore\SetProcessDpiAwareness", "int", 2)       ; Per-Monitor
    catch {
        try DllCall("SetProcessDPIAware")                        ; System DPI Aware（最終手段）
    }
}

; ================================================================
; ★ Discord Webhook 設定
;    サボりを検知したとき・ロック中にタイマーを終了したときに
;    指定のチャンネルへ通知を送ります。
;    URL を空文字にすると通知を無効化できます。
; ================================================================
discordWebhook := "https://discord.com/api/webhooks/1514960540949282948/QWx9sLWEDVBct8MUXU5EvsgiGKcY5C3BRriVil5Ye_yM2hvCKJPfFdI-MryZNVmhDXBS?thread_id=1514960461815353394"

; ===== ランチャーとのフェーズ共有（変更不要）=====
; launcher.ahk がこのファイルを読んでロック中かどうかを判定します。
global phaseFilePath := A_ScriptDir "\current_phase.txt"
global isCroquis     := false   ; 起動モード判定より先に宣言（OnExit から参照するため）

WritePhase(phase) {
    _path := A_ScriptDir "\current_phase.txt"
    if (phase = "")
        SafeDeleteFile(_path)
    else
        SafeWriteFile(_path, phase)
}

; ================================================================
; ★ 複数プロセスからの同時アクセス対策（変更不要）
;
;    current_phase.txt・work_goal.txt・overtime_work.txt・day_state.txt は
;    lock_window.ahk と launcher.ahk の両方から読み書きされる共有ファイル。
;    お互い独立したプロセスなので、書き込み中のファイルを別プロセスが
;    ちょうど同時に読もうとする（あるいはその逆）と、Windowsのファイル共有
;    違反（エラー32「別のプロセスが使用中です」）が発生することがある。
;    通常は一瞬で解消される一時的な競合なので、短い待機を挟んで
;    数回リトライすることで対処する。
; ================================================================
SafeReadFile(path, retries := 5, delayMs := 30) {
    loop retries {
        try
            return FileRead(path)
        catch {
            Sleep(delayMs)
        }
    }
    return ""
}

SafeDeleteFile(path, retries := 5, delayMs := 30) {
    loop retries {
        try {
            FileDelete(path)
            return true
        } catch {
            Sleep(delayMs)
        }
    }
    return false
}

SafeWriteFile(path, content, retries := 5, delayMs := 30) {
    loop retries {
        SafeDeleteFile(path, 1, 0)   ; 無ければ無いで良いので1回だけ試して失敗は無視
        try {
            FileAppend(content, path)
            return true
        } catch {
            Sleep(delayMs)
        }
    }
    return false
}

OnExit(CleanupPhaseFile)
CleanupPhaseFile(reason, code) {
    ; g がまだ初期化されていない段階での終了に備えてフォールバック
    currentPhase := ""
    try currentPhase := g.phase

    ; フェーズファイルの実際の内容を読む
    ; （g.phase が "break" のままでも WritePhase("croquis_done") 済みの場合があるため）
    actualPhase := Trim(SafeReadFile(A_ScriptDir "\current_phase.txt"))

    ; croquis_done はlauncherが読むまで保持する
    if (actualPhase != "croquis_done")
        WritePhase("")
    NextDnsUnblock()

    ; クロッキー中の終了は対象外
    if (isCroquis)
        return

    goalReached := false
    try goalReached := g.workGoalReached

    setInfo := ""
    try setInfo := " [Set " g.currentSet "/" g.totalSets "]"

    if (currentPhase = "lock") {
        ; ロック中の終了は常に通知
        SendDiscordAlert("⚠️ **ロック中にタイマーを終了しました**" setInfo " " FormatTime(, "HH:mm"))
    } else if ((currentPhase = "break" || currentPhase = "intermission") && !goalReached) {
        ; 休憩・中休み中でも、作業ノルマ（totalWorkGoalMinutes）未達成なら通知
        ; 達成済みなら休憩中の終了は正当な終了とみなし、通知しない
        label := (currentPhase = "intermission") ? "中休み" : "休憩"
        SendDiscordAlert("⚠️ **ノルマ未達成のまま" label "中にタイマーを終了しました**" setInfo " " FormatTime(, "HH:mm"))
    }
}

; ===== Discord 通知（変更不要）=====
SendDiscordAlert(msg) {
    global discordWebhook
    if (discordWebhook = "")
        return
    try {
        safe := StrReplace(StrReplace(msg, '"', "'"), "`n", "\n")
        body := '{"content": "' safe '"}'
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("POST", discordWebhook, false)
        http.SetRequestHeader("Content-Type", "application/json")
        http.Send(body)
    }
}

; ===== NextDNS ブロック・解除（変更不要）=====
; parentalControl/categories エンドポイントでカテゴリ単位でブロックします。
NextDnsBlock() {
    global nextdnsEnabled, nextdnsApiKey, nextdnsProfile, nextdnsCategories, nextdnsServices, nextdnsBlockList
    if (!nextdnsEnabled)
        return
    psPath  := A_Temp "\ndns_block.ps1"
    logPath := A_Temp "\ndns_block_log.txt"
    try FileDelete(psPath)
    try FileDelete(logPath)
    q  := Chr(34)
    ps := "$headers = @{" . "`n"
    ps .= "    " q "X-Api-Key" q " = " q nextdnsApiKey q "`n"
    ps .= "}" . "`n"
    for cat in nextdnsCategories {
        body := "{" q "id" q ":" q cat q "," q "active" q ":true}"
        ps .= "$body = '" body "'" . "`n"
        ps .= "try {`n"
        ps .= "    Invoke-WebRequest -Uri " q "https://api.nextdns.io/profiles/" nextdnsProfile "/parentalcontrol/categories" q " -Method POST -Headers $headers -Body $body -ContentType " q "application/json" q " -UseBasicParsing | Out-Null`n"
        ps .= "    Add-Content -Path " q logPath q " -Value " q "OK: " cat q "`n"
        ps .= "} catch {`n"
        ps .= "    Add-Content -Path " q logPath q " -Value (" q "ERR: " cat " " q " + " . '$_.Exception.Message)' . "`n"
        ps .= "}`n"
    }
    ; denylist（個別ドメイン）ブロックも追加
    for domain in nextdnsBlockList {
        body := "{" q "id" q ":" q domain q "," q "active" q ":true}"
        ps .= "$body = '" body "'" . "`n"
        ps .= "try {`n"
        ps .= "    Invoke-WebRequest -Uri " q "https://api.nextdns.io/profiles/" nextdnsProfile "/denylist" q " -Method POST -Headers $headers -Body $body -ContentType " q "application/json" q " -UseBasicParsing | Out-Null`n"
        ps .= "    Add-Content -Path " q logPath q " -Value " q "OK(deny): " domain q "`n"
        ps .= "} catch {`n"
        ps .= "    Add-Content -Path " q logPath q " -Value (" q "ERR(deny): " domain " " q " + " . '$_.Exception.Message)' . "`n"
        ps .= "}`n"
    }
    ; サービス個別ブロックも追加
    for svc in nextdnsServices {
        body := "{" q "id" q ":" q svc q "," q "active" q ":true}"
        ps .= "$body = '" body "'" . "`n"
        ps .= "try {`n"
        ps .= "    Invoke-WebRequest -Uri " q "https://api.nextdns.io/profiles/" nextdnsProfile "/parentalcontrol/services" q " -Method POST -Headers $headers -Body $body -ContentType " q "application/json" q " -UseBasicParsing | Out-Null`n"
        ps .= "    Add-Content -Path " q logPath q " -Value " q "OK(svc): " svc q "`n"
        ps .= "} catch {`n"
        ps .= "    Add-Content -Path " q logPath q " -Value (" q "ERR(svc): " svc " " q " + " . '$_.Exception.Message)' . "`n"
        ps .= "}`n"
    }
    FileAppend(ps, psPath, "UTF-8-RAW")
    Run('powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File "' psPath '"',, 'Hide')
    TrayTip("📵 スマホブロック有効", "NextDNS でサービスをブロックしました", "Mute")
}

NextDnsUnblock() {
    global nextdnsEnabled, nextdnsApiKey, nextdnsProfile, nextdnsCategories, nextdnsServices, nextdnsBlockList
    if (!nextdnsEnabled)
        return
    psPath  := A_Temp "\ndns_unblock.ps1"
    logPath := A_Temp "\ndns_unblock_log.txt"
    try FileDelete(psPath)
    try FileDelete(logPath)
    q  := Chr(34)
    ps := "$headers = @{" . "`n"
    ps .= "    " q "X-Api-Key" q " = " q nextdnsApiKey q "`n"
    ps .= "}" . "`n"
    for cat in nextdnsCategories {
        ps .= "try {`n"
        ps .= "    Invoke-WebRequest -Uri " q "https://api.nextdns.io/profiles/" nextdnsProfile "/parentalcontrol/categories/" cat q " -Method DELETE -Headers $headers -UseBasicParsing | Out-Null`n"
        ps .= "    Add-Content -Path " q logPath q " -Value " q "OK: " cat q "`n"
        ps .= "} catch {`n"
        ps .= "    Add-Content -Path " q logPath q " -Value (" q "ERR: " cat " " q " + " . '$_.Exception.Message)' . "`n"
        ps .= "}`n"
    }
    ; denylist（個別ドメイン）解除も追加
    for domain in nextdnsBlockList {
        ps .= "try {`n"
        ps .= "    Invoke-WebRequest -Uri " q "https://api.nextdns.io/profiles/" nextdnsProfile "/denylist/" domain q " -Method DELETE -Headers $headers -UseBasicParsing | Out-Null`n"
        ps .= "    Add-Content -Path " q logPath q " -Value " q "OK(deny): " domain q "`n"
        ps .= "} catch {`n"
        ps .= "    Add-Content -Path " q logPath q " -Value (" q "ERR(deny): " domain " " q " + " . '$_.Exception.Message)' . "`n"
        ps .= "}`n"
    }
    ; サービス個別ブロックも解除
    for svc in nextdnsServices {
        ps .= "try {`n"
        ps .= "    Invoke-WebRequest -Uri " q "https://api.nextdns.io/profiles/" nextdnsProfile "/parentalcontrol/services/" svc q " -Method DELETE -Headers $headers -UseBasicParsing | Out-Null`n"
        ps .= "    Add-Content -Path " q logPath q " -Value " q "OK(svc): " svc q "`n"
        ps .= "} catch {`n"
        ps .= "    Add-Content -Path " q logPath q " -Value (" q "ERR(svc): " svc " " q " + " . '$_.Exception.Message)' . "`n"
        ps .= "}`n"
    }
    FileAppend(ps, psPath, "UTF-8-RAW")
    Run('powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File "' psPath '"',, 'Hide')
    TrayTip("📶 スマホブロック解除", "NextDNS のブロックを解除しました", "Mute")
}

; ================================================================
; ★ ブロック対象リスト
;
;    【追加方法】
;    コメントアウトされた行をコピーして行頭の ; を外し、
;    name と key を書き換えてください。
;    key: ウィンドウのタイトルバーに含まれる文字列（部分一致）
; ================================================================
siteList := [
    {name: "X (Twitter)",  key: "Twitter"},
    {name: "YouTube",      key: "YouTube"},
    {name: "Niconico",     key: "niconico"},
    {name: "Instagram",    key: "Instagram"},
    {name: "Facebook",     key: "Facebook"},
    {name: "Slay the Spire",     key: "Slay"},
    ; ↓ ここにブロック対象を追加（; を外して編集）
    {name: "Steam",        key: "Steam"},
    ; {name: "Discord",      key: "Discord"},
    ; {name: "Amazon Music", key: "Amazon Music"},
]

lockTimeList := [
    {label: "15 min",  seconds: 900},
    {label: "20 min",  seconds: 1200},
    {label: "25 min",  seconds: 1500},
    {label: "30 min",  seconds: 1800},
    {label: "45 min",  seconds: 2700},
    {label: "1 hour",  seconds: 3600}
]

breakTimeList := [
    {label: "3 min",   seconds: 180},
    {label: "5 min",   seconds: 300},
    {label: "10 min",  seconds: 600},
    {label: "15 min",  seconds: 900}
]

setCountList := [
    {label: "1 sets",  count: 1},
    {label: "2 sets",  count: 2},
    {label: "3 sets",  count: 3},
    {label: "4 sets",  count: 4},
    {label: "5 sets",  count: 5},
    {label: "6 sets",  count: 6}
]

; ================================================================
; ★ 自動起動時のデフォルト設定
;    秒数で指定します（例: 1800 = 30分 / 3600 = 1時間）
; ================================================================
autoLockSecs  := 1500
autoBreakSecs := 300
autoTotalSets := 3

; ================================================================
; ★ クロッキーモードの設定
;    /croquis 引数で起動したときのロック時間（秒）
;    launcher.ahk 側の croquisLockSecs と合わせてください
; ================================================================
croquisLockSecs    := 1500   ; 25分
croquisShotDir     := A_ScriptDir "\croquis_shots"   ; キャプチャ保存先
croquisCaptureWait := 180    ; タイマー終了からスクショ撮影までの猶予（秒）
croquisBreakSecs   := 600    ; クロッキー後の休憩時間（秒）

; ================================================================
; ★ 右脳ドローイング（テスト実行専用・変更不要）
;
;    60秒×多数セットで、モデル画像をクリップボード貼り付けではなく
;    常時最前面の「参照ウィンドウ」に自動表示する特殊モード。
;    croquisModeParams（launcher.ahk側）には登録しておらず、通常の
;    croquisMode設定やランダム選択からは絶対に到達しない。
;    トレイメニューの「🧪 右脳ドローイング（テスト）」からのみ起動できる。
;
;    fastCroquisCaptureEvery
;      → 何セットごとに撮影（croquisCaptureWait秒の待機）を挟むか
;
;    fastCroquisFolder
;      → モデル画像フォルダ（croquis_models_2 を流用。モード2/4と共有）
;
;    croquisUsedFastLog
;      → このモード専用の使用済みリスト（croquis_used.txtとは別ファイル。
;        一周するまで被りなし→一周でリセット。テスト実行時はここへの
;        書き込みをスキップするので、テストで画像を消費しない）
;
;    fastCroquisRefX/Y/W/H
;      → 参照ウィンドウの初期位置・サイズ（起動のたびにドラッグ・リサイズで
;        調整した最終的な位置・サイズが fastCroquisRefGeometryPath に自動保存され、
;        次回起動時はそちらが優先される。ここの値は保存ファイルが無い＝
;        初回起動時のみに使われる初期値）
;
;    fastCroquisRefGeometryPath
;      → 参照ウィンドウの位置・サイズを記憶するファイル（自動管理・変更不要）
;
;    fastCroquisStopFlagPath
;      → launcher.ahk側のトレイメニュー「🧪 テストモードを終了」から
;        手動停止する際に使うシグナルファイル（変更不要）
; ================================================================
fastCroquisCaptureEvery := 5
fastCroquisFolder       := A_ScriptDir "\croquis_models_2"
croquisUsedFastLog      := A_ScriptDir "\croquis_used_fast.txt"       ; モード6（テスト実行）専用・書き込みなし
croquisUsedPracticeLog  := A_ScriptDir "\croquis_used_practice.txt"   ; モード8（本番の軽量練習モード）専用
fastCroquisRefX := 100
fastCroquisRefY := 100
fastCroquisRefW := 400
fastCroquisRefH := 400
fastCroquisRefGeometryPath := A_ScriptDir "\fast_croquis_ref_geometry.txt"
fastCroquisStopFlagPath := A_ScriptDir "\fast_croquis_stop.txt"
; 参照ウィンドウの表示に使うHTMLファイル（内部でimg要素をJSで拡縮・切替する。
; 詳細はWriteFastCroquisHtml参照）
fastCroquisHtmlPath := A_ScriptDir "\fast_croquis_ref.html"

; 参照ウィンドウの状態を保持するグローバル変数。
; オート実行の早い段階（起動モード分岐で RunFastCroquis() が呼ばれるより前）で
; 初期化しておく必要がある（AHKはオート実行部分を上から順に実行するため、
; 分岐処理より後ろで初期化すると「値が代入されていない」エラーになる）。
global fastRefGui := ""
global fastRefCurrentImage := ""
global fastCroquisLastError := ""
; 表示エンジン本体（ActiveXコントロールとそのCOMオブジェクト）。
; 【設計変更の経緯】当初はAHK標準のPicture/Staticコントロールで直接
; 画像を縮小表示していたが、以下の問題を次々に踏んだ：
;   ・GuiControlに.Destroy()メソッドが存在しない
;   ・DllCall(DestroyWindow)で破棄しても内部の名前登録は解除されず、
;     同名で再Addすると"A control with this name already exists."
;   ・.Value での画像差し替えは、Add()時のような正しい再スケーリングを
;     してくれず、一部が拡大されたように表示される
; これらはWindows標準のSTATIC/Pictureコントロール特有の制約であり、
; 自前で拡大縮小のジオメトリ計算をし続ける限り再発しかねない。
; そこで、ブラウザエンジン（Shell.Explorer ActiveX、Windows標準搭載で
; 追加インストール不要）を埋め込み、画像の拡大縮小・中央寄せは全て
; CSS/JS側（fast_croquis_ref.html）に任せる方式に変更した。
; AHK側はimg要素のsrcをJS経由で書き換えるだけでよく、ウィンドウの
; リサイズもActiveXコントロール自体をMoveするだけで、内部のJS側
; window.onresizeが自動的に再フィットしてくれる。
global fastRefWBCtrl := ""   ; ActiveXのGuiControlオブジェクト
global fastRefWB     := ""  ; WebBrowserのCOMオブジェクト（.Value）
fastCroquisErrorLogPath := A_ScriptDir "\fast_croquis_error.log"

; ================================================================
; ★ 中休みモードの設定
;
;    全セット完了後に入る「中休みモード」の設定です。
;    この時間内に「作業完了」ボタンを押さなければ、セットが追加されます。
;
;    intermissionMinutes
;      → 中休みモードの時間（分）
;    intermissionAddSets
;      → 時間切れ時に追加するセット数
; ================================================================
intermissionMinutes := 15
intermissionAddSets := 2

; ================================================================
; ★ 食事休憩の時間設定
; ================================================================
mealPauseStartH := 19
mealPauseStartM := 0
mealPauseEndH   := 20
mealPauseEndM   := 30

; ================================================================
; ★ 運動ボタンの設定
; ================================================================
exerciseUnlockKey     := "Steam"
exerciseUnlockMinutes := 60
exerciseLogPath       := A_ScriptDir "\exercise_log.txt"

; ================================================================
; ★ 昼休みボタンの設定
;
;    lunchBreakMinutes
;      → 昼休みとして一時停止する時間（分）。
;        この間タイマーとサボり検知が停止します。
;        1日1回のみ使用可能です。
; ================================================================
lunchBreakMinutes := 50
lunchLogPath      := A_ScriptDir "\lunch_log.txt"

; ================================================================
; ★ NextDNS 設定
;    ロック中にスマホのSNS等をDNSレベルでブロックします。
;
;    nextdnsApiKey
;      → my.nextdns.io/account で取得したAPIキーを貼ってください。
;    nextdnsProfile
;      → 管理画面URLの英数字のプロファイルIDです。
;        例: https://my.nextdns.io/ab12cd/setup → "ab12cd"
;    nextdnsEnabled
;      → false にすると無効化します。
;    nextdnsBlockList
;      → ブロックするドメインのリスト（サブドメインも自動対象）
; ================================================================
nextdnsApiKey   := "10fe27590862f3c7d0e62ca47fe93ec40bbd0b78"
nextdnsProfile  := "5f2c95"
nextdnsEnabled  := true

; ================================================================
; ★ NextDNS ブロックカテゴリ
;
;    ロック中にNextDNSのペアレンタルコントロール機能でブロックする
;    カテゴリのリストです。休憩中は自動で解除されます。
;
;    利用可能なカテゴリID:
;      social-networks  … X・Instagram・Facebook・TikTok等
;      video-streaming  … YouTube・Netflix・Twitch・ニコニコ等
;      gaming           … Steam・その他ゲームサービス
;      dating           … マッチングアプリ等
;      gambling         … ギャンブル系サイト
;
;    ※ ブロックしたいカテゴリの行頭の ; を外してください。
; ================================================================
nextdnsCategories := [
    ; "social-networks",
    "video-streaming",
    "gaming",
    ; "dating",
    ; "gambling",
]

; ================================================================
; ★ NextDNS 個別サービスブロック
;
;    カテゴリブロックから漏れるアプリを個別に指定します。
;    カテゴリとサービスの両方が有効になります。
;
;    利用可能なサービスID（主なもの）:
;      youtube, twitter, instagram, tiktok, facebook
;      snapchat, discord, reddit, twitch, steam
;      netflix, hulu, primevideo, spotify, amazon
;      minecraft, roblox, fortnite, blizzard
;      whatsapp, telegram, line, pinterest, tumblr
;      zoom, skype, vimeo, dailymotion, imgur
;
;    ※ ブロックしたいサービスの行頭の ; を外してください。
; ================================================================
nextdnsServices := [
    "youtube",
    "twitter",
    "instagram",
    "tiktok",
    "facebook",
    "snapchat",
    "reddit",
    "twitch",
    "steam",
    ; ↓ 必要に応じて追加
    ; "netflix",
    ; "primevideo",
    ; "spotify",
    ; "minecraft",
]

; ================================================================
; ★ NextDNS 個別ドメインブロック（denylist）
;
;    サービスIDにない・カテゴリに含まれないアプリを
;    ドメイン単位で直接指定してブロックします。
;
;    【ドメインの調べ方】
;    NextDNS管理画面の「ログ」タブを開き、
;    スマホでブロックしたいアプリを操作すると
;    そのアプリが通信しているドメインが一覧で表示されます。
;    そのドメインを下のリストに追加してください。
;    サブドメインは自動的にブロックされます。
;
;    例: "nicovideo.jp"  → ニコニコ動画
;        "line.me"       → LINE
; ================================================================
nextdnsBlockList := [
    ; ↓ ここにドメインを追加（; を外して編集）
    ; "nicovideo.jp",
    ; "line.me",
    ; "abema.tv",
]

; ================================================================
; ★ ゲームプレイ時間制限の設定
;
;    gameLimitMinutes
;      → 1日のゲームプレイ制限時間（分）。0にすると無効。
;
;    gameLimitExtendSets
;      → 制限到達後、このセット数の作業を完了すると制限を1回延長できます。
;        延長は1日1回のみ。
;
;    gameLimitTargets
;      → 制限対象のゲームプロセス名またはウィンドウタイトルキーワード。
;        プロセス名（.exe）または タイトルキーワードで指定します。
;        プロセス名は完全一致、タイトルは部分一致で判定します。
;
;    gameLimitLogPath
;      → 本日のゲームプレイ時間を保存するファイル（変更不要）
; ================================================================
gameLimitMinutes    := 120   ; 1日2時間
gameLimitExtendSets := 1     ; 1セット完了で1回延長
gameLimitTargets    := [
    {type: "process", key: "steam.exe"},
    ; ↓ 追加例（; を外して編集）
    ; {type: "process", key: "EpicGamesLauncher.exe"},
    ; {type: "title",   key: "Minecraft"},
]
gameLimitLogPath    := A_ScriptDir "\game_limit.txt"

; ================================================================
; ★ 集中モードの許可リスト
;
;    集中モード中でも最小化しないアプリを指定します。
;    ウィンドウのタイトルバーに含まれる文字列（部分一致）で指定します。
;
;    【確認方法】
;    許可したいアプリを開いた状態でタスクバーのアイコンに
;    カーソルを当てると表示されるタイトルの一部を使ってください。
;
;    【注意】
;    ・タイマーGUI自体は自動的に除外されます（設定不要）
;    ・BGMウィンドウ登録ボタンで登録したウィンドウも自動的に除外されます
;    ・デスクトップ・タスクバー等のシステムウィンドウも自動的に除外されます
;
;    例: "Spotify" → Spotifyは最小化しない
;        "Visual Studio Code" → VSCodeは最小化しない
; ================================================================
focusModeAllowList := [
    "Spotify",
    ; ↓ ここに許可するアプリを追加（; を外して編集）
    "CLIP",
    "sakura",
    "さとりすと",
    "エクスプローラー",
    "カラーヒストリー",
    "情報",
    "ナビゲーター",
    "ホウ酸's",
    "kindle"   ; Chromeのウィンドウ名機能で「kindle」と名付けたウィンドウを除外
]

; ================================================================
; ★ 集中モードの許可プロセスリスト
;
;    タイトル文字列ではなく「プロセス名（.exeファイル名）」で指定します。
;    同じソフトが出すウィンドウはすべて同じプロセス名を持つため、
;    サブウィンドウが多いアプリはこちらに登録するのが便利です。
;
;    【プロセス名の調べ方】
;    タスクマネージャーを開き（Ctrl+Shift+Esc）、
;    「詳細」タブで対象アプリを探すと「名前」列に .exe 名が表示されます。
;    例: CLIP Studio Paint → "CLIPStudioPaint.exe"
;        Photoshop         → "Photoshop.exe"
;
;    大文字小文字は区別しません。
; ================================================================
focusModeAllowProcesses := [
    "CLIPStudioPaint.exe",
    ; ↓ ここに許可するプロセスを追加（; を外して編集）
    ; "Photoshop.exe",
    ; "sai2.exe",
    "Satolist2.exe",
    "Spotify.exe",
    "ssp.exe",
    "Microsoft.Photos.exe",
    "photos.exe"
]

; ================================================================
; ★ 集中モード自動発動の設定
;
;    focusModeAutoFromSet
;      → この番号以降のセットで、ランダムに集中モードが自動発動します。
;        例: 3 なら3セット目以降が対象（1・2セット目は必ず通常モード）
;
;    focusModeAutoChance
;      → 自動発動の確率（%）。
;        例: 50 なら50%の確率で集中モードになる
;            100 なら必ず集中モードになる
;            0 なら自動発動しない（手動のみ）
; ================================================================
focusModeAutoFromSet := 3
focusModeAutoChance  := 30

; ================================================================
; ★ 作業達成時間の設定
;
;    totalWorkGoalMinutes
;      → この時間（分）だけ作業ウィンドウがアクティブになると
;        「作業達成」とみなし、スクリプト停止が許可されます。
;        0 にすると機能を無効化します。
;
;    作業ウィンドウの指定は workWindowTitles / workWindowProcesses を使います。
;    ロック中・中休み中のみ計測します（休憩・食事中は計測しません）。
;    クロッキー（別プロセスとして起動）とまたがっても計測が引き継がれるよう、
;    work_goal.txt に随時保存し、起動のたびに本日分を読み込みます。
;
;    ノルマ達成後にさらに作業した場合、その超過分は翌日1日だけノルマから
;    差し引かれます（例: 前日30分超過なら、翌日のノルマは150分→120分）。
;    ただし workGoalMinMinutes を下回ることはありません。超過分が
;    差し引ける範囲を超えても、翌々日以降には持ち越しません。
;
;    workGoalMinMinutes
;      → 超過分を差し引いても、これより短くはならない下限（分）
;
;    workIdleToleranceSecs
;      → 作業ウィンドウがアクティブなままでも、この秒数以上マウス・キーボードの
;        操作が無ければ、その間は作業時間として計上しません
;        （ウィンドウを開いたままスマホを触っている時間などを除外するため）
;
;    ★残業時間について
;    ノルマ達成後、休憩中にこのスクリプトを終了して1日を終える運用のため、
;    終了後にロック外で行った作業は本来ここでは計測できません。
;    そのぶんは launcher.ahk 側が常駐監視で独自に計測し、
;    overtime_work.txt に保存します。このファイルは翌日の繰り越し計算
;    （下の起動時ブロック）で読み込むだけで、lock_window.ahk 側からは
;    書き込みません（launcher.ahk が起動中に同じファイルへ書き込むと
;    競合するため、書き込み元を1つに限定しています）。
; ================================================================
totalWorkGoalMinutes  := 150   ; 2時間半
workGoalMinMinutes    := 90    ; 1時間30分（超過繰り越しによる下限）
workIdleToleranceSecs := 60    ; 1分
workGoalLogPath       := A_ScriptDir "\work_goal.txt"
overtimeLogPath       := A_ScriptDir "\overtime_work.txt"   ; launcher.ahk が書き込む残業ログ（読み取り専用で参照）

; 「1日の区切り」は launcher.ahk が睡眠復帰のたびに進める dayId を基準にする
; （カレンダー日付の0時ではない。詳細は launcher.ahk 側の day_state.txt の説明を参照）。
; このファイルは launcher.ahk のみが書き込み、lock_window.ahk 側は起動時に読み取るだけ。
dayStatePath := A_ScriptDir "\day_state.txt"
currentDayId := 1
try currentDayId := Integer(Trim(SafeReadFile(dayStatePath)))

; ================================================================
; ★ 休憩延期の設定
;
;    ロック時間終了時に、以下のリストに含まれるウィンドウが
;    アクティブであった場合、休憩への移行を延期します。
;    別のウィンドウに切り替わった瞬間に休憩が開始されます。
;
;    workWindowTitles
;      → タイトルバーに含まれる文字列で判定（部分一致）
;
;    workWindowProcesses
;      → プロセス名（.exe）で判定
;        タイトルが変わるアプリはこちらが確実です。
;
;    breakDeferGraceSecs
;      → 作業ウィンドウ以外がアクティブになってから何秒継続したら
;        休憩開始とみなすか。IME・通知など一時的なフォーカス奪取を
;        無視するための猶予です。
;        例: 5 なら5秒間ずっと作業外が続いたら休憩開始
; ================================================================
workWindowTitles := [
    ; ↓ ここに作業用ウィンドウのタイトルキーワードを追加（; を外して編集）
    ; "Visual Studio Code",
    ; "sakura",
]
workWindowProcesses := [
    "CLIPStudioPaint.exe",
    ; ↓ ここに作業用アプリのプロセス名を追加（; を外して編集）
    ; "sai2.exe",
    ; "Photoshop.exe",
]
breakDeferGraceSecs := 5

; 本日の作業ノルマ進捗を読み込む（dayIdが変わっていたら前日の超過分を反映）
; クロッキー用プロセスと通常作業用プロセスは別々に起動されるため、
; メモリ上の値だけでは引き継がれない。ファイル経由で引き継ぐ。
_workActiveMs     := 0
_workGoalReached  := false
_effectiveGoalMin := totalWorkGoalMinutes
if (totalWorkGoalMinutes != 0) {
    try {
        _workGoalData := StrSplit(SafeReadFile(workGoalLogPath), "|")
        _storedDayId  := Integer(_workGoalData[1])

        if (_storedDayId = currentDayId) {
            ; 同じ日（同じ睡眠区間）の続き（クロッキー→通常作業など）：そのまま引き継ぐ
            _workActiveMs     := Integer(_workGoalData[2])
            _workGoalReached  := (_workGoalData[3] = "1")
            _effectiveGoalMin := (_workGoalData.Length >= 4) ? Integer(_workGoalData[4]) : totalWorkGoalMinutes
        } else if (_storedDayId = currentDayId - 1) {
            ; 前日（1つ前の睡眠区間）から日が変わった：前日の超過分を計算し、本日の実効ノルマに反映する
            ; （前日の記録が無い・2日以上前の場合は繰り越しなし＝通常のノルマのまま）
            _prevActiveMin := Round(Integer(_workGoalData[2]) / 60000)
            _prevGoalMin   := (_workGoalData.Length >= 4) ? Integer(_workGoalData[4]) : totalWorkGoalMinutes
            _overMin       := Max(0, _prevActiveMin - _prevGoalMin)

            ; launcher.ahk が計測した「前日・ロック外での残業時間」も繰り越しに加算する
            ; （ノルマ達成後にこのスクリプトを終了して、ロック外で追加作業した分）
            _prevOvertimeMin := 0
            try {
                _otData := StrSplit(SafeReadFile(overtimeLogPath), "|")
                if (Integer(_otData[1]) = currentDayId - 1)
                    _prevOvertimeMin := Round(Integer(_otData[2]) / 60000)
            }
            _overMin += _prevOvertimeMin

            _effectiveGoalMin := Max(workGoalMinMinutes, totalWorkGoalMinutes - _overMin)
        }
        ; それ以外（2日以上前 or 記録なし）は繰り越しなし＝通常のノルマのまま
    }

    ; 本日分（実効ノルマ含む）を即座に保存しておく。
    ; クロッキー→通常作業など、本日中に複数プロセスが立ち上がっても
    ; 同じ実効ノルマを使い続けられるようにするため。
    SafeWriteFile(workGoalLogPath, currentDayId "|" _workActiveMs "|" (_workGoalReached ? "1" : "0") "|" _effectiveGoalMin)
}

global effectiveWorkGoalMinutes := _effectiveGoalMin

global g := {
    phase:             "",
    endTick:           0,
    isPaused:          false,
    pausedRemainingMs: 0,
    inMealPause:       false,
    isExercise:        false,
    exerciseEndTick:   0,
    currentSet:        0,
    totalSets:         0,
    lockSecs:          0,
    breakSecs:         0,
    targetTitles:      [],
    generation:           0,      ; RunPomodoro の呼び出し世代（タイマー競合防止）
    breakPending:         false,  ; 休憩延期中かどうか
    breakDeferSince:      0,      ; 作業外ウィンドウになった最初の TickCount
    fakeEndTick:          0,      ; 偽装カウントダウンの終了 TickCount
    hadIntermission:      false,  ; 一度でも中休みを経験したか
    activeWorkMs:         _workActiveMs,      ; 作業ウィンドウがアクティブだった累計時間（ms）
    workGoalReached:      _workGoalReached,   ; 作業達成フラグ
    lastActiveCheck:      0,      ; 前回の作業時間チェックのTickCount
    focusMode:            false,  ; 集中モード中かどうか
    focusModeIsAuto:      false,  ; true=自動発動 / false=手動発動
    lastSetHadFocusMode:  false,  ; 直前に完了したセットが集中モードだったか（自動抽選の連続発動防止用）
    intermissionEnd:      0,      ; 中休みモード終了のTickCount
    focusCountdownEnd:    0,      ; 集中モード猶予カウントダウン用
    focusCountingDown:    false,  ; カウントダウン中はブロックを一時停止
    focusMinimizedHwnds:  [],     ; 集中モードで最小化したウィンドウのHWND一覧（復元用）
    gameLimitReached:     false,  ; ゲーム制限に達したか
    gameExtendSetsLeft:   0,      ; 延長に必要な残りセット数
    gameExtendUsed:       false,  ; 本日の延長を使用済みか
    croquisSet:           1,      ; クロッキー現在セット番号
    croquisTotal:         1,      ; クロッキー総セット数
    croquisInter:         0,      ; クロッキーセット間休憩（秒）
    idlePaused:           false,  ; 無操作による自動一時停止中かどうか（他の一時停止と区別するため）
    idleSavedTitle:       "",     ; 一時停止前のタイトル（復元用）
    idleSavedSub:         "",     ; 一時停止前のサブテキスト（復元用）
    inCaptureWait:        false,  ; クロッキー撮影待機中かどうか（無操作検知の一時停止から除外するため）
    mealSavedTitle:       "",     ; 食事休憩前のタイトル（復元用）
    mealSavedSub:         "",     ; 食事休憩前のサブテキスト（復元用）
    mealSavedColor:       "",     ; 食事休憩前の背景色（復元用）
    goingOut:             false,  ; 外出モード（無期限の手動一時停止）中かどうか
    goOutSavedTitle:      "",     ; 外出モード開始前のタイトル（復元用）
    goOutSavedSub:        "",     ; 外出モード開始前のサブテキスト（復元用）
    goOutSavedColor:      ""      ; 外出モード開始前の背景色（復元用）
}

; ===== 運動ボタン：本日使用済みか確認（変更不要）=====
exerciseUsedToday := false
try {
    lastUsed := Trim(FileRead(exerciseLogPath))
    if (lastUsed = FormatTime(, "yyyyMMdd"))
        exerciseUsedToday := true
}

; ===== 昼休みボタン：本日使用済みか確認（変更不要）=====
lunchUsedToday := false
try {
    lastLunch := Trim(FileRead(lunchLogPath))
    if (lastLunch = FormatTime(, "yyyyMMdd"))
        lunchUsedToday := true
}

; ===== カウントダウンGUI（変更不要）=====
global timerGui := Gui("+AlwaysOnTop +ToolWindow", "Timer")
timerGui.SetFont("s13 bold", "Segoe UI")
timerGui.BackColor := "CC3333"

global timerTitle := timerGui.Add("Text", "w295 Center cWhite",     "")
timerGui.SetFont("s28 bold", "Segoe UI")
global timerCount := timerGui.Add("Text", "w295 Center cWhite y+5", "00:00")
timerGui.SetFont("s10", "Segoe UI")
global timerSub   := timerGui.Add("Text", "w295 Center cWhite y+5", "")

; ================================================================
; ★ コンパクトボタン行（変更不要）
;    各ボタンにマウスを乗せると操作の説明がツールチップで表示されます。
;
;    ボタン一覧:
;    🚴 … 運動モード（Steam を一定時間解除・1日1回）
;    ➕ … セットを1つ追加
;    🥗 … 昼休み（タイマー＆サボり検知を一時停止・1日1回）
;    🎯 … 集中モード（許可リスト以外のウィンドウをすべて最小化）
;    🚪 … 外出モード（数時間単位の外出用に、タイマーを無期限に一時停止）
; ================================================================
timerGui.SetFont("s11", "Segoe UI")
global exerciseBtn := timerGui.Add("Button", "x5 w56 y+10", "🚴")
exerciseBtn.OnEvent("Click", OnExerciseStart)
if (exerciseUsedToday)
    exerciseBtn.Enabled := false

global addSetBtn := timerGui.Add("Button", "x+3 w56 yp", "➕")
addSetBtn.OnEvent("Click", OnAddSet)

global lunchBtn := timerGui.Add("Button", "x+3 w56 yp", "🥗")
lunchBtn.OnEvent("Click", OnLunchBreak)
if (lunchUsedToday)
    lunchBtn.Enabled := false

global focusBtn := timerGui.Add("Button", "x+3 w56 yp", "🎯")
focusBtn.OnEvent("Click", OnFocusMode)
focusBtn.Enabled := false   ; タイマー未起動中は無効

global goOutBtn := timerGui.Add("Button", "x+3 w56 yp", "🚪")
goOutBtn.OnEvent("Click", OnGoOut)

; 作業完了ボタン（中休みモード中のみ表示・変更不要）
; タイトル行の右横に配置し、中休み中のみ出現します
global workDoneBtn := timerGui.Add("Button", "x205 y8 w90 h24", "✅ 完了")
workDoneBtn.OnEvent("Click", OnWorkDone)
workDoneBtn.Visible := false

; 食事休憩の手動終了ボタン（食事休憩中のみ表示・変更不要）
; 数字表示（timerCount）と同じ位置に重ねて表示し、休憩中だけ切り替えます
global mealEndBtn := timerGui.Add("Button", "x73 y38 w160 h36", "⏭ 食事休憩を終了")
mealEndBtn.OnEvent("Click", OnMealEnd)
mealEndBtn.Visible := false

timerGui.Show("Center w305 h158 NoActivate Hide")

; トレイアイコンのダブルクリックでタイマーGUIを最前面に戻す
OnMessage(0x404, OnTrayDblClick)
OnTrayDblClick(wParam, lParam, msg, hwnd) {
    if (lParam = 0x202)   ; WM_LBUTTONUP（シングルクリック）→ 握りつぶす
        return 0
    if (lParam = 0x203) { ; WM_LBUTTONDBLCLK（ダブルクリック）→ GUI最前面
        try {
            timerGui.Opt("+AlwaysOnTop")
            timerGui.Show("NoActivate")
        }
    }
}

; ===== ツールチップ（マウスオーバー時に表示）（変更不要）=====
SetTimer(UpdateTooltip, 150)

UpdateTooltip() {
    global g, exerciseUsedToday, exerciseUnlockKey, exerciseUnlockMinutes
    MouseGetPos(,, , &mCtrl, 2)
    ctrlHwnd := IsInteger(mCtrl) ? mCtrl : 0
    if (ctrlHwnd = exerciseBtn.Hwnd) {
        if exerciseUsedToday
            ToolTip("🚴 運動モード（本日使用済み）")
        else
            ToolTip("🚴 運動モード`n" exerciseUnlockKey " を " exerciseUnlockMinutes " 分間解除します`n（1日1回のみ使用可能）")
    } else if (ctrlHwnd = addSetBtn.Hwnd) {
        ToolTip("➕ セットを1つ追加`n現在の合計: " g.totalSets " セット`nAll done 後に押すと作業を再開します")
    } else if (ctrlHwnd = lunchBtn.Hwnd) {
        if lunchUsedToday
            ToolTip("🥗 昼休み（本日使用済み）")
        else
            ToolTip("🥗 昼休み`nタイマーとサボり検知を " lunchBreakMinutes " 分間停止します`n（1日1回のみ使用可能）")
    } else if (ctrlHwnd = focusBtn.Hwnd) {
        if (g.phase = "lock" && g.focusMode)
            ToolTip("🎯 集中モード ON（解除は休憩中のみ）`n許可リスト以外のウィンドウを最小化しています")
        else if (g.focusMode)
            ToolTip("🎯 集中モード ON`nクリックで解除できます")
        else
            ToolTip("🎯 集中モードを開始`n許可リスト以外のウィンドウをすべて最小化します`n解除は休憩中のみ可能です")
    } else if (ctrlHwnd = workDoneBtn.Hwnd) {
        ToolTip("✅ 今日の作業完了を宣言`nサボり監視を停止し、待機モードに移行します`n押さない場合は " intermissionMinutes " 分後にセットが追加されます")
    } else if (ctrlHwnd = mealEndBtn.Hwnd) {
        ToolTip("⏭ 食事休憩を今すぐ終了して`nタイマーを再開します")
    } else if (ctrlHwnd = goOutBtn.Hwnd) {
        if (g.goingOut)
            ToolTip("▶ 外出モードを終了して`nタイマーを再開します")
        else
            ToolTip("🚪 外出モード`n数時間の外出などのために、現在の状態のまま`nタイマーを無期限に一時停止します")
    } else {
        ToolTip()
    }
}

; ===== セット追加ボタン処理（変更不要）=====
OnAddSet(btn, *) {
    global g, timerTitle

    if (g.phase = "" && g.currentSet = 0)
        return

    g.totalSets += 1

    if (g.phase = "intermission" || g.phase = "done") {
        SetTimer(IntermissionTick, 0)   ; 中休みタイマーを止める
        workDoneBtn.Visible := false
        g.focusMode := false
        ; 中休み中の手動追加もセットカウントを引き継ぐ
        nextSet := (g.phase = "intermission") ? g.currentSet + 1 : 1
        RunPomodoro(g.targetTitles, g.lockSecs, g.breakSecs, g.totalSets, nextSet)
        return
    }

    if (!g.inMealPause && !g.isExercise) {
        if (g.phase = "lock")
            timerTitle.Value := "🔒 Lock  -  Set " g.currentSet "/" g.totalSets
        else if (g.phase = "break")
            timerTitle.Value := "☕ Break  -  Set " g.currentSet "/" g.totalSets
    }
}



; ===== 作業中ウィンドウ判定（変更不要）=====
IsWorkWindow() {
    global workWindowTitles, workWindowProcesses
    try {
        activeHwnd := WinGetID("A")
        if (!activeHwnd)
            return false
        title   := WinGetTitle("ahk_id " activeHwnd)
        proc    := WinGetProcessName("ahk_id " activeHwnd)
        for kw in workWindowTitles {
            if InStr(title, kw)
                return true
        }
        for p in workWindowProcesses {
            if (StrLower(proc) = StrLower(p))
                return true
        }
    }
    return false
}

; ===== 中休みモード（変更不要）=====
EnterIntermission() {
    global g, timerGui, timerTitle, timerCount, timerSub
    global workDoneBtn, intermissionMinutes, intermissionAddSets
    g.hadIntermission := true   ; 中休みを経験したことを記録

    g.phase             := "intermission"
    g.intermissionEnd   := A_TickCount + (intermissionMinutes * 60 * 1000)
    WritePhase("intermission")   ; サボり監視を継続

    SoundPlay("*48")
    TrayTip("中休み", intermissionMinutes " 分以内に「作業完了」を押さないとセットが追加されます", "Mute")

    timerGui.BackColor := "37474F"   ; スレートグレー
    timerTitle.SetFont("cWhite")
    timerCount.SetFont("cWhite")
    timerSub.SetFont("cWhite")
    timerTitle.Value := "🛋️ 中休み"
    timerSub.Value   := "作業完了 or " intermissionMinutes "分後に再開"
    workDoneBtn.Visible := g.workGoalReached   ; 作業達成済みのときのみ表示

    FocusModeRestore()
    UpdateFocusBtnState()
    SetTimer(IntermissionTick, 300)
}

IntermissionTick() {
    global g, timerCount, workDoneBtn, intermissionAddSets

    remaining := g.intermissionEnd - A_TickCount
    if (remaining <= 0) {
        SetTimer(IntermissionTick, 0)
        workDoneBtn.Visible := false
        ; 時間切れ → セットを追加して、続きのセットから再開
        g.totalSets += intermissionAddSets
        nextSet := g.currentSet + 1
        TrayTip("中休み終了", intermissionAddSets " セット追加して Set " nextSet " から再開します", "Mute")
        RunPomodoro(g.targetTitles, g.lockSecs, g.breakSecs, g.totalSets, nextSet)
        return
    }

    secs := Ceil(remaining / 1000)
    mins := secs // 60
    secs := Mod(secs, 60)
    timerCount.Value := Format("{:02d}:{:02d}", mins, secs)
}

; ===== 作業完了ボタン処理（変更不要）=====
OnWorkDone(btn, *) {
    global g, workDoneBtn

    SetTimer(IntermissionTick, 0)
    workDoneBtn.Visible := false

    g.phase := "done"
    WritePhase("done")   ; サボり監視を停止
    NextDnsUnblock()     ; 作業完了時にブロックを解除

    timerGui.BackColor := "1A1A2E"
    timerTitle.Value := "✅ All done!"
    timerCount.Value := "--:--"
    timerSub.Value   := "➕ ボタンで追加セットを開始"
    UpdateFocusBtnState()

    SoundPlay("*48")
    TrayTip("作業完了", "お疲れ様でした！", "Mute")
}

; ===== 昼休みボタン処理（変更不要）=====
OnLunchBreak(btn, *) {
    global g, lunchBtn, lunchLogPath, lunchBreakMinutes
    global timerGui, timerTitle, timerCount, timerSub

    try FileDelete(lunchLogPath)
    FileAppend(FormatTime(, "yyyyMMdd"), lunchLogPath)
    lunchBtn.Enabled := false

    ; タイマーを一時停止して残り時間を保存
    g.isPaused          := true
    g.idlePaused        := false   ; 無操作検知による一時停止ではないことを明示
    g.pausedRemainingMs := Max(0, g.endTick - A_TickCount)
    g.isExercise        := true   ; 復帰処理を運動モードと共用するため流用
    g.exerciseEndTick   := A_TickCount + (lunchBreakMinutes * 60 * 1000)

    WritePhase("lunch")   ; サボり検知を無効化
    NextDnsUnblock()

    timerGui.BackColor := "4A7C4E"
    timerTitle.Value   := "🥗 昼休み中"
    timerCount.Value   := Format("{:02d}:00", lunchBreakMinutes)
    timerSub.Value     := "タイマー・サボり検知を停止中"

    SoundPlay("*48")
    TrayTip("昼休み開始", lunchBreakMinutes " 分後にタイマーを再開します", "Mute")

    SetTimer(LunchBreakTimer, 300)
}

LunchBreakTimer() {
    global g, timerCount

    remaining := g.exerciseEndTick - A_TickCount
    if (remaining <= 0) {
        SetTimer(LunchBreakTimer, 0)
        ResumeAfterExercise()   ; 運動モードと同じ復帰処理を再利用
        return
    }

    secs := Ceil(remaining / 1000)
    mins := secs // 60
    secs := Mod(secs, 60)
    timerCount.Value := Format("{:02d}:{:02d}", mins, secs)
}

; ===== 集中モードボタン処理（変更不要）=====
OnFocusMode(btn, *) {
    global g

    if (g.phase = "lock") {
        ; ロック中は有効化のみ（解除不可）
        if (!g.focusMode) {
            g.focusMode       := true
            g.focusModeIsAuto := false   ; 手動発動
            UpdateFocusBtnState()
            FocusModeMinimizeWithCountdown()
            TrayTip("🎯 集中モード開始", "10秒後にウィンドウを最小化します", "Mute")
        }
    } else if (g.phase = "break" || g.phase = "done") {
        ; 休憩中・完了後は ON/OFF 切り替え可能
        g.focusMode := !g.focusMode
        if (g.focusMode)
            g.focusModeIsAuto := false   ; 手動発動
        UpdateFocusBtnState()
        if (g.focusMode) {
            FocusModeMinimizeWithCountdown()
            TrayTip("🎯 集中モード開始", "10秒後にウィンドウを最小化します", "Mute")
        } else {
            FocusModeRestore()
            TrayTip("集中モード解除", "ウィンドウを復元しました", "Mute")
        }
    }
}

; ===== 集中モードボタンの状態更新（変更不要）=====
UpdateFocusBtnState() {
    global g, focusBtn
    if (g.phase = "lock") {
        ; ロック中：未ON時のみ有効（ONのまま解除できないようグレーアウト）
        focusBtn.Enabled := !g.focusMode
    } else if (g.phase = "break" || g.phase = "done" || g.phase = "intermission") {
        focusBtn.Enabled := true
    } else {
        focusBtn.Enabled := false
    }
}

; ===== 外出モードボタン処理（変更不要）=====
; 数時間単位の外出のために、現在のフェーズ（ロック・休憩・中休み・クロッキー問わず）を
; 無期限に一時停止する。既存の g.isPaused の仕組みをそのまま利用し、
; g.pausedRemainingMs に残り時間を保存しておくことで、再開時に
; 経過した現実時間を巻き戻す形で正しく引き継ぐ（食事休憩・運動と同じ方式）。
OnGoOut(btn, *) {
    global g, goOutBtn, timerGui, timerTitle, timerSub

    if (!g.goingOut) {
        ; 食事休憩・運動モードと重ねると、それぞれの終了処理と競合するため
        ; 開始不可にする（先に終了してから外出モードを使ってもらう）
        if (g.isExercise || g.inMealPause) {
            TrayTip("🚪 外出モード", "食事休憩・運動モード中は開始できません。終了してからお試しください", "Mute")
            return
        }

        g.goingOut          := true
        g.isPaused          := true
        g.idlePaused        := false
        g.pausedRemainingMs := Max(0, g.endTick - A_TickCount)
        g.goOutSavedTitle   := timerTitle.Value
        g.goOutSavedSub     := timerSub.Value
        g.goOutSavedColor   := timerGui.BackColor

        timerGui.BackColor := "37474F"
        timerTitle.Value   := "🚪 外出モード"
        timerSub.Value     := "戻ったらこのボタンを押して再開してください"
        goOutBtn.Text      := "▶ 再開"
        SoundPlay("*48")
        TrayTip("🚪 外出モード", "タイマーを一時停止しました。戻ったら再開ボタンを押してください", "Mute")
    } else {
        g.goingOut        := false
        g.isPaused        := false
        g.idlePaused       := false
        g.lastActiveCheck := 0   ; 作業時間の誤加算防止（他の一時停止解除と同じパターン）
        g.endTick         := A_TickCount + g.pausedRemainingMs

        timerGui.BackColor := g.goOutSavedColor
        timerTitle.Value   := g.goOutSavedTitle
        timerSub.Value     := g.goOutSavedSub
        goOutBtn.Text      := "🚪"
        SoundPlay("*48")
        TrayTip("▶ 再開", "タイマーを再開しました", "Mute")
    }
}

; ================================================================
; ★ 集中モード開始猶予の設定
;    集中モードに入る際、この秒数だけ待ってからウィンドウを最小化します。
;    動画などを停止する猶予として使ってください。
;    0にすると即時実行します。
; ================================================================
focusModeCountdownSecs := 15

; ===== 集中モード：カウントダウン付き起動（変更不要）=====
FocusModeMinimizeWithCountdown() {
    global g, timerSub, focusModeCountdownSecs

    if (focusModeCountdownSecs <= 0) {
        FocusModeMinimize()
        return
    }

    g.focusCountdownEnd  := A_TickCount + (focusModeCountdownSecs * 1000)
    g.focusCountingDown  := true   ; ブロックを一時停止
    SetTimer(FocusCountdownTick, 300)
}

FocusCountdownTick() {
    global g, timerSub

    remaining := g.focusCountdownEnd - A_TickCount
    if (remaining <= 0) {
        SetTimer(FocusCountdownTick, 0)
        g.focusCountingDown := false   ; ブロック再開
        if (g.focusMode)
            FocusModeMinimize()
        if (g.phase = "lock")
            timerSub.Value := "remaining time  🎯"
        else if (g.phase = "break")
            timerSub.Value := "enjoy your break!  🎯 ON"
        return
    }

    secs := Ceil(remaining / 1000)
    timerSub.Value := "🎯 集中モード開始まで " secs " 秒..."
}

; ===== 配列に指定した値が含まれるか判定（変更不要）=====
HasVal(arr, val) {
    for v in arr {
        if (v = val)
            return true
    }
    return false
}

; ===== 集中モード：許可リスト以外の全ウィンドウを最小化（変更不要）=====
FocusModeMinimize() {
    global g, focusModeAllowList, focusModeAllowProcesses, timerGui

    ; ---------------------------------------------------------------
    ; システム保護リスト（変更不要）
    ; Windowsの動作に必須なプロセス・ウィンドウタイトルを除外します。
    ; ユーザーが触れる必要はありません。
    ; ---------------------------------------------------------------

    ; 保護プロセス名（これらのexeが出すウィンドウはすべて最小化しない）
    systemProcesses := [
        "explorer.exe",                  ; デスクトップ・タスクバー・エクスプローラー
        "ShellExperienceHost.exe",       ; 音量・Wi-Fi・通知などのシステムポップアップ
        "StartMenuExperienceHost.exe",   ; スタートメニュー
        "SearchHost.exe",                ; Windows検索
        "SearchApp.exe",                 ; Windows検索（旧版）
        "SystemSettings.exe",            ; Windowsの設定
        "SndVol.exe",                    ; クラシック音量ミキサー
        "Taskmgr.exe",                   ; タスクマネージャー
        "TextInputHost.exe",             ; タッチキーボード・IMEツールバー
        "ScreenClippingHost.exe",        ; スクリーンショットツール
        "SnippingTool.exe",              ; 切り取り&スケッチ
        "msedgewebview2.exe",            ; Webview2（各種システムUI）
        "ApplicationFrameHost.exe",      ; UWPアプリのフレーム
        "LockApp.exe",                   ; ロック画面
        "LogonUI.exe",                   ; ログイン画面
        "fontdrvhost.exe",               ; フォントドライバ
        "dwm.exe",                       ; デスクトップウィンドウマネージャー
    ]

    ; 保護ウィンドウタイトル（タイトルにこれが含まれるウィンドウは最小化しない）
    systemExempt := [
        "Program Manager",
        "Windows Input Experience",
        "Task Switching",
        "タスクマネージャー",
        "Task Manager",
        "音量ミキサー",
        "Volume Mixer",
    ]

    winList := WinGetList()
    for hwnd in winList {
        try {
            ; 最小化済みはスキップ
            if (WinGetMinMax("ahk_id " hwnd) = -1)
                continue

            ; タイマーGUI自体はスキップ
            if (hwnd = timerGui.Hwnd)
                continue

            title := WinGetTitle("ahk_id " hwnd)

            ; タイトルが空（非表示ウィンドウ等）はスキップ
            if (title = "")
                continue

            ; システムウィンドウはスキップ
            skip := false
            for sysKey in systemExempt {
                if InStr(title, sysKey) {
                    skip := true
                    break
                }
            }
            if skip
                continue

            ; 許可リストに含まれるウィンドウはスキップ
            for allowKey in focusModeAllowList {
                if InStr(title, allowKey) {
                    skip := true
                    break
                }
            }
            if skip
                continue

            ; システム保護プロセス・ユーザー許可プロセスはスキップ
            try {
                procName := WinGetProcessName("ahk_id " hwnd)
                for sysProc in systemProcesses {
                    if (StrLower(procName) = StrLower(sysProc)) {
                        skip := true
                        break
                    }
                }
                if (!skip) {
                    for allowProc in focusModeAllowProcesses {
                        if (StrLower(procName) = StrLower(allowProc)) {
                            skip := true
                            break
                        }
                    }
                }
            }
            if skip
                continue

            WinMinimize("ahk_id " hwnd)
            if (!HasVal(g.focusMinimizedHwnds, hwnd))   ; 重複記録を防止（同じウィンドウが何度もトグルする対策）
                g.focusMinimizedHwnds.Push(hwnd)   ; 復元用に記録
        }
    }

    ; タイマーGUIが万一最小化されていた場合に強制再表示
    try {
        if (WinGetMinMax("ahk_id " timerGui.Hwnd) = -1)
            timerGui.Show("NoActivate")
    }
}

; ===== 集中モード：最小化したウィンドウを復元（変更不要）=====
FocusModeRestore() {
    global g
    for hwnd in g.focusMinimizedHwnds {
        try {
            ; まだ存在するウィンドウのみ復元
            if WinExist("ahk_id " hwnd)
                WinRestore("ahk_id " hwnd)
        }
    }
    g.focusMinimizedHwnds := []   ; 記録をクリア
}



; ===== 作業ノルマの残り時間をトレイアイコンのツールチップに表示（変更不要）=====
; ロック中・中休み中・休憩中を問わず、常に直近の状態を表示し続ける
UpdateWorkGoalTip() {
    global g, totalWorkGoalMinutes, effectiveWorkGoalMinutes

    if (totalWorkGoalMinutes = 0)
        return

    if (g.workGoalReached) {
        A_IconTip := "🎯 本日の作業ノルマ達成済み"
        return
    }

    remainMin := Ceil(Max(0, effectiveWorkGoalMinutes * 60000 - g.activeWorkMs) / 60000)
    h := remainMin // 60
    m := Mod(remainMin, 60)
    label := (h > 0) ? h "時間" m "分" : m "分"
    A_IconTip := "🎯 ノルマまであと " label
}
UpdateWorkGoalTip()   ; 起動直後にも初期値を表示しておく

; ===== 作業時間計測：5秒ごとに監視（変更不要）=====
SetTimer(CheckActiveWork, 5000)

CheckActiveWork() {
    global g, totalWorkGoalMinutes, effectiveWorkGoalMinutes, workIdleToleranceSecs, workGoalLogPath, currentDayId

    ; ロックフェーズ・中休み中・一時停止していないときのみ計測
    ; （中休み中も計測対象に含めないと「中休み中に達成した場合も即座に表示」が機能しないため）
    if ((g.phase != "lock" && g.phase != "intermission") || g.isPaused || totalWorkGoalMinutes = 0)
        return

    ; 作業ウィンドウがアクティブか確認
    if (!IsWorkWindow())
        return

    ; 前回チェックからの経過時間を加算
    ; ただし、ウィンドウがアクティブなままでも一定時間以上マウス・キーボードの
    ; 操作が無い場合（スマホをいじっている等）は、その間を作業時間に含めない
    now    := A_TickCount
    idleMs := A_TimeIdlePhysical
    if (g.lastActiveCheck > 0) {
        elapsed := now - g.lastActiveCheck
        if (idleMs < workIdleToleranceSecs * 1000)
            g.activeWorkMs += elapsed
    }
    g.lastActiveCheck := now

    ; 達成チェック（前日の超過分により短縮されている場合は effectiveWorkGoalMinutes で判定）
    if (!g.workGoalReached && g.activeWorkMs >= effectiveWorkGoalMinutes * 60000) {
        g.workGoalReached := true
        SoundPlay("*48")
        TrayTip("🎉 作業達成！", effectiveWorkGoalMinutes " 分の作業時間を達成しました。`n休憩中のスクリプト停止が許可されます。", "Mute")
        ; 中休み中に達成した場合は即座にボタンを表示
        if (g.phase = "intermission")
            workDoneBtn.Visible := true
    }

    ; ファイルに保存（クロッキー→通常作業など、プロセスをまたいで引き継ぐため。
    ; 4項目目に本日の実効ノルマも保存し、翌日の繰り越し計算に使う。
    ; dayId は起動時に読み取った固定値をそのまま使う（睡眠を挟まない限り同じ日として扱うため、
    ; ここで日付を再計算する必要はない）
    SafeWriteFile(workGoalLogPath, currentDayId "|" g.activeWorkMs "|" (g.workGoalReached ? "1" : "0") "|" effectiveWorkGoalMinutes)

    UpdateWorkGoalTip()
}

; ===== 無操作によるロックタイマーの自動一時停止：0.2秒ごとに監視（変更不要）=====
; ロック中（クロッキー含む）にworkIdleToleranceSecs以上無操作なら、
; 作業時間への未加算だけでなく、タイマー自体も一時停止する。
; 操作再開時は次のチェックまで待たず、この0.2秒間隔のチェックで即座に検知して再開する。
; 食事休憩・運動など他の理由で既に一時停止中の場合は一切関与しない
; （g.idlePaused で「このチェックが一時停止させたのか」を区別している）。
SetTimer(CheckIdleTimerPause, 200)

CheckIdleTimerPause() {
    global g, timerTitle, timerSub, workIdleToleranceSecs, isCroquis, croquisArg

    ; ロック中のみが対象（休憩・中休みは対象外。中休みは無操作でも
    ; タイマーが進み続けることが「自動でセット追加」の前提になっているため）
    if (g.phase != "lock")
        return

    ; 【要望】教本模写モード（モード5・7）は、教本の文章を読んでいるために
    ; 無操作になっているだけでサボっているわけではないため、対象外にする
    if (isCroquis && (croquisArg.mode = 5 || croquisArg.mode = 7))
        return

    ; クロッキーの撮影待機中も対象外にする。
    ; 撮影待機のカウントダウン（CaptureCountdownTick）は g.isPaused を見ずに
    ; 独自に時間を管理しているため、ここで一時停止フラグを立ててしまうと、
    ; 撮影完了→次フェーズへ移行した後もフラグだけが残留し、
    ; 次のフェーズのタイマーが永久に止まったままになる不具合があった。
    if (g.inCaptureWait)
        return

    idleMs    := A_TimeIdlePhysical
    isIdleNow := (idleMs >= workIdleToleranceSecs * 1000)

    if (isIdleNow) {
        if (!g.isPaused) {
            ; まだ何にも一時停止されていない状態からのみ、無操作による一時停止を開始する
            g.idlePaused        := true
            g.isPaused          := true
            g.pausedRemainingMs := Max(0, g.endTick - A_TickCount)
            g.idleSavedTitle    := timerTitle.Value
            g.idleSavedSub      := timerSub.Value
            timerTitle.Value    := "⏸ 離席検知中"
            timerSub.Value      := "操作を再開すると自動的に再開します"
        }
    } else {
        if (g.idlePaused) {
            ; 無操作による一時停止のみを解除する（他の理由による一時停止は触らない）
            g.idlePaused      := false
            g.isPaused        := false
            g.lastActiveCheck := 0   ; 作業時間の誤加算防止（他の一時停止解除と同じパターン）
            g.endTick         := A_TickCount + g.pausedRemainingMs
            timerTitle.Value  := g.idleSavedTitle
            timerSub.Value    := g.idleSavedSub
        }
    }
}

; ===== ゲームプレイ時間監視：10秒ごとに（変更不要）=====
SetTimer(CheckGameLimit, 10000)

; 本日のプレイ時間を読み込む（日付が変わっていたらリセット）
_gamePlayedMs := 0
_gameLimitDate := ""
try {
    _gameData := StrSplit(FileRead(gameLimitLogPath), "|")
    if (_gameData[1] = FormatTime(, "yyyyMMdd"))
        _gamePlayedMs := Integer(_gameData[2])
}
global gamePlayedMs  := _gamePlayedMs   ; 本日の累計プレイ時間（ms）
global gameActiveMs  := 0               ; 現在セッションの連続プレイ時間（ms）
global gameLastCheck := 0               ; 前回チェックのTickCount
global gameExtendSetsDone := 0          ; 延長のために完了したセット数

; ゲームウィンドウが対象かを判定する関数
IsGameWindow() {
    global gameLimitTargets
    try {
        hwnd := WinGetID("A")
        if (!hwnd) 
            return false
        title := WinGetTitle("ahk_id " hwnd)
        proc  := WinGetProcessName("ahk_id " hwnd)
        for t in gameLimitTargets {
            if (t.type = "process" && StrLower(proc) = StrLower(t.key))
                return true
            if (t.type = "title" && InStr(title, t.key))
                return true
        }
    }
    return false
}

; ゲームウィンドウをすべて最小化する
MinimizeGameWindows() {
    global gameLimitTargets
    SetTitleMatchMode(2)
    for t in gameLimitTargets {
        if (t.type = "title") {
            winList := WinGetList(t.key)
            for hwnd in winList {
                try WinMinimize("ahk_id " hwnd)
            }
        } else {
            winList := WinGetList("ahk_exe " t.key)
            for hwnd in winList {
                try WinMinimize("ahk_id " hwnd)
            }
        }
    }
}

; ゲームを通常終了する（WinClose）
CloseGameWindows() {
    global gameLimitTargets
    SetTitleMatchMode(2)
    for t in gameLimitTargets {
        if (t.type = "title") {
            winList := WinGetList(t.key)
            for hwnd in winList {
                try WinClose("ahk_id " hwnd)
            }
        } else {
            winList := WinGetList("ahk_exe " t.key)
            for hwnd in winList {
                try WinClose("ahk_id " hwnd)
            }
        }
    }
}

CheckGameLimit() {
    global g, gameLimitMinutes, gameLimitTargets, gameLimitLogPath
    global gamePlayedMs, gameLastCheck, gameLimitExtendSets, gameExtendSetsDone

    if (gameLimitMinutes = 0)
        return

    now := A_TickCount

    ; ゲームがアクティブか確認し、プレイ時間を加算
    if (IsGameWindow()) {
        if (gameLastCheck > 0)
            gamePlayedMs += (now - gameLastCheck)
        gameLastCheck := now
    } else {
        gameLastCheck := 0
    }

    ; ファイルに保存
    try FileDelete(gameLimitLogPath)
    FileAppend(FormatTime(, "yyyyMMdd") "|" gamePlayedMs, gameLimitLogPath)

    ; 制限到達チェック
    limitMs := gameLimitMinutes * 60000
    if (gamePlayedMs >= limitMs && !g.gameLimitReached) {
        g.gameLimitReached := true
        SoundPlay("*48")
        TrayTip("🎮 ゲーム制限到達", gameLimitMinutes " 分のプレイ時間に達しました。ゲームを終了します。", "Mute")
        Sleep(3000)
        CloseGameWindows()
    }

    ; 制限到達後はゲームを最小化し続ける
    if (g.gameLimitReached)
        MinimizeGameWindows()
}

; ===== 食事休憩チェック：15秒ごとに監視（変更不要）=====
SetTimer(CheckMealPause, 15000)

CheckMealPause() {
    global g, timerGui, timerTitle, timerCount, timerSub, mealEndBtn
    global mealPauseStartH, mealPauseStartM, mealPauseEndH, mealPauseEndM

    if (g.phase = "")
        return

    ; 撮影処理中（スクリーンショット撮影〜フェーズ切り替え完了まで）は見送る。
    ; この間に食事休憩を割り込ませると、撮影自体は続行される一方で表示だけ
    ; 食事休憩に切り替わり、撮影完了後の次フェーズ表示で上書きされてしまう
    ; （無操作一時停止と同じ理由で対象外にしている）。次のチェック（最大15秒後）
    ; で改めて判定される。
    if (g.inCaptureWait)
        return

    h := Integer(FormatTime(, "H"))
    m := Integer(FormatTime(, "m"))
    currentMins   := h * 60 + m
    pauseStartMin := mealPauseStartH * 60 + mealPauseStartM
    pauseEndMin   := mealPauseEndH   * 60 + mealPauseEndM
    inWindow      := (currentMins >= pauseStartMin && currentMins < pauseEndMin)

    if (inWindow && !g.inMealPause) {
        g.inMealPause := true

        if (g.isExercise)
            return

        ; 現在の表示内容をそのまま保存しておく（g.phase から再構築するのではなく、
        ; そのまま復元できるようにする）。通常のロック・休憩に限らず、クロッキーの
        ; どのフェーズ（セット中・撮影待機後の次セット案内・休憩など）で食事休憩が
        ; 挟まっても、終了後に正しい表示へ戻せる。
        g.mealSavedTitle := timerTitle.Value
        g.mealSavedSub   := timerSub.Value
        g.mealSavedColor := timerGui.BackColor

        g.isPaused          := true
        g.idlePaused        := false   ; 無操作検知による一時停止ではないことを明示
        g.pausedRemainingMs := Max(0, g.endTick - A_TickCount)

        WritePhase("lunch")   ; サボり検知を無効化
        timerGui.BackColor := "37474F"
        timerTitle.Value   := "🍽️ 食事休憩中"
        timerCount.Visible := false   ; 数字表示を隠し、代わりに手動終了ボタンを表示
        endTimeStr         := Format("{:02d}:{:02d}", mealPauseEndH, mealPauseEndM)
        timerSub.Value     := endTimeStr " に自動で再開します（手動終了も可）"
        mealEndBtn.Visible := true
        NextDnsUnblock()
        SoundPlay("*48")
        TrayTip("食事休憩", endTimeStr " にタイマーを再開します", "Mute")

    } else if (!inWindow && g.inMealPause) {
        g.inMealPause := false

        if (g.isExercise)
            return

        EndMealPauseResume()
    }
}

; ===== 食事休憩終了時の共通処理（自動終了・手動終了ボタン共通・変更不要）=====
EndMealPauseResume() {
    global g, timerGui, timerTitle, timerCount, timerSub, mealEndBtn

    g.isPaused        := false
    g.idlePaused      := false   ; 念のため無操作フラグも解除しておく
    g.lastActiveCheck := 0   ; 食事休憩中の経過時間が作業時間に加算されないようリセット
    g.endTick         := A_TickCount + g.pausedRemainingMs

    timerCount.Visible := true
    mealEndBtn.Visible  := false

    WritePhase(g.phase)   ; サボり検知を元のフェーズに戻す

    ; 食事休憩前に保存しておいた表示内容をそのまま復元する
    ; （通常のロック・休憩に限らず、クロッキーのどのフェーズでも正しく戻せる）
    timerGui.BackColor := g.mealSavedColor
    timerTitle.Value   := g.mealSavedTitle
    timerSub.Value     := g.mealSavedSub

    if (g.phase = "lock")
        NextDnsBlock()
    SoundPlay("*48")
    TrayTip("作業再開", "タイマーを再開します", "Mute")
}

; ===== 食事休憩の手動終了ボタン処理（変更不要）=====
OnMealEnd(btn, *) {
    global g

    if (!g.inMealPause)
        return

    g.inMealPause := false

    if (g.isExercise)   ; 運動中は運動終了時にまとめて処理されるため何もしない
        return

    EndMealPauseResume()
}

; ===== 運動ボタン処理（変更不要）=====
OnExerciseStart(btn, *) {
    global g, exerciseBtn, exerciseUnlockKey, exerciseUnlockMinutes, exerciseLogPath
    global timerGui, timerTitle, timerCount, timerSub

    try FileDelete(exerciseLogPath)
    FileAppend(FormatTime(, "yyyyMMdd"), exerciseLogPath)
    exerciseBtn.Enabled := false

    newList := []
    for t in g.targetTitles {
        if (t != exerciseUnlockKey)
            newList.Push(t)
    }
    g.targetTitles := newList

    g.isPaused          := true
    g.idlePaused        := false   ; 無操作検知による一時停止ではないことを明示
    g.pausedRemainingMs := Max(0, g.endTick - A_TickCount)
    g.isExercise        := true
    g.exerciseEndTick   := A_TickCount + (exerciseUnlockMinutes * 60 * 1000)

    timerGui.BackColor := "E65100"
    timerTitle.Value   := "🚴 運動モード（Steam 解除中）"
    timerCount.Value   := Format("{:02d}:00", exerciseUnlockMinutes)
    timerSub.Value     := "通常タイマーは一時停止中"

    WritePhase("exercise")   ; サボり検知を無効化
    NextDnsUnblock()
    SoundPlay("*48")
    TrayTip("運動モード開始", exerciseUnlockMinutes " 分間 " exerciseUnlockKey " のブロックを解除します", "Mute")

    SetTimer(ExerciseTimer, 300)
}

ExerciseTimer() {
    global g, timerCount

    remaining := g.exerciseEndTick - A_TickCount

    if (remaining <= 0) {
        SetTimer(ExerciseTimer, 0)
        ResumeAfterExercise()
        return
    }

    secs := Ceil(remaining / 1000)
    mins := secs // 60
    secs := Mod(secs, 60)
    timerCount.Value := Format("{:02d}:{:02d}", mins, secs)
}

ResumeAfterExercise() {
    global g, exerciseUnlockKey, timerGui, timerTitle, timerCount, timerSub, mealEndBtn
    global mealPauseEndH, mealPauseEndM

    g.targetTitles.Push(exerciseUnlockKey)
    g.isExercise := false

    if (g.inMealPause) {
        ; 運動終了時点でまだ食事休憩中だった場合。
        ; 手動終了ボタンはここでは出さず（運動→食事の遷移は稀なケースのため）、
        ; 数字表示は "--:--" のまま見せておき、自動終了（CheckMealPause）を待つ。
        timerGui.BackColor := "37474F"
        timerTitle.Value   := "🍽️ 食事休憩中"
        timerCount.Value   := "--:--"
        timerCount.Visible := true
        mealEndBtn.Visible := false
        endTimeStr         := Format("{:02d}:{:02d}", mealPauseEndH, mealPauseEndM)
        timerSub.Value     := endTimeStr " に自動で再開します"
        NextDnsUnblock()   ; 食事休憩中はスマホブロックを解除
    } else {
        g.isPaused        := false
        g.idlePaused      := false   ; 念のため無操作フラグも解除しておく
        g.lastActiveCheck := 0   ; 一時停止中の経過時間が作業時間に加算されないようリセット
        g.endTick         := A_TickCount + g.pausedRemainingMs

        if (g.phase = "lock") {
            timerGui.BackColor := "CC3333"
            timerTitle.Value   := "🔒 Lock  -  Set " g.currentSet "/" g.totalSets
            timerSub.Value     := "remaining time"
        } else {
            timerGui.BackColor := "2E7D32"
            timerTitle.Value   := "☕ Break  -  Set " g.currentSet "/" g.totalSets
            timerSub.Value     := "enjoy your break!"
        }
    }

    ; フェーズファイルを元のフェーズに戻す（サボり検知を再開）
    WritePhase(g.phase)
    if (g.phase = "lock")
        NextDnsBlock()
    SoundPlay("*48")
    TrayTip("運動終了", exerciseUnlockKey " のブロックを再開しました", "Mute")
}

; ===== 起動モード判定（変更不要）=====
global isAuto     := false
global isCroquis  := false
global croquisArg := {lockSecs: 1500, sets: 1, interSecs: 0, mode: 1, isTest: false}   ; デフォルトはモード1

for arg in A_Args {
    if (arg = "/auto")
        isAuto := true
    if (SubStr(arg, 1, 8) = "/croquis") {
        isCroquis := true
        ; /croquis:lockSecs:sets:interSecs:mode:test の形式で受け取る
        parts := StrSplit(arg, ":")
        if (parts.Length >= 4) {
            croquisArg.lockSecs  := Integer(parts[2])
            croquisArg.sets      := Integer(parts[3])
            croquisArg.interSecs := Integer(parts[4])
        }
        ; mode（5番目）は次セットの画像選択で使うフォルダの判定に使う。
        ; 旧バージョンのlauncher.ahk（modeを渡さない）からの起動でも動くよう、
        ; 省略時はモード1として扱う。
        if (parts.Length >= 5)
            croquisArg.mode := Integer(parts[5])
        ; test（6番目）は「右脳ドローイングのテスト実行」用フラグ。
        ; 1 のときは croquis_used_fast.txt への書き込み（使用済みマーク）を行わず、
        ; current_phase.txt にも "lock" ではなく "lock_test" を書き込んで
        ; launcher.ahk 側のサボり監視・残業計測から除外する。
        if (parts.Length >= 6)
            croquisArg.isTest := (parts[6] = "1")
    }
}

if (isCroquis) {
    targetTitles := []
    for site in siteList
        targetTitles.Push(site.key)
    alreadyHas := false
    for t in targetTitles {
        if (t = exerciseUnlockKey) {
            alreadyHas := true
            break
        }
    }
    if !alreadyHas
        targetTitles.Push(exerciseUnlockKey)

    g.targetTitles    := targetTitles
    g.focusMode       := true
    g.focusModeIsAuto := false

    timerGui.Show("NoActivate")

    ; モード6（右脳ドローイング・テスト実行専用）とモード8（右脳ドローイング・
    ; 軽め、本番用）は、既存モードと大きく仕組みが異なる（クリップボード貼り付け
    ; ではなく参照ウィンドウ自動切り替え）ため、専用のフローに分岐する。
    ; モード6はcroquisModeParamsには未登録＝通常のランダム選択やcroquisMode設定
    ; からは絶対に到達しない、テスト実行専用の入口。
    ; モード8はcroquisModeParamsに登録された本番モードだが、ランダム抽選からは
    ; 常に除外される（launcher.ahk側で明示的に除外している）。撮影は行わず、
    ; 毎セットの後に必ずinterSecs秒の休憩＋次画像の位置調整時間を挟む点がモード6と異なる。
    if (croquisArg.mode = 6)
        RunFastCroquis(croquisArg.sets, croquisArg.lockSecs, croquisArg.interSecs)
    else if (croquisArg.mode = 8)
        RunFastCroquisPractice(croquisArg.sets, croquisArg.lockSecs, croquisArg.interSecs)
    else
        RunPomodoroCroquis(targetTitles, croquisArg.lockSecs, croquisArg.sets, croquisArg.interSecs)

} else if (isAuto) {
    targetTitles := []
    for site in siteList {
        targetTitles.Push(site.key)
    }
    alreadyHas := false
    for t in targetTitles {
        if (t = exerciseUnlockKey) {
            alreadyHas := true
            break
        }
    }
    if !alreadyHas
        targetTitles.Push(exerciseUnlockKey)
    timerGui.Show("NoActivate")
    RunPomodoro(targetTitles, autoLockSecs, autoBreakSecs, autoTotalSets)

} else {
    myGui := Gui(, "Window Locker")
    myGui.SetFont("s11", "Segoe UI")

    myGui.Add("Text",, "Lock duration:")
    lockDropdown := myGui.Add("DropDownList", "w220", [])
    for t in lockTimeList {
        lockDropdown.Add([t.label])
    }
    lockDropdown.Choose(4)

    myGui.Add("Text", "y+12", "Break duration:")
    breakDropdown := myGui.Add("DropDownList", "w220", [])
    for t in breakTimeList {
        breakDropdown.Add([t.label])
    }
    breakDropdown.Choose(2)

    myGui.Add("Text", "y+12", "Sets:")
    setDropdown := myGui.Add("DropDownList", "w220", [])
    for s in setCountList {
        setDropdown.Add([s.label])
    }
    setDropdown.Choose(3)

    myGui.Add("Button", "y+20 w220", "Start").OnEvent("Click", StartPomodoro)
    myGui.Show()
}

; ===== 手動起動時のスタートボタン処理（変更不要）=====
StartPomodoro(btn, *) {
    global siteList, lockTimeList, breakTimeList, setCountList
    global siteDropdown, lockDropdown, breakDropdown, setDropdown, myGui
    global timerGui, exerciseUnlockKey

    selectedLock  := lockTimeList[lockDropdown.Value]
    selectedBreak := breakTimeList[breakDropdown.Value]
    selectedSets  := setCountList[setDropdown.Value]

    myGui.Hide()
    timerGui.Show("NoActivate")

    ; 手動起動もランチャーと同様にsiteList全件をブロック対象にする
    targets := []
    for site in siteList {
        targets.Push(site.key)
    }
    alreadyHas := false
    for t in targets {
        if (t = exerciseUnlockKey) {
            alreadyHas := true
            break
        }
    }
    if !alreadyHas
        targets.Push(exerciseUnlockKey)

    RunPomodoro(targets, selectedLock.seconds, selectedBreak.seconds, selectedSets.count)
}

; ===== セット間の次画像選択（変更不要）=====
; launcher の PickCroquisImage と同じロジック。lock_window 側から呼ぶ用。
PickNextCroquisImage() {
    global croquisArg   ; 起動時に launcher.ahk から渡されたモード番号を使う

    mode   := croquisArg.mode
    ; launcher.ahk側のフォルダ命名規則（croquis_models_<mode>）と合わせる
    folder := A_ScriptDir "\croquis_models_" mode
    ; 使用済みログは全モード共通の1ファイル（launcher.ahk側と共有）。
    ; モードをまたいで同じ画像が二度使われないようにするため一元管理する。
    usedLogPath := A_ScriptDir "\croquis_used.txt"

    exts    := ["*.jpg", "*.jpeg", "*.png", "*.bmp", "*.webp"]
    allImgs := []
    for ext in exts {
        loop files folder "\" ext
            allImgs.Push(A_LoopFileName)
    }
    if (allImgs.Length = 0)
        return ""

    usedList := []
    try {
        raw := FileRead(usedLogPath)
        loop parse raw, "`n", "`r" {
            if (Trim(A_LoopField) != "")
                usedList.Push(Trim(A_LoopField))
        }
    }

    unused := []
    for img in allImgs {
        used := false
        for u in usedList {
            if (StrLower(u) = StrLower(img)) {
                used := true
                break
            }
        }
        if (!used)
            unused.Push(img)
    }

    ; このモードのフォルダを全部使い切ったら、共有リストから
    ; 「このモードの画像分だけ」を取り除いてリセットする（他モードの履歴は残す）
    if (unused.Length = 0) {
        remaining := []
        for u in usedList {
            belongsToThisMode := false
            for img in allImgs {
                if (StrLower(u) = StrLower(img)) {
                    belongsToThisMode := true
                    break
                }
            }
            if (!belongsToThisMode)
                remaining.Push(u)
        }
        try FileDelete(usedLogPath)
        for r in remaining
            FileAppend(r "`n", usedLogPath)
        unused := allImgs
    }

    idx      := Random(1, unused.Length)
    selected := unused[idx]
    FileAppend(selected "`n", usedLogPath)
    return folder "\" selected
}

CopyNextCroquisImage(path) {
    hGdiPlus := DllCall("LoadLibrary", "Str", "gdiplus.dll", "Ptr")
    if (!hGdiPlus)
        return

    token := 0
    si    := Buffer(24, 0)
    NumPut("UInt", 1, si, 0)
    DllCall("gdiplus\GdiplusStartup", "Ptr*", &token, "Ptr", si, "Ptr", 0)

    pBitmap := 0
    r := DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", path, "Ptr*", &pBitmap)
    if (r != 0 || !pBitmap) {
        DllCall("gdiplus\GdiplusShutdown", "Ptr", token)
        return
    }

    width := 0, height := 0
    DllCall("gdiplus\GdipGetImageWidth",  "Ptr", pBitmap, "UInt*", &width)
    DllCall("gdiplus\GdipGetImageHeight", "Ptr", pBitmap, "UInt*", &height)

    stride  := width * 4
    dibSize := 40 + (stride * height)
    hDib    := DllCall("GlobalAlloc", "UInt", 2, "UPtr", dibSize, "Ptr")
    pDib    := DllCall("GlobalLock", "Ptr", hDib, "Ptr")

    NumPut("UInt",   40,              pDib,  0)
    NumPut("Int",    width,           pDib,  4)
    NumPut("Int",    -height,         pDib,  8)
    NumPut("UShort", 1,               pDib, 12)
    NumPut("UShort", 32,              pDib, 14)
    NumPut("UInt",   0,               pDib, 16)
    NumPut("UInt",   stride * height, pDib, 20)
    loop 5
        NumPut("UInt", 0, pDib, 24 + (A_Index - 1) * 4)

    rect := Buffer(16, 0)
    NumPut("Int", 0,      rect,  0)
    NumPut("Int", 0,      rect,  4)
    NumPut("Int", width,  rect,  8)
    NumPut("Int", height, rect, 12)

    bmpData := Buffer(32, 0)
    NumPut("UInt", stride,     bmpData,  8)
    NumPut("UInt", 0x0026200A, bmpData, 12)
    NumPut("Ptr",  pDib + 40,  bmpData, 16)

    DllCall("gdiplus\GdipBitmapLockBits",
        "Ptr", pBitmap, "Ptr", rect,
        "UInt", 5, "Int", 0x0026200A, "Ptr", bmpData)
    DllCall("gdiplus\GdipBitmapUnlockBits", "Ptr", pBitmap, "Ptr", bmpData)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
    DllCall("gdiplus\GdiplusShutdown", "Ptr", token)
    DllCall("GlobalUnlock", "Ptr", hDib)

    hBitmap := 0
    hdc     := DllCall("GetDC", "Ptr", 0, "Ptr")
    hBitmap := DllCall("CreateDIBitmap", "Ptr", hdc,
        "Ptr", pDib, "UInt", 4, "Ptr", pDib + 40, "Ptr", pDib, "UInt", 0, "Ptr")
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)

    DllCall("OpenClipboard", "Ptr", 0)
    DllCall("EmptyClipboard")
    if (hBitmap)
        DllCall("SetClipboardData", "UInt", 2, "Ptr", hBitmap)
    DllCall("SetClipboardData",     "UInt", 8, "Ptr", hDib)
    DllCall("CloseClipboard")
}

; ===== クロッキー成果キャプチャ（変更不要）=====
; CLIPStudioウィンドウを前面に出してからPowerShellでキャプチャ。
; 保存先: croquis_shots\yyyy-MM-dd_HH-mm.png
; ユーザー操作なしで自動実行されるため誤魔化し不可。
CaptureCroquisResult() {
    global croquisShotDir

    ; 保存先フォルダを準備
    if !DirExist(croquisShotDir)
        DirCreate(croquisShotDir)

    ; CLIPStudioを前面へ（見つからなければそのままキャプチャ）
    try {
        WinActivate("ahk_exe CLIPStudioPaint.exe")
        Sleep(800)   ; 描画が安定するまで待機
    }

    ; ファイル名は年月日のみ。同日に複数枚撮る場合は連番を付加する
    dateStr  := FormatTime(, "yyyy-MM-dd")
    savePath := croquisShotDir "\" dateStr ".png"
    if (FileExist(savePath)) {
        n := 2
        while (FileExist(croquisShotDir "\" dateStr "_" n ".png"))
            n += 1
        savePath := croquisShotDir "\" dateStr "_" n ".png"
    }

    ; PowerShellでCLIPStudioウィンドウだけをキャプチャ
    ; ウィンドウが見つからない場合はフルスクリーンにフォールバック
    q  := Chr(34)
    ps := "Add-Type -AssemblyName System.Windows.Forms,System.Drawing`n"
    ps .= "$clip = Get-Process CLIPStudioPaint -ErrorAction SilentlyContinue | Select-Object -First 1`n"
    ps .= "if ($clip -and $clip.MainWindowHandle -ne 0) {`n"
    ps .= "    Add-Type @'`n"
    ps .= "    using System; using System.Runtime.InteropServices; using System.Drawing;`n"
    ps .= "    public class WinRect {`n"
    ps .= "        [DllImport(" q "user32.dll" q ")] public static extern bool GetWindowRect(IntPtr h, out RECT r);`n"
    ps .= "        [DllImport(" q "user32.dll" q ")] public static extern bool SetForegroundWindow(IntPtr h);`n"
    ps .= "        public struct RECT { public int L,T,R,B; }`n"
    ps .= "    }`n"
    ps .= "'@ -ErrorAction SilentlyContinue`n"
    ps .= "    $h = $clip.MainWindowHandle`n"
    ps .= "    $r = New-Object WinRect+RECT`n"
    ps .= "    [WinRect]::GetWindowRect($h, [ref]$r) | Out-Null`n"
    ps .= "    $w = $r.R - $r.L; $ht = $r.B - $r.T`n"
    ps .= "    if ($w -gt 0 -and $ht -gt 0) {`n"
    ps .= "        $bmp = New-Object System.Drawing.Bitmap($w, $ht)`n"
    ps .= "        $g = [System.Drawing.Graphics]::FromImage($bmp)`n"
    ps .= "        $g.CopyFromScreen($r.L, $r.T, 0, 0, [System.Drawing.Size]::new($w, $ht))`n"
    ps .= "        $bmp.Save(" q savePath q ")`n"
    ps .= "        $g.Dispose(); $bmp.Dispose()`n"
    ps .= "    }`n"
    ps .= "} else {`n"
    ps .= "    $s = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds`n"
    ps .= "    $bmp = New-Object System.Drawing.Bitmap($s.Width, $s.Height)`n"
    ps .= "    $g = [System.Drawing.Graphics]::FromImage($bmp)`n"
    ps .= "    $g.CopyFromScreen(0, 0, 0, 0, $s.Size)`n"
    ps .= "    $bmp.Save(" q savePath q ")`n"
    ps .= "    $g.Dispose(); $bmp.Dispose()`n"
    ps .= "}`n"

    psPath := A_Temp "\croquis_capture.ps1"
    try FileDelete(psPath)
    FileAppend(ps, psPath, "UTF-8-RAW")
    ; 同期実行（キャプチャ完了を待ってから次の処理へ）
    RunWait('powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File "' psPath '"',, "Hide")
}

; ===== クロッキー専用ポモドーロ（変更不要）=====
RunPomodoroCroquis(targetTitles, lockSecs, totalSets, interSecs) {
    global g, timerGui, timerTitle, timerCount, timerSub, croquisCaptureWait

    g.targetTitles := targetTitles
    g.totalSets    := totalSets
    g.lockSecs     := lockSecs
    g.breakSecs    := 0
    g.croquisTotal := totalSets
    g.croquisInter := interSecs
    g.croquisSet   := 1

    ; セット1の開始前にも、セット間と同じ待機（画像貼り付け／教本準備）を挟む。
    ; 最初の画像は launcher.ahk が起動前にクリップボードへコピー済みなので、
    ; ここで新しく画像を選ぶ必要はない（貼り付けの案内と待機のみ）。
    ; interSecs が 0 のモードでは待機画面を出さず、そのままセット1を開始する。
    if (interSecs > 0)
        StartCroquisFirstWait(totalSets, interSecs)
    else
        StartNextCroquisSet()
}

; ===== クロッキー・セット1開始前の待機（セット間の待機と同じ仕組み・変更不要）=====
StartCroquisFirstWait(totalSets, interSecs) {
    global g, timerGui, timerTitle, timerCount, timerSub, croquisArg

    ; モード5・7（教本の模写）は画像を一切使わないため、貼り付けの案内は出さない
    noImageMode := (croquisArg.mode = 5 || croquisArg.mode = 7)

    g.generation += 1
    myGen        := g.generation
    g.phase      := "break"
    g.endTick    := A_TickCount + (interSecs * 1000)
    WritePhase("break")

    timerGui.BackColor := "4A148C"   ; 薄紫：セット間と同じ配色
    timerTitle.Value   := "🎨 セット開始まで 1/" totalSets
    timerSub.Value     := noImageMode ? "教本を開いて準備してください" : "サブビューに貼り付けてください"
    SoundPlay("*48")

    SetTimer(FirstWaitTick, 300)

    FirstWaitTick() {
        if (g.generation != myGen) {
            SetTimer(FirstWaitTick, 0)
            return
        }
        if (g.isPaused)
            return

        rem := g.endTick - A_TickCount
        if (rem <= 0) {
            SetTimer(FirstWaitTick, 0)
            g.focusMode       := true
            g.focusModeIsAuto := false
            FocusModeMinimizeWithCountdown()
            StartNextCroquisSet()
            return
        }
        s := Ceil(rem / 1000)
        timerCount.Value := Format("00:{:02d}", s)
    }
}

StartNextCroquisSet() {
    global g, timerGui, timerTitle, timerCount, timerSub, croquisCaptureWait

    setNum     := g.croquisSet
    totalSets  := g.croquisTotal
    lockSecs   := g.lockSecs
    interSecs  := g.croquisInter

    g.generation += 1
    myGen        := g.generation

    g.currentSet      := setNum
    g.phase           := "lock"
    g.lastActiveCheck := 0
    g.endTick         := A_TickCount + (lockSecs * 1000)
    g.isPaused        := false
    g.idlePaused      := false

    WritePhase("lock")
    NextDnsBlock()

    timerGui.BackColor := "6A1B9A"
    timerTitle.SetFont("cWhite")
    timerCount.SetFont("cWhite")
    timerSub.SetFont("cWhite")
    timerTitle.Value := "🎨 クロッキー " setNum "/" totalSets
    timerSub.Value   := "集中モード ON"
    SoundPlay("*48")
    TrayTip("🎨 クロッキー " setNum "/" totalSets, lockSecs // 60 " 分間のロックタイマー", "Mute")
    UpdateFocusBtnState()

    ; モードごとの通知タイミングを lockSecs から決定
    ; 25分(1500s)→残り10分・5分 / 15分(900s)→残り5分・2分 / 5分(300s)→経過2分30秒(1回)
    notifyThresholds := []
    notifyLabels     := []
    notifyFired      := []
    if (lockSecs >= 1200) {           ; モード1相当（20分以上）
        notifyThresholds := [600, 300]
        notifyLabels     := ["残り10分です", "残り5分です"]
    } else if (lockSecs >= 600) {     ; モード2相当（10分以上）
        notifyThresholds := [300, 120]
        notifyLabels     := ["残り5分です", "残り2分です"]
    } else {                          ; モード3相当（短いセット）→経過2分30秒で1回
        notifyThresholds := [lockSecs - 150]   ; 経過150秒 = 残り(lockSecs-150)秒
        notifyLabels     := ["半分経過しました"]
    }
    loop notifyThresholds.Length
        notifyFired.Push(false)

    SetTitleMatchMode(2)
    SetTimer(CroquisLockTick, 300)

    CroquisLockTick() {
        if (g.generation != myGen) {
            SetTimer(CroquisLockTick, 0)
            return
        }
        if (g.isPaused)
            return

        remaining := g.endTick - A_TickCount

        ; 残り時間通知チェック
        loop notifyThresholds.Length {
            idx := A_Index
            if (!notifyFired[idx] && remaining <= notifyThresholds[idx] * 1000) {
                notifyFired[idx] := true
                SoundPlay("*64")
                TrayTip("🎨 クロッキー", notifyLabels[idx], "Mute")
            }
        }

        if (remaining <= 0) {
            SetTimer(CroquisLockTick, 0)
            FocusModeRestore()
            g.inCaptureWait := true   ; 撮影待機中は無操作検知の一時停止対象から除外する

            timerTitle.Value := "🎨 まもなく撮影"
            timerSub.Value   := "画面をズームアウトしてください"
            SoundPlay("*48")
            TrayTip("🎨 セット" setNum "終了", croquisCaptureWait " 秒後に撮影します", "Mute")

            captureEnd := A_TickCount + (croquisCaptureWait * 1000)
            SetTimer(CaptureCountdownTick, 300)

            CaptureCountdownTick() {
                rem := captureEnd - A_TickCount
                if (rem <= 0) {
                    SetTimer(CaptureCountdownTick, 0)

                    ; g.inCaptureWait はここではまだ false にしない。
                    ; CaptureCroquisResult() 内の Sleep(800) と、スクリーンショット
                    ; 保存を待つ RunWait で実質1〜数秒かかるが、その間 g.phase は
                    ; まだ "break" に変わっていない（StartCroquisInterSet/
                    ; StartCroquisBreak が呼ばれて初めて変わる）。この隙間で
                    ; g.inCaptureWait を先に false にしてしまうと、無操作時間が
                    ; すでに閾値を超えていた場合（クロッキーは紙・タブレットに
                    ; 描くことが多く、PC自体の操作は長時間ゼロになりがち）、
                    ; CheckIdleTimerPause がこの隙間で g.isPaused を立ててしまい、
                    ; フェーズが break に変わった後は誰にも解除されず
                    ; セット間カウントダウンが永久に固まる不具合があった。
                    CaptureCroquisResult()
                    NextDnsUnblock()

                    if (setNum < totalSets) {
                        StartCroquisInterSet(setNum, totalSets, lockSecs, interSecs)
                    } else {
                        StartCroquisBreak()
                    }

                    ; フェーズが break に切り替わった後なら、CheckIdleTimerPause は
                    ; phase != "lock" で対象外になるため、ここで false に戻しても安全。
                    g.inCaptureWait := false
                    return
                }
                s := Ceil(rem / 1000)
                timerCount.Value := Format("00:{:02d}", s)
            }
            return
        }

        secs := Ceil(remaining / 1000)
        mins := secs // 60
        secs := Mod(secs, 60)
        timerCount.Value := Format("{:02d}:{:02d}", mins, secs)

        if (g.focusCountingDown)
            return

        for targetTitle in g.targetTitles {
            winList := WinGetList(targetTitle)
            for hwnd in winList {
                try {
                    state := WinGetMinMax("ahk_id " hwnd)
                    if (state != -1)
                        WinMinimize("ahk_id " hwnd)
                }
            }
        }

        if (g.focusMode)
            FocusModeMinimize()
    }

    g.focusMode       := true
    g.focusModeIsAuto := false
    FocusModeMinimizeWithCountdown()
}

; ===== クロッキーセット間休憩（変更不要）=====
; 次のモデル画像をコピーしてから休憩カウントダウン、その後次セットへ
StartCroquisInterSet(doneSet, totalSets, lockSecs, interSecs) {
    global g, timerGui, timerTitle, timerCount, timerSub, croquisArg

    ; モード4（記憶描画モード）は2セット目に新しい画像を選ばない。
    ; 1セット目のモデルを記憶を頼りに描く練習のため。
    skipNextImage := (croquisArg.mode = 4)

    if (!skipNextImage) {
        ; 次の画像をコピー（launcher 側の PickCroquisImage は使えないので
        ; current_phase.txt 経由で launcher に要求する方式ではなく、
        ; lock_window 側でファイルを直接選ぶ）
        nextImg := PickNextCroquisImage()
        if (nextImg != "") {
            CopyNextCroquisImage(nextImg)
            TrayTip("🎨 次のモデル", "クリップボードにコピーしました。サブビューに貼り付けてください", "Mute")
        }
    } else {
        TrayTip("🧠 記憶で描く", "今回は新しい画像を見ずに、記憶を頼りに描いてみましょう", "Mute")
    }

    g.generation += 1
    myGen        := g.generation
    g.phase      := "break"
    g.endTick    := A_TickCount + (interSecs * 1000)
    WritePhase("break")

    nextSet := doneSet + 1
    timerGui.BackColor := "4A148C"   ; 薄紫：セット間
    timerTitle.Value   := "🎨 次のセットまで " nextSet "/" totalSets
    timerSub.Value     := skipNextImage ? "記憶を頼りに描いてみましょう" : "次のモデルをサブビューへ"
    SoundPlay("*48")

    SetTimer(InterSetTick, 300)

    InterSetTick() {
        if (g.generation != myGen) {
            SetTimer(InterSetTick, 0)
            return
        }
        if (g.isPaused)
            return

        rem := g.endTick - A_TickCount
        if (rem <= 0) {
            SetTimer(InterSetTick, 0)
            g.croquisSet  += 1
            g.focusMode       := true
            g.focusModeIsAuto := false
            FocusModeMinimizeWithCountdown()
            StartNextCroquisSet()
            return
        }
        s := Ceil(rem / 1000)
        timerCount.Value := Format("00:{:02d}", s)
    }
}

; ===== 右脳ドローイング：画像選択（モード6・8共通）=====
; PickNextCroquisImage() と同じロジックだが、フォルダは常にfastCroquisFolder
; （croquis_models_2）固定。使用済みリストはテストかどうかで切り替える：
;   ・テスト実行（croquisArg.isTest = true、モード6）：専用の使用済みリスト
;     （croquis_used_fast.txt）を使い、書き込み自体もスキップする（何度実行
;     しても画像を消費しない）
;   ・本番（croquisArg.isTest = false、モード8）：モード8専用の使用済み
;     リスト（croquis_used_practice.txt）を読み書きする
; 【重要】croquis_models_2フォルダをモード2・4と共有してはいるが、
; 使用済み管理はいずれも他モードの共有リスト（croquis_used.txt）とは
; 完全に独立している。モード8で使った画像がモード2・4側で「使用済み」に
; カウントされることはなく、逆にモード2・4で使った画像がモード8側で
; 使用済み扱いになることもない（要望により意図的にこう分離している）。
PickFastCroquisImage() {
    global croquisArg, croquisUsedFastLog, croquisUsedPracticeLog, fastCroquisFolder

    ; ※HTML/ActiveX（Shell.Explorer＝IE/Tridentエンジン）で表示するため、
    ;   webpは読み込めない（IEはwebpに対応していない）ため対象外にしている
    exts    := ["*.jpg", "*.jpeg", "*.png", "*.bmp"]
    allImgs := []
    for ext in exts {
        loop files fastCroquisFolder "\" ext
            allImgs.Push(A_LoopFileName)
    }
    if (allImgs.Length = 0)
        return ""

    usedLogPath := croquisArg.isTest ? croquisUsedFastLog : croquisUsedPracticeLog

    usedList := []
    try {
        raw := FileRead(usedLogPath)
        loop parse raw, "`n", "`r" {
            if (Trim(A_LoopField) != "")
                usedList.Push(Trim(A_LoopField))
        }
    }

    unused := []
    for img in allImgs {
        used := false
        for u in usedList {
            if (StrLower(u) = StrLower(img)) {
                used := true
                break
            }
        }
        if (!used)
            unused.Push(img)
    }

    ; このモード専用ファイルには、そのモード（このフォルダ）の分しか記録
    ; されないため、いずれの場合も丸ごと削除するだけでよい（他モードの
    ; 使用履歴と混在していないため、部分的な取り除き処理は不要）
    if (unused.Length = 0) {
        try FileDelete(usedLogPath)
        unused := allImgs
    }

    idx      := Random(1, unused.Length)
    selected := unused[idx]

    if (!croquisArg.isTest)
        FileAppend(selected "`n", usedLogPath)

    return fastCroquisFolder "\" selected
}

; ===== 右脳ドローイング：参照ウィンドウ（モード6専用）=====
; クリップボード貼り付けの代わりに、常時最前面の小さな専用ウィンドウに
; モデル画像を直接表示する。60秒ごとにプログラム側で自動的に中身が
; 切り替わるため、コピー・貼り付けの手作業が一切不要になる。
;
; 【設計変更の経緯】
; 当初はAHK標準のPicture/Staticコントロールで直接画像を縮小表示していたが、
;   ・GuiControlに.Destroy()メソッドが存在しない
;   ・DllCall(DestroyWindow)で破棄しても内部の名前登録は解除されず、
;     同名で再Addすると"A control with this name already exists."
;   ・.Value での画像差し替えは正しい再スケーリングをしてくれず、
;     一部が拡大されたように表示される
; と、Windows標準コントロール特有の制約を次々に踏んだ。自前でジオメトリ
; 計算をし続ける限り再発しかねないため、Shell.Explorer（Windows標準搭載、
; 追加インストール不要）をActiveXコントロールとしてGuiに埋め込み、画像の
; 拡大縮小・中央寄せは全てHTML/CSS/JS側（fast_croquis_ref.html）に
; 任せる方式に変更した。AHK側はimg要素のsrcをJS経由で書き換えるだけでよく、
; ウィンドウのリサイズもActiveXコントロール自体をMoveするだけで、内部の
; JS側window.onresizeが自動的に再フィットしてくれる。

; 参照ウィンドウ用HTMLファイルを書き出す（起動のたびに上書きするので、
; スクリプト更新時も常に最新の内容になる）。
; #ref（img要素）はJSのfitImage()で「ウィンドウに収まる最大サイズまで
; アスペクト比を保って拡縮・中央寄せ」される。object-fit:containは
; Shell.Explorer（Trident/MSHTML）では効かないため、naturalWidth/Height
; を使って自分でピクセル単位のwidth/height/left/topを計算している。
WriteFastCroquisHtml() {
    global fastCroquisHtmlPath
    html := "
    (
<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<style>
html, body { margin:0; padding:0; background:#000; overflow:hidden; width:100%; height:100%; }
#ref { position:absolute; display:none; -ms-user-select:none; user-select:none; }
body { cursor:move; }
</style>
<script>
// ズーム倍率（ホイールで変更）とパン量（ドラッグで変更）。
// 新しい画像に切り替わるたびにリセットされる（=常にウィンドウに収まる
// 標準サイズ・中央位置から始まる）。
var zoom = 1;
var panX = 0;
var panY = 0;
var dragging = false;
var dragStartX = 0, dragStartY = 0, panStartX = 0, panStartY = 0;

function render() {
    var img = document.getElementById('ref');
    if (!img.naturalWidth || !img.naturalHeight) return;
    var ww = document.documentElement.clientWidth;
    var wh = document.documentElement.clientHeight;
    var scale = Math.min(ww / img.naturalWidth, wh / img.naturalHeight) * zoom;
    var dw = Math.round(img.naturalWidth * scale);
    var dh = Math.round(img.naturalHeight * scale);
    img.style.width  = dw + 'px';
    img.style.height = dh + 'px';
    img.style.left = Math.round((ww - dw) / 2 + panX) + 'px';
    img.style.top  = Math.round((wh - dh) / 2 + panY) + 'px';
    img.style.display = 'block';
}
function setImage(path) {
    var img = document.getElementById('ref');
    img.style.display = 'none';
    zoom = 1;
    panX = 0;
    panY = 0;
    img.onload = render;
    img.src = path;
}
window.onresize = render;

function handleWheel(e) {
    e = e || window.event;
    var delta = 0;
    if (typeof e.deltaY !== 'undefined') delta = -e.deltaY;          // 標準の wheel イベント
    else if (typeof e.wheelDelta !== 'undefined') delta = e.wheelDelta; // 古い mousewheel イベント
    else if (typeof e.detail !== 'undefined') delta = -e.detail;
    if (delta > 0) zoom = zoom * 1.1;
    else if (delta < 0) zoom = zoom / 1.1;
    if (zoom < 0.1) zoom = 0.1;
    if (zoom > 10) zoom = 10;
    render();
    if (e.preventDefault) e.preventDefault();
    if (typeof e.returnValue !== 'undefined') e.returnValue = false;
    return false;
}
// 標準の"wheel"イベントに対応していない環境向けに、古い"mousewheel"にも
// 対応する。プロパティ代入(onwheel=)だけでは反応しない環境があったため、
// addEventListenerでも二重に登録して確実性を上げている。
if (document.addEventListener) {
    document.addEventListener('wheel', handleWheel, false);
    document.addEventListener('mousewheel', handleWheel, false);
} else if (document.attachEvent) {
    document.attachEvent('onmousewheel', handleWheel);
}
document.onwheel = handleWheel;
document.onmousewheel = handleWheel;

document.onmousedown = function(e) {
    e = e || window.event;
    dragging = true;
    dragStartX = e.clientX;
    dragStartY = e.clientY;
    panStartX = panX;
    panStartY = panY;
    return false;
};
document.onmousemove = function(e) {
    if (!dragging) return;
    e = e || window.event;
    panX = panStartX + (e.clientX - dragStartX);
    panY = panStartY + (e.clientY - dragStartY);
    render();
};
document.onmouseup = function(e) {
    dragging = false;
};
document.ondragstart = function() { return false; };
</script>
</head>
<body><img id="ref" alt=""></body>
</html>
    )"
    try FileDelete(fastCroquisHtmlPath)
    FileAppend(html, fastCroquisHtmlPath, "UTF-8")
}

CreateFastCroquisRefWindow(firstImagePath) {
    global fastRefGui, fastCroquisRefX, fastCroquisRefY, fastCroquisRefW, fastCroquisRefH
    global fastRefCurrentImage, fastRefWBCtrl, fastRefWB, fastCroquisHtmlPath, fastCroquisRefGeometryPath

    ; 【要望】前回このウィンドウを閉じた時点の位置・サイズが保存されていれば、
    ; それを優先して使う（無ければfastCroquisRefX/Y/W/Hの初期値のまま）。
    ; 保存内容は "x,y,w,h" のカンマ区切り1行。壊れている・値が異常な場合は
    ; 初期値にフォールバックする（起動不能になることを避けるため）。
    saved := Trim(SafeReadFile(fastCroquisRefGeometryPath))
    if (saved != "") {
        parts := StrSplit(saved, ",")
        if (parts.Length = 4) {
            try {
                sx := Integer(parts[1]), sy := Integer(parts[2])
                sw := Integer(parts[3]), sh := Integer(parts[4])
                if (sw >= 100 && sh >= 100) {
                    fastCroquisRefX := sx
                    fastCroquisRefY := sy
                    fastCroquisRefW := sw
                    fastCroquisRefH := sh
                }
            }
        }
    }

    fastRefGui := Gui("+AlwaysOnTop +Resize", "参照 - 右脳ドローイング")
    fastRefGui.MarginX := 0
    fastRefGui.MarginY := 0
    fastRefGui.BackColor := "000000"
    fastRefGui.OnEvent("Size", FastRefWindowResized)
    fastRefGui.Show("x" fastCroquisRefX " y" fastCroquisRefY " w" fastCroquisRefW " h" fastCroquisRefH)

    WriteFastCroquisHtml()

    fastRefWBCtrl := fastRefGui.Add("ActiveX", "x0 y0 w" fastCroquisRefW " h" fastCroquisRefH, "Shell.Explorer")
    fastRefWB := fastRefWBCtrl.Value
    fastRefWB.Navigate("file:///" StrReplace(fastCroquisHtmlPath, "\", "/"))

    ; ローカルファイルなので読み込みはほぼ瞬時だが、念のため完了を少し待つ
    loop 50 {
        if (fastRefWB.ReadyState = 4)
            break
        Sleep(20)
    }

    fastRefCurrentImage := ""
    ShowFastCroquisImage(firstImagePath)
}

ShowFastCroquisImage(path) {
    global fastRefCurrentImage, fastCroquisLastError, fastCroquisErrorLogPath
    if (path = "")
        return
    if (LoadFastCroquisImage(path))
        return

    ; この画像の表示に失敗した場合（読み込めない形式など）、
    ; 別の画像を選び直して最大3回までリトライする。各失敗はログファイルに
    ; 追記する（TrayTipはコピペできず一定時間で消えて確認しづらいため使わない）。
    loop 3 {
        LogFastCroquisError(fastRefCurrentImage, fastCroquisLastError)
        altPath := PickFastCroquisImage()
        if (altPath = "")
            break
        if (LoadFastCroquisImage(altPath))
            return
    }
    LogFastCroquisError(fastRefCurrentImage, fastCroquisLastError)
}

; 右脳ドローイングの画像表示エラーをログファイルに追記する（変更不要）。
; TrayTipはコピペできず一定時間で消えるため使わず、常に確認・コピペできる
; プレーンテキストファイルに記録する。
LogFastCroquisError(path, errMsg) {
    global fastCroquisErrorLogPath
    line := FormatTime(, "yyyy-MM-dd HH:mm:ss") " | " path " | " errMsg "`n"
    try FileAppend(line, fastCroquisErrorLogPath)
}

; ウィンドウリサイズ時はActiveXコントロール自体を新しいクライアントサイズに
; 合わせてMoveするだけでよい。埋め込みブラウザの内部windowにresizeイベントが
; 飛び、fast_croquis_ref.html側のwindow.onresize=fitImageが自動的に
; 再フィットしてくれるため、AHK側で拡大率などを計算し直す必要がない。
FastRefWindowResized(GuiObj, MinMax, Width, Height) {
    global fastRefWBCtrl
    if (MinMax = -1)   ; 最小化時は何もしない
        return
    try fastRefWBCtrl.Move(0, 0, Width, Height)
}

; 画像を新規に読み込む（画像切り替え時に呼ばれる）。
; HTML側のグローバル関数 setImage() をCOM経由で直接呼び出し、img要素の
; srcを書き換える。拡大縮小・中央寄せはHTML側のfitImage()が自動で行う。
; ローカルファイルの読み込みはほぼ瞬時なので、少し待ってから
; img.complete / naturalWidth を確認し、読み込みに失敗していないかを見る
; （壊れたファイルなどでは img.onerror 相当の状態になり naturalWidth が 0 のまま）。
; 戻り値: 表示に成功したら true、失敗したら false（呼び出し側でリトライに使う）
LoadFastCroquisImage(path) {
    global fastRefGui, fastRefWB, fastRefCurrentImage, fastCroquisLastError
    if (fastRefWB = "")
        return false

    ; 【要望】参照ウィンドウは常に最前面表示にする。作成時に+AlwaysOnTopを
    ; 指定しているだけでは、他のアプリの状態によってはトップモスト状態が
    ; 崩れることがあるため、画像切り替えのたびに念のため再宣言しておく
    ; （軽い処理であり、60秒〜のペースでしか呼ばれないため負荷は問題にならない）
    try WinSetAlwaysOnTop(true, fastRefGui)

    try {
        win := fastRefWB.Document.parentWindow
        fileUrl := "file:///" StrReplace(path, "\", "/")
        win.setImage(fileUrl)

        Sleep(60)
        img := fastRefWB.Document.getElementById("ref")
        if (!IsObject(img) || !img.naturalWidth) {
            fastCroquisLastError := "画像の読み込みに失敗しました（形式非対応または破損の可能性）"
            return false
        }

        fastRefCurrentImage := path
        return true
    } catch as e {
        fastCroquisLastError := e.Message " (" (e.HasProp("What") ? e.What : "") ")"
        return false
    }
}

DestroyFastCroquisRefWindow() {
    global fastRefGui, fastRefWBCtrl, fastRefWB, fastRefCurrentImage, fastCroquisRefGeometryPath

    ; 【要望】閉じる直前の位置・サイズを記憶しておき、次回起動時に復元する
    if (fastRefGui != "") {
        try {
            fastRefGui.GetPos(&gx, &gy, &gw, &gh)
            SafeWriteFile(fastCroquisRefGeometryPath, gx "," gy "," gw "," gh)
        }
    }

    try fastRefGui.Destroy()
    fastRefGui := ""
    fastRefWBCtrl := ""
    fastRefWB := ""
    fastRefCurrentImage := ""
}


; 手動停止シグナル（launcher.ahk トレイメニュー「🧪 テストモードを終了」）を確認する。
; 各ティック関数の先頭で呼び出し、シグナルファイルがあれば参照ウィンドウを閉じて
; 正常終了する（current_phase.txt は CleanupPhaseFile が空に戻してくれる）。
CheckFastCroquisStop() {
    global fastCroquisStopFlagPath
    if FileExist(fastCroquisStopFlagPath) {
        SafeDeleteFile(fastCroquisStopFlagPath)
        DestroyFastCroquisRefWindow()
        SoundPlay("*48")
        TrayTip("🧪 テストモード", "手動で終了しました", "Mute")
        ExitApp()
    }
}

; ===== 右脳ドローイング：メインフロー（モード6専用・変更不要）=====
; 60秒 × totalSets。fastCroquisCaptureEvery セットごとに撮影（croquisCaptureWait
; 秒待機）を挟み、それ以外のセットは撮影せず即座に次の画像へ切り替える。
RunFastCroquis(totalSets, lockSecs, preWaitSecs) {
    global g, timerGui, timerTitle, timerCount, timerSub, croquisArg

    g.totalSets    := totalSets
    g.lockSecs     := lockSecs
    g.breakSecs    := 0
    g.croquisTotal := totalSets
    g.croquisSet   := 1

    firstImg := PickFastCroquisImage()
    CreateFastCroquisRefWindow(firstImg)

    ; セット1開始前の待機（参照ウィンドウの位置・サイズ調整用）
    g.generation += 1
    myGen     := g.generation
    g.phase   := "break"
    g.endTick := A_TickCount + (preWaitSecs * 1000)
    WritePhase("break")

    timerGui.BackColor := "4A148C"
    timerTitle.Value   := "🧠 右脳ドローイング開始まで"
    timerSub.Value     := "参照ウィンドウの位置・サイズを調整してください"
    SoundPlay("*48")

    SetTimer(FastPreWaitTick, 300)

    FastPreWaitTick() {
        if (g.generation != myGen) {
            SetTimer(FastPreWaitTick, 0)
            return
        }
        CheckFastCroquisStop()
        if (g.isPaused)
            return

        rem := g.endTick - A_TickCount
        if (rem <= 0) {
            SetTimer(FastPreWaitTick, 0)
            StartFastCroquisSet(1, totalSets, lockSecs)
            return
        }
        s := Ceil(rem / 1000)
        timerCount.Value := Format("00:{:02d}", s)
    }
}

StartFastCroquisSet(setNum, totalSets, lockSecs) {
    global g, timerGui, timerTitle, timerCount, timerSub, croquisArg

    g.currentSet := setNum
    g.generation += 1
    myGen     := g.generation
    g.phase   := "lock"
    g.endTick := A_TickCount + (lockSecs * 1000)
    ; テスト実行中は current_phase.txt に "lock" ではなく "lock_test" を書き込み、
    ; launcher.ahk側のサボり監視・残業計測から除外する
    ; （g.phase 自体は内部処理のため "lock" のまま。無操作時の自動一時停止などは
    ;   通常どおり機能させる）
    WritePhase(croquisArg.isTest ? "lock_test" : "lock")

    timerGui.BackColor := "8B0000"
    timerTitle.Value   := "🧠 右脳ドローイング  -  " setNum "/" totalSets
    timerSub.Value     := croquisArg.isTest ? "テスト実行中" : "remaining time"
    SoundPlay("*48")

    SetTitleMatchMode(2)
    SetTimer(FastCroquisLockTick, 300)

    FastCroquisLockTick() {
        global fastCroquisCaptureEvery, croquisCaptureWait

        if (g.generation != myGen) {
            SetTimer(FastCroquisLockTick, 0)
            return
        }
        CheckFastCroquisStop()
        if (g.isPaused)
            return

        ; ブロック対象ウィンドウの最小化（通常ロックと同じ仕組み）
        for targetTitle in g.targetTitles {
            winList := WinGetList(targetTitle)
            for hwnd in winList {
                try WinMinimize("ahk_id " hwnd)
            }
        }

        remaining := g.endTick - A_TickCount
        if (remaining <= 0) {
            SetTimer(FastCroquisLockTick, 0)

            isCheckpoint := (Mod(setNum, fastCroquisCaptureEvery) = 0) || (setNum = totalSets)

            if (isCheckpoint) {
                StartFastCroquisCapture(setNum, totalSets, lockSecs)
            } else {
                nextImg := PickFastCroquisImage()
                ShowFastCroquisImage(nextImg)
                StartFastCroquisSet(setNum + 1, totalSets, lockSecs)
            }
            return
        }
        secs := Ceil(remaining / 1000)
        timerCount.Value := Format("00:{:02d}", secs)
    }
}

StartFastCroquisCapture(setNum, totalSets, lockSecs) {
    global g, timerGui, timerTitle, timerCount, timerSub, croquisCaptureWait

    ; 撮影処理・フェーズ切り替えが完全に終わるまでガードを維持する
    ; （通常クロッキーと同じ、無操作一時停止が固着するバグへの対策）
    g.inCaptureWait := true
    g.generation += 1
    myGen := g.generation

    FocusModeRestore()
    timerGui.BackColor := "4A148C"
    timerTitle.Value   := "🎨 まもなく撮影  -  " setNum "/" totalSets
    timerSub.Value     := "画面をズームアウトしてください"
    WritePhase("break")

    captureEnd := A_TickCount + (croquisCaptureWait * 1000)
    SetTimer(FastCaptureCountdownTick, 300)

    FastCaptureCountdownTick() {
        if (g.generation != myGen) {
            SetTimer(FastCaptureCountdownTick, 0)
            return
        }
        CheckFastCroquisStop()

        rem := captureEnd - A_TickCount
        if (rem <= 0) {
            SetTimer(FastCaptureCountdownTick, 0)

            CaptureCroquisResult()
            NextDnsUnblock()

            if (setNum < totalSets) {
                nextImg := PickFastCroquisImage()
                ShowFastCroquisImage(nextImg)
                StartFastCroquisSet(setNum + 1, totalSets, lockSecs)
            } else {
                DestroyFastCroquisRefWindow()
                StartCroquisBreak()
            }

            g.inCaptureWait := false
            return
        }
        s := Ceil(rem / 1000)
        timerCount.Value := Format("00:{:02d}", s)
    }
}

; ===== 右脳ドローイング：小規模練習モード（モード8専用）=====
; 参照ウィンドウ（HTML/ActiveX表示）を使う点はモード6テストと同じ仕組みを
; 流用するが、以下の点が異なるため専用のフローとして分けている：
;   ・croquisModeParamsに登録された本番モード（テストではない）。
;     ランダム抽選からは常に除外され、mode_scheduler.ahkでの明示指定か、
;     「本日のクロッキーをスキップ」時の代替としてのみ起動される
;   ・撮影（StartFastCroquisCapture・fastCroquisCaptureEveryごとの
;     チェックポイント）は行わない。毎セットの後に必ずinterSecs秒の
;     休憩＋次画像の位置調整時間を挟んでから次のセットに進む
;     （モード6テストは非チェックポイントのセットでは休憩無しで即座に
;     次のセットへ進む点が異なる）
;   ・使用画像は croquis_used.txt（他モードと共有）で管理される
;     （PickFastCroquisImage側でcroquisArg.isTestがfalseなので自動的に
;     こちらの分岐になる）
;   ・全セット終了後は通常のクロッキーと同じ StartCroquisBreak() に合流し、
;     croquis_done を書き込んで作業タイマーへ引き継ぐ（テストのように
;     単独で終了するのではなく、本番のクロッキーと同じ扱いになる）
RunFastCroquisPractice(totalSets, lockSecs, interSecs) {
    global g, timerGui, timerTitle, timerCount, timerSub

    g.totalSets    := totalSets
    g.lockSecs     := lockSecs
    g.breakSecs    := 0
    g.croquisTotal := totalSets
    g.croquisSet   := 1

    firstImg := PickFastCroquisImage()
    CreateFastCroquisRefWindow(firstImg)

    ; セット1開始前の待機（参照ウィンドウの位置・サイズ調整用。モード6テストと同じ挙動）
    g.generation += 1
    myGen     := g.generation
    g.phase   := "break"
    g.endTick := A_TickCount + (interSecs * 1000)
    WritePhase("break")

    timerGui.BackColor := "4A148C"
    timerTitle.Value   := "🧠 右脳ドローイング（軽め）開始まで"
    timerSub.Value     := "参照ウィンドウの位置・サイズを調整してください"
    SoundPlay("*48")

    SetTimer(FastPracticePreWaitTick, 300)

    FastPracticePreWaitTick() {
        if (g.generation != myGen) {
            SetTimer(FastPracticePreWaitTick, 0)
            return
        }
        CheckFastCroquisStop()
        if (g.isPaused)
            return

        rem := g.endTick - A_TickCount
        if (rem <= 0) {
            SetTimer(FastPracticePreWaitTick, 0)
            StartFastCroquisPracticeSet(1, totalSets, lockSecs, interSecs)
            return
        }
        s := Ceil(rem / 1000)
        timerCount.Value := Format("00:{:02d}", s)
    }
}

StartFastCroquisPracticeSet(setNum, totalSets, lockSecs, interSecs) {
    global g, timerGui, timerTitle, timerCount, timerSub, croquisCaptureWait

    g.currentSet := setNum
    g.generation += 1
    myGen     := g.generation
    g.phase   := "lock"
    g.endTick := A_TickCount + (lockSecs * 1000)
    WritePhase("lock")

    timerGui.BackColor := "8B0000"
    timerTitle.Value   := "🧠 右脳ドローイング（軽め）  -  " setNum "/" totalSets
    timerSub.Value     := "remaining time"
    SoundPlay("*48")

    SetTitleMatchMode(2)
    SetTimer(FastCroquisPracticeLockTick, 300)

    FastCroquisPracticeLockTick() {
        if (g.generation != myGen) {
            SetTimer(FastCroquisPracticeLockTick, 0)
            return
        }
        CheckFastCroquisStop()
        if (g.isPaused)
            return

        ; ブロック対象ウィンドウの最小化（通常ロックと同じ仕組み）
        for targetTitle in g.targetTitles {
            winList := WinGetList(targetTitle)
            for hwnd in winList {
                try WinMinimize("ahk_id " hwnd)
            }
        }

        remaining := g.endTick - A_TickCount
        if (remaining <= 0) {
            SetTimer(FastCroquisPracticeLockTick, 0)

            if (setNum >= totalSets) {
                ; 【要望】全セット終了後も、通常のクロッキーと同じ撮影処理
                ; （croquisCaptureWait秒待機→CaptureCroquisResult()でCLIPStudio
                ; のウィンドウをスクリーンショット保存）を行う。Discordへの
                ; 報告に使うため、軽量モードだからといって省略しない。
                FocusModeRestore()
                DestroyFastCroquisRefWindow()   ; 撮影の邪魔にならないよう先に閉じる
                g.inCaptureWait := true   ; 撮影待機中は無操作検知の一時停止対象から除外する

                timerTitle.Value := "🎨 まもなく撮影"
                timerSub.Value   := "画面をズームアウトしてください"
                SoundPlay("*48")
                TrayTip("🧠 右脳ドローイング（軽め）終了", croquisCaptureWait " 秒後に撮影します", "Mute")

                captureEnd := A_TickCount + (croquisCaptureWait * 1000)
                SetTimer(FastCroquisPracticeCaptureCountdownTick, 300)

                FastCroquisPracticeCaptureCountdownTick() {
                    rem := captureEnd - A_TickCount
                    if (rem <= 0) {
                        SetTimer(FastCroquisPracticeCaptureCountdownTick, 0)
                        CaptureCroquisResult()
                        NextDnsUnblock()
                        StartCroquisBreak()
                        g.inCaptureWait := false
                        return
                    }
                    s := Ceil(rem / 1000)
                    timerCount.Value := Format("00:{:02d}", s)
                }
                return
            }

            ; 次の画像に切り替えてから、休憩＋位置調整時間を挟んで次セットへ
            nextImg := PickFastCroquisImage()
            ShowFastCroquisImage(nextImg)
            StartFastCroquisPracticeBreak(setNum + 1, totalSets, lockSecs, interSecs)
            return
        }
        secs := Ceil(remaining / 1000)
        timerCount.Value := Format("00:{:02d}", secs)
    }
}

; セットとセットの間に必ず挟まる休憩＋次画像の位置調整時間（interSecs秒）。
; モード6テストの「チェックポイントのみ休憩」とは異なり、モード8は毎セット後に必ず挟む。
StartFastCroquisPracticeBreak(nextSetNum, totalSets, lockSecs, interSecs) {
    global g, timerGui, timerTitle, timerCount, timerSub

    g.generation += 1
    myGen     := g.generation
    g.phase   := "break"
    g.endTick := A_TickCount + (interSecs * 1000)
    WritePhase("break")

    timerGui.BackColor := "4A148C"
    timerTitle.Value   := "🧠 右脳ドローイング（軽め）休憩・調整"
    timerSub.Value     := "次は " nextSetNum "/" totalSets " です"
    SoundPlay("*48")

    SetTimer(FastCroquisPracticeBreakTick, 300)

    FastCroquisPracticeBreakTick() {
        if (g.generation != myGen) {
            SetTimer(FastCroquisPracticeBreakTick, 0)
            return
        }
        CheckFastCroquisStop()
        if (g.isPaused)
            return

        rem := g.endTick - A_TickCount
        if (rem <= 0) {
            SetTimer(FastCroquisPracticeBreakTick, 0)
            StartFastCroquisPracticeSet(nextSetNum, totalSets, lockSecs, interSecs)
            return
        }
        s := Ceil(rem / 1000)
        timerCount.Value := Format("00:{:02d}", s)
    }
}

; ===== クロッキー後休憩（変更不要）=====
StartCroquisBreak() {
    global g, timerGui, timerTitle, timerCount, timerSub, croquisBreakSecs, croquisArg

    g.phase   := "break"
    g.endTick := A_TickCount + (croquisBreakSecs * 1000)
    g.generation += 1
    myGen := g.generation

    WritePhase("break")

    timerGui.BackColor := "1A6B3C"   ; 緑：休憩色
    timerTitle.Value   := "☕ クロッキー休憩"
    timerSub.Value     := "お疲れ様でした"
    SoundPlay("*48")
    TrayTip("☕ 休憩", croquisBreakSecs // 60 " 分間の休憩です", "Mute")

    SetTimer(CroquisBreakTick, 300)

    CroquisBreakTick() {
        if (g.generation != myGen) {
            SetTimer(CroquisBreakTick, 0)
            return
        }
        if (g.isPaused)   ; 食事休憩・運動中は休憩タイマーを止める
            return

        rem := g.endTick - A_TickCount
        if (rem <= 0) {
            SetTimer(CroquisBreakTick, 0)

            ; 右脳ドローイングのテスト実行はあくまでテストなので、
            ; croquis_done は書かず、作業タイマーへの引き継ぎも行わない。
            ; 単独で完結して終了する（current_phase.txt は CleanupPhaseFile が
            ; 空に戻してくれる）。
            if (croquisArg.isTest) {
                SoundPlay("*48")
                TrayTip("🧪 テスト終了", "右脳ドローイングのテスト実行が終了しました", "Mute")
                ExitApp()
                return
            }

            WritePhase("croquis_done")
            SoundPlay("*48")
            TrayTip("🎨 クロッキー完了", "作業タイマーを開始します", "Mute")
            Sleep(8000)   ; launcher が5秒ごとに監視しているため余裕を持って待つ
            ExitApp()
            return
        }
        secs := Ceil(rem / 1000)
        mins := secs // 60
        secs := Mod(secs, 60)
        timerCount.Value := Format("{:02d}:{:02d}", mins, secs)
    }
}

; ===== ポモドーロ本体（変更不要）=====
RunPomodoro(targetTitles, lockSecs, breakSecs, totalSets, startSet := 1) {
    global g, timerGui, timerTitle, timerCount, timerSub

    g.targetTitles := targetTitles
    g.totalSets    := totalSets
    g.lockSecs     := lockSecs
    g.breakSecs    := breakSecs
    g.generation   += 1          ; 世代を進める（古いタイマーを無効化）
    myGen          := g.generation

    RunSet(currentSet) {

        if (currentSet > g.totalSets) {
            EnterIntermission()
            return
        }

        g.currentSet      := currentSet
        g.phase           := "lock"
        g.lastActiveCheck := 0   ; 作業時間計測をリセット
        g.endTick    := A_TickCount + (lockSecs * 1000)
        g.isPaused   := false
        g.idlePaused := false
        ; WritePhase("lock") をインライン展開（ネスト関数からの呼び出し保険）
        _phasePath := A_ScriptDir "\current_phase.txt"
        try FileDelete(_phasePath)
        FileAppend("lock", _phasePath)
        NextDnsBlock()   ; スマホのSNSをブロック

        ; 自動集中モード判定
        ; ・前セットが自動発動だった場合 → いったんリセットして再抽選
        ; ・前セットが手動発動だった場合 → リセットせず引き継ぎ（抽選もスキップ）
        ; ・自動抽選は「現在OFFであること」に加えて「直前セットが集中モードでなかったこと」も条件にする
        ;   （集中モードだったセットの直後のセットで連続して自動発動しないようにするため。
        ;    休憩中にボタンでON/OFFを切り替えたかどうかに関わらず、直前セットのロック中の
        ;    実際の状態＝g.lastSetHadFocusMode で判定する）
        if (g.focusModeIsAuto) {
            g.focusMode     := false
            g.focusModeIsAuto := false
        }
        if (!g.focusMode && !g.lastSetHadFocusMode && currentSet >= focusModeAutoFromSet) {
            if (Random(1, 100) <= focusModeAutoChance) {
                g.focusMode       := true
                g.focusModeIsAuto := true
                TrayTip("🎯 集中モード自動発動", "Set " currentSet " - 10秒後にウィンドウを最小化します", "Mute")
            }
        }

        timerGui.BackColor := "CC3333"
        timerTitle.SetFont("cWhite")
        timerCount.SetFont("cWhite")
        timerSub.SetFont("cWhite")
        timerTitle.Value := "🔒 Lock  -  Set " currentSet "/" g.totalSets
        timerSub.Value   := g.focusMode ? "remaining time  🎯" : "remaining time"
        SoundPlay("*48")
        TrayTip("Lock [Set " currentSet "/" g.totalSets "]", lockSecs // 60 " min lock started", "Mute")
        UpdateFocusBtnState()

        ; 集中モードが引き継がれていた場合、直ちに適用
        if (g.focusMode)
            FocusModeMinimizeWithCountdown()

        SetTitleMatchMode(2)
        SetTimer(LockWindow, 300)

        LockWindow() {
            if (g.generation != myGen) {
                SetTimer(LockWindow, 0)
                return
            }
            if (g.isPaused)
                return

            remaining := g.endTick - A_TickCount

            if (remaining <= 0) {
                SetTimer(LockWindow, 0)
                ; 作業中ウィンドウがアクティブなら休憩を延期
                if (IsWorkWindow()) {
                    g.breakPending := true
                    ; 青い画面を見せると集中が途切れるため、GUIを静かに最小化して待つ
                    ; ユーザーが自然に別ウィンドウに切り替えたタイミングで休憩を開始する
                    timerGui.Minimize()
                    SetTimer(WaitForBreak, 500)
                } else {
                    DoStartBreak()
                }
                return
            }

            secs := Ceil(remaining / 1000)
            mins := secs // 60
            secs := Mod(secs, 60)
            timerCount.Value := Format("{:02d}:{:02d}", mins, secs)

            if (g.focusCountingDown)
                return

            for targetTitle in g.targetTitles {
                winList := WinGetList(targetTitle)
                for hwnd in winList {
                    try {
                        state := WinGetMinMax("ahk_id " hwnd)
                        if (state != -1)
                            WinMinimize("ahk_id " hwnd)
                    }
                }
            }

            if (g.focusMode)
                FocusModeMinimize()
        }

        ; WaitForBreak・DoStartBreak・BreakTimer は LockWindow と同階層に置く
        ; （ネスト関数から sibling 関数を SetTimer できないため）
        WaitForBreak() {
            if (g.generation != myGen || !g.breakPending) {
                SetTimer(WaitForBreak, 0)
                g.breakDeferSince := 0
                return
            }
            if (IsWorkWindow()) {
                ; 作業ウィンドウに戻ったのでカウントをリセット
                g.breakDeferSince := 0
            } else {
                ; 作業ウィンドウ外になった
                if (g.breakDeferSince = 0)
                    g.breakDeferSince := A_TickCount   ; 離脱開始時刻を記録
                elapsed := (A_TickCount - g.breakDeferSince) / 1000
                if (elapsed >= breakDeferGraceSecs) {
                    ; 猶予時間を超えて作業外が続いた → 休憩開始
                    SetTimer(WaitForBreak, 0)
                    g.breakDeferSince := 0
                    DoStartBreak()
                }
                ; 猶予内はまだ待つ
            }
        }

        DoStartBreak() {
            g.breakPending := false
            g.phase        := "break"
            g.endTick      := A_TickCount + (breakSecs * 1000)
            WritePhase("break")
            NextDnsUnblock()

            ; このセットのロック中に集中モードだったかを記録しておく
            ; （次セットの自動抽選条件「直前セットが集中モードでなかったこと」に使う。
            ;   休憩中にボタンで on/off を切り替えても、ここで記録した値は変わらない）
            g.lastSetHadFocusMode := g.focusMode


            ; 最小化されていた場合は復元してから休憩表示へ
            timerGui.Show("NoActivate")
            timerGui.BackColor := "2E7D32"
            timerTitle.SetFont("cWhite")
            timerCount.SetFont("cWhite")
            timerSub.SetFont("cWhite")
            timerTitle.Value := "☕ Break  -  Set " currentSet "/" g.totalSets
            timerSub.Value   := g.focusMode ? "enjoy your break!  🎯 ON" : "enjoy your break!"
            SoundPlay("*48")
            TrayTip("Break! [Set " currentSet "/" g.totalSets "]", breakSecs // 60 " min break - enjoy!", "Mute")
            UpdateFocusBtnState()
            FocusModeRestore()
            SetTimer(BreakTimer, 300)
        }

        BreakTimer() {
            if (g.generation != myGen) {
                SetTimer(BreakTimer, 0)
                return
            }
            if (g.isPaused)
                return

            remaining := g.endTick - A_TickCount
            if (remaining <= 0) {
                SetTimer(BreakTimer, 0)
                RunSet(currentSet + 1)
                return
            }

            secs := Ceil(remaining / 1000)
            mins := secs // 60
            secs := Mod(secs, 60)
            timerCount.Value := Format("{:02d}:{:02d}", mins, secs)
        }
    }

    RunSet(startSet)
}
