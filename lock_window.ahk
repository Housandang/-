#Requires AutoHotkey v2.0
#SingleInstance Force   ; 既存のインスタンスを確認なしで自動終了・上書き

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
    try FileDelete(_path)
    if (phase != "")
        FileAppend(phase, _path)
}

OnExit(CleanupPhaseFile)
CleanupPhaseFile(reason, code) {
    ; g がまだ初期化されていない段階での終了に備えてフォールバック
    currentPhase := ""
    try currentPhase := g.phase

    ; フェーズファイルの実際の内容を読む
    ; （g.phase が "break" のままでも WritePhase("croquis_done") 済みの場合があるため）
    actualPhase := ""
    try actualPhase := Trim(FileRead(A_ScriptDir "\current_phase.txt"))

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
croquisCaptureWait := 10     ; タイマー終了からスクショ撮影までの猶予（秒）
croquisBreakSecs   := 300    ; クロッキー後の休憩時間（秒）

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
    "ホウ酸's"
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
focusModeAutoChance  := 50

; ================================================================
; ★ 作業達成時間の設定
;
;    totalWorkGoalMinutes
;      → この時間（分）だけ作業ウィンドウがアクティブになると
;        「作業達成」とみなし、スクリプト停止が許可されます。
;        0 にすると機能を無効化します。
;
;    作業ウィンドウの指定は workWindowTitles / workWindowProcesses を使います。
;    ロック中のみ計測します（休憩・食事中は計測しません）。
; ================================================================
totalWorkGoalMinutes := 150   ; 2時間半

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
    activeWorkMs:         0,      ; 作業ウィンドウがアクティブだった累計時間（ms）
    workGoalReached:      false,  ; 作業達成フラグ
    lastActiveCheck:      0,      ; 前回の作業時間チェックのTickCount
    focusMode:            false,  ; 集中モード中かどうか
    focusModeIsAuto:      false,  ; true=自動発動 / false=手動発動
    intermissionEnd:      0,      ; 中休みモード終了のTickCount
    focusCountdownEnd:    0,      ; 集中モード猶予カウントダウン用
    focusCountingDown:    false,  ; カウントダウン中はブロックを一時停止
    focusMinimizedHwnds:  [],     ; 集中モードで最小化したウィンドウのHWND一覧（復元用）
    gameLimitReached:     false,  ; ゲーム制限に達したか
    gameExtendSetsLeft:   0,      ; 延長に必要な残りセット数
    gameExtendUsed:       false,  ; 本日の延長を使用済みか
    croquisSet:           1,      ; クロッキー現在セット番号
    croquisTotal:         1,      ; クロッキー総セット数
    croquisInter:         0       ; クロッキーセット間休憩（秒）
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
; ================================================================
timerGui.SetFont("s11", "Segoe UI")
global exerciseBtn := timerGui.Add("Button", "x5 w70 y+10", "🚴")
exerciseBtn.OnEvent("Click", OnExerciseStart)
if (exerciseUsedToday)
    exerciseBtn.Enabled := false

global addSetBtn := timerGui.Add("Button", "x+3 w70 yp", "➕")
addSetBtn.OnEvent("Click", OnAddSet)

global lunchBtn := timerGui.Add("Button", "x+3 w70 yp", "🥗")
lunchBtn.OnEvent("Click", OnLunchBreak)
if (lunchUsedToday)
    lunchBtn.Enabled := false

global focusBtn := timerGui.Add("Button", "x+3 w70 yp", "🎯")
focusBtn.OnEvent("Click", OnFocusMode)
focusBtn.Enabled := false   ; タイマー未起動中は無効

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
    global g, totalWorkGoalMinutes

    if (totalWorkGoalMinutes = 0)
        return

    if (g.workGoalReached) {
        A_IconTip := "🎯 本日の作業ノルマ達成済み"
        return
    }

    remainMin := Ceil(Max(0, totalWorkGoalMinutes * 60000 - g.activeWorkMs) / 60000)
    h := remainMin // 60
    m := Mod(remainMin, 60)
    label := (h > 0) ? h "時間" m "分" : m "分"
    A_IconTip := "🎯 ノルマまであと " label
}
UpdateWorkGoalTip()   ; 起動直後にも初期値を表示しておく

; ===== 作業時間計測：5秒ごとに監視（変更不要）=====
SetTimer(CheckActiveWork, 5000)

CheckActiveWork() {
    global g, totalWorkGoalMinutes

    ; ロックフェーズ・中休み中・一時停止していないときのみ計測
    ; （中休み中も計測対象に含めないと「中休み中に達成した場合も即座に表示」が機能しないため）
    if ((g.phase != "lock" && g.phase != "intermission") || g.isPaused || totalWorkGoalMinutes = 0)
        return

    ; 作業ウィンドウがアクティブか確認
    if (!IsWorkWindow())
        return

    ; 前回チェックからの経過時間を加算
    now := A_TickCount
    if (g.lastActiveCheck > 0)
        g.activeWorkMs += (now - g.lastActiveCheck)
    g.lastActiveCheck := now

    ; 達成チェック
    if (!g.workGoalReached && g.activeWorkMs >= totalWorkGoalMinutes * 60000) {
        g.workGoalReached := true
        SoundPlay("*48")
        TrayTip("🎉 作業達成！", totalWorkGoalMinutes " 分の作業時間を達成しました。`n休憩中のスクリプト停止が許可されます。", "Mute")
        ; 中休み中に達成した場合は即座にボタンを表示
        if (g.phase = "intermission")
            workDoneBtn.Visible := true
    }

    UpdateWorkGoalTip()
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
    global g, timerGui, timerTitle, timerCount, timerSub, mealEndBtn, isCroquis
    global mealPauseStartH, mealPauseStartM, mealPauseEndH, mealPauseEndM

    if (g.phase = "")
        return

    ; クロッキー中は食事休憩による割り込みを行わない。
    ; （タイマー終了間際に食事休憩が割り込むと g.isPaused が true のままになり、
    ;   撮影フェーズへ移行できなくなる問題があったため。クロッキーは短時間なので
    ;   食事時間帯に多少かかっても中断せず最後まで進行させる）
    if (isCroquis)
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

        g.isPaused          := true
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
    g.lastActiveCheck := 0   ; 食事休憩中の経過時間が作業時間に加算されないようリセット
    g.endTick         := A_TickCount + g.pausedRemainingMs

    timerCount.Visible := true
    mealEndBtn.Visible  := false

    WritePhase(g.phase)   ; サボり検知を元のフェーズに戻す

    if (g.phase = "lock") {
        timerGui.BackColor := "CC3333"
        timerTitle.Value   := "🔒 Lock  -  Set " g.currentSet "/" g.totalSets
        timerSub.Value     := "remaining time"
    } else {
        timerGui.BackColor := "2E7D32"
        timerTitle.Value   := "☕ Break  -  Set " g.currentSet "/" g.totalSets
        timerSub.Value     := "enjoy your break!"
    }
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
global croquisArg := {lockSecs: 1500, sets: 1, interSecs: 0}   ; デフォルトはモード1

for arg in A_Args {
    if (arg = "/auto")
        isAuto := true
    if (SubStr(arg, 1, 8) = "/croquis") {
        isCroquis := true
        ; /croquis:lockSecs:sets:interSecs の形式で受け取る
        parts := StrSplit(arg, ":")
        if (parts.Length >= 4) {
            croquisArg.lockSecs  := Integer(parts[2])
            croquisArg.sets      := Integer(parts[3])
            croquisArg.interSecs := Integer(parts[4])
        }
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

    g.focusMode       := true
    g.focusModeIsAuto := false

    timerGui.Show("NoActivate")
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
    global croquisShotDir   ; croquisFolder パスを共有するために設定変数が必要
    ; lock_window.ahk には croquisFolder がないため、croquis_used.txt と同じ場所から推測
    usedLogPath := A_ScriptDir "\croquis_used.txt"
    folder      := A_ScriptDir "\croquis_models"   ; デフォルトパス

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

    if (unused.Length = 0) {
        try FileDelete(usedLogPath)
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

    StartNextCroquisSet()
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
                    CaptureCroquisResult()
                    NextDnsUnblock()

                    if (setNum < totalSets) {
                        StartCroquisInterSet(setNum, totalSets, lockSecs, interSecs)
                    } else {
                        StartCroquisBreak()
                    }
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
    global g, timerGui, timerTitle, timerCount, timerSub

    ; 次の画像をコピー（launcher 側の PickCroquisImage は使えないので
    ; current_phase.txt 経由で launcher に要求する方式ではなく、
    ; lock_window 側でファイルを直接選ぶ）
    nextImg := PickNextCroquisImage()
    if (nextImg != "") {
        CopyNextCroquisImage(nextImg)
        TrayTip("🎨 次のモデル", "クリップボードにコピーしました。サブビューに貼り付けてください", "Mute")
    }

    g.generation += 1
    myGen        := g.generation
    g.phase      := "break"
    g.endTick    := A_TickCount + (interSecs * 1000)
    WritePhase("break")

    nextSet := doneSet + 1
    timerGui.BackColor := "4A148C"   ; 薄紫：セット間
    timerTitle.Value   := "🎨 次のセットまで " nextSet "/" totalSets
    timerSub.Value     := "次のモデルをサブビューへ"
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

; ===== クロッキー後休憩（変更不要）=====
StartCroquisBreak() {
    global g, timerGui, timerTitle, timerCount, timerSub, croquisBreakSecs

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
        ; WritePhase("lock") をインライン展開（ネスト関数からの呼び出し保険）
        _phasePath := A_ScriptDir "\current_phase.txt"
        try FileDelete(_phasePath)
        FileAppend("lock", _phasePath)
        NextDnsBlock()   ; スマホのSNSをブロック

        ; 自動集中モード判定
        ; ・前セットが自動発動だった場合 → いったんリセットして再抽選
        ; ・前セットが手動発動だった場合 → リセットせず引き継ぎ（抽選もスキップ）
        if (g.focusModeIsAuto) {
            g.focusMode     := false
            g.focusModeIsAuto := false
        }
        if (!g.focusMode && currentSet >= focusModeAutoFromSet) {
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
