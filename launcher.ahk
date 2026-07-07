#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; ================================================================
; ★ スリープ復帰から何分後に自動起動するか
; ================================================================
delayMinutes := 30

; ================================================================
; ★ スリープ時間がこの値（時間）以上の場合のみ起動
;    例: 6 なら、6時間以上スリープしていた場合のみ起動（就寝明け判定）
; ================================================================
minSleepHours := 6

; ================================================================
; ★ 自動起動をスキップする曜日
;    A_WDay の値: 1=日, 2=月, 3=火, 4=水, 5=木, 6=金, 7=土
;    例: [7] なら土曜スキップ / [1, 7] なら土日スキップ
; ================================================================
skipWDays := [7]

; ================================================================
; ★ lock_window.ahk のパス
;    このファイルと同じフォルダに置いている場合は変更不要です。
; ================================================================
scriptPath   := A_ScriptDir "\lock_window.ahk"
sleepLogPath := A_ScriptDir "\last_sleep.txt"

; ================================================================
; ★ 食事休憩の時間設定（lock_window.ahk と合わせてください）
;    この時間帯にカウントダウンが終了した場合、クロッキーは
;    食事休憩終了後まで自動的に待機します。
; ================================================================
mealPauseStartH := 19
mealPauseStartM := 0
mealPauseEndH   := 20
mealPauseEndM   := 30

; ================================================================
; ★ クロッキー設定
;
;    croquisMode
;      → 使用するモードを番号で指定してください
;
;        1 … 25分 × 1枚（デフォルト）
;        2 … 15分 × 2枚（セット間に2分休憩）
;        3 …  5分 × 5枚（セット間に1分休憩）
;
;    croquisFolder
;      → モデル画像が入ったフォルダのパス
;
;    croquisDelayMinutes
;      → スリープ復帰後、クロッキー開始までの待機時間（分）
;
;    croquisUsedLog / croquisShotDir
;      → 変更不要
; ================================================================
croquisMode := 2
croquisFolder       := A_ScriptDir "\croquis_models"
croquisDelayMinutes := 5
croquisUsedLog      := A_ScriptDir "\croquis_used.txt"
croquisShotDir      := A_ScriptDir "\croquis_shots"   ; lock_window.ahk と合わせること

; モード別パラメータ（変更不要）
croquisModeParams := Map(
    1, {lockSecs: 1500, sets: 1, interSecs:   0},
    2, {lockSecs:  900, sets: 2, interSecs: 120},
    3, {lockSecs:  300, sets: 5, interSecs:  60}
)

; ================================================================
; ★ クロッキー週次レポート設定
;
;    croquisReportWebhook
;      → 送信先の Discord Webhook URL
;        サボり通知とは別のチャンネルに送りたい場合は別のURLを設定
;        同じでよければ下の discordWebhook と同じURLを入れてください
;
;    croquisReportWDay
;      → 送信する曜日（A_WDay: 1=日, 2=月, 3=火, 4=水, 5=木, 6=金, 7=土）
;        土曜 = 7
;
;    croquisReportHour
;      → 送信する時刻（時・24時間表記）
; ================================================================
croquisReportWebhook := "https://discord.com/api/webhooks/1514960540949282948/QWx9sLWEDVBct8MUXU5EvsgiGKcY5C3BRriVil5Ye_yM2hvCKJPfFdI-MryZNVmhDXBS?thread_id=1514960461815353394"
croquisReportWDay    := 7    ; 土曜
croquisReportHour    := 15   ; 15時

; ================================================================
; ★ 就寝時スマホブロックの設定
;
;    nightBlockDelay     … スリープ開始から何分後にブロックするか
;    nightBlockHourStart … 発動対象の開始時刻（この時刻以降）
;    nightBlockHourEnd   … 発動対象の終了時刻（この時刻まで）
;
;    nextdns 系の値は lock_window.ahk と合わせてください。
; ================================================================
nightBlockDelay     := 30
nightBlockHourStart := 23
nightBlockHourEnd   := 9

nightdnsApiKey   := "10fe27590862f3c7d0e62ca47fe93ec40bbd0b78"
nightdnsProfile  := "5f2c95"

nightdnsCategories := [
    "social-networks",
    "video-streaming",
    "gaming",
]
nightdnsServices := [
    "youtube",
    "twitter",
    "instagram",
    "tiktok",
    "facebook",
    "snapchat",
    "reddit",
    "twitch",
    "steam",
    "discord",
]
nightdnsBlockList := [
    ; ↓ lock_window.ahk の nextdnsBlockList と合わせて追記
]

; 就寝ブロックが実行されたことを示すフラグファイル（変更不要）
nightBlockFlagPath := A_ScriptDir "\night_block_flag.txt"

; ===== トレイアイコン設定（変更不要）=====
; スリープ復帰後、タスクバーのこのアイコンにマウスを乗せると
; 「作業開始まで XX:XX」という残り時間が常に表示されます。
A_IconTip := "Work Launcher - 待機中"

; ===== 就寝モード状態（変更不要）=====
nightModeActive  := false
nightModeEndTick := 0

; ===== カウントダウンGUI（変更不要）=====
; ※ GUIはモニター環境によって表示されない場合があります。
;    トレイアイコンのツールチップが確実な確認方法です。
cdGui := Gui("+AlwaysOnTop +ToolWindow", "Work Mode")
cdGui.SetFont("s9", "Segoe UI")
cdGui.BackColor := "1A1A2E"

cdLabel := cdGui.Add("Text", "x10 y10 w140 cWhite", "作業開始まで...")
cdGui.SetFont("s26 bold", "Segoe UI")
cdCount := cdGui.Add("Text", "x10 y28 w140 cWhite", "00:00")
cdGui.SetFont("s8", "Segoe UI")
cdSkipBtn := cdGui.Add("Button", "x158 y10 w72 h70", "今すぐ`n開始")
cdSkipBtn.OnEvent("Click", (*) => SkipCountdown())
cdGui.Show("Center w240 h120 NoActivate Hide")

; ===== スリープ復帰の検知（変更不要）=====
WM_POWERBROADCAST      := 0x0218
PBT_APMSUSPEND         := 0x4
PBT_APMRESUMEAUTOMATIC := 0x12

; ===== トレイメニュー（変更不要）=====
trayMenu := A_TrayMenu
trayMenu.Add()
trayMenu.Add("🌙 就寝モード開始 (" nightBlockDelay " 分後にスマホをブロック)", OnNightModeStart)
trayMenu.Add("🌙 就寝モードをキャンセル", OnNightModeCancel)

; トレイアイコンのダブルクリックでカウントダウンGUIを最前面に戻す
OnMessage(0x404, OnTrayDblClick)
OnTrayDblClick(wParam, lParam, msg, hwnd) {
    if (lParam = 0x203) {   ; WM_LBUTTONDBLCLK
        try {
            cdGui.Opt("+AlwaysOnTop")
            cdGui.Show("NoActivate")
        }
    }
}

OnNightModeStart(*) {
    global nightModeActive, nightModeEndTick, nightBlockDelay
    if nightModeActive {
        MsgBox("就寝モードはすでに起動中です。")
        return
    }
    nightModeActive  := true
    nightModeEndTick := A_TickCount + (nightBlockDelay * 60 * 1000)
    A_IconTip        := "就寝モード：スマホブロックまで " nightBlockDelay " 分"
    TrayTip("🌙 就寝モード開始", nightBlockDelay " 分後にスマホをブロックします", "Mute")
    SetTimer(NightModeCountdown, 1000)
    ; 3秒後にモニターの電源をオフにする（GPUへの影響なし・マウス操作で復帰）
    SetTimer(TurnOffMonitors, -10000)   ; 通知が消えてから10秒後に消灯
}

TurnOffMonitors() {
    SendMessage(0x0112, 0xF170, 2, , "Program Manager")
}

OnNightModeCancel(*) {
    global nightModeActive
    if !nightModeActive {
        MsgBox("就寝モードは起動していません。")
        return
    }
    nightModeActive := false
    SetTimer(NightModeCountdown, 0)
    A_IconTip := "Work Launcher - 待機中"
    TrayTip("就寝モードキャンセル", "スマホブロックをキャンセルしました", "Mute")
}

NightModeCountdown() {
    global nightModeActive, nightModeEndTick
    if !nightModeActive {
        SetTimer(NightModeCountdown, 0)
        return
    }
    remaining := nightModeEndTick - A_TickCount
    if remaining <= 0 {
        SetTimer(NightModeCountdown, 0)
        nightModeActive := false
        A_IconTip := "Work Launcher - 待機中"
        ; スマホブロックを実行
        NightBlock()
        return
    }
    mins := Ceil(remaining / 60000)
    A_IconTip := "就寝モード：スマホブロックまで " mins " 分"
}

NightBlock() {
    global nightdnsApiKey, nightdnsProfile, nightBlockFlagPath
    global nightdnsCategories, nightdnsServices, nightdnsBlockList

    psPath := A_Temp "\ndns_night_block_now.ps1"
    try FileDelete(psPath)

    q  := Chr(34)
    ps := "$headers = @{ " q "X-Api-Key" q " = " q nightdnsApiKey q " }" . "`n"
    for cat in nightdnsCategories {
        body := "{" q "id" q ":" q cat q "," q "active" q ":true}"
        ps .= "$body = '" body "'; try { Invoke-WebRequest -Uri " q "https://api.nextdns.io/profiles/" nightdnsProfile "/parentalcontrol/categories" q " -Method POST -Headers $headers -Body $body -ContentType " q "application/json" q " -UseBasicParsing | Out-Null } catch { }`n"
    }
    for svc in nightdnsServices {
        body := "{" q "id" q ":" q svc q "," q "active" q ":true}"
        ps .= "$body = '" body "'; try { Invoke-WebRequest -Uri " q "https://api.nextdns.io/profiles/" nightdnsProfile "/parentalcontrol/services" q " -Method POST -Headers $headers -Body $body -ContentType " q "application/json" q " -UseBasicParsing | Out-Null } catch { }`n"
    }
    for domain in nightdnsBlockList {
        body := "{" q "id" q ":" q domain q "," q "active" q ":true}"
        ps .= "$body = '" body "'; try { Invoke-WebRequest -Uri " q "https://api.nextdns.io/profiles/" nightdnsProfile "/denylist" q " -Method POST -Headers $headers -Body $body -ContentType " q "application/json" q " -UseBasicParsing | Out-Null } catch { }`n"
    }
    ps .= "New-Item -Path " q nightBlockFlagPath q " -ItemType File -Force | Out-Null`n"

    FileAppend(ps, psPath, "UTF-8-RAW")
    Run('powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File "' psPath '"', , "Hide")
    ; API呼び出しが完了するまで少し待ってからスリープ
    ; （通知は出さない：モニターが復帰してしまうため）
    SetTimer(SleepPC, -8000)
}

SleepPC() {
    DllCall("PowrProf\SetSuspendState", "Int", 0, "Int", 1, "Int", 0)
}

OnMessage(WM_POWERBROADCAST, OnPower)
countdownEnd  := 0
showAttempts  := 0
countdownMode := ""   ; "croquis" or "main"

OnPower(wParam, lParam, msg, hwnd) {
    global countdownEnd, showAttempts, sleepLogPath, minSleepHours, delayMinutes, skipWDays

    ; スリープ開始時刻を保存
    ; ただし直前の記録から30分未満の場合は上書きしない（短時間スリープ対策）
    if (wParam = PBT_APMSUSPEND) {
        A_IconTip := "Work Launcher - 待機中"
        shouldWrite := true
        try {
            lastSleep := Trim(FileRead(sleepLogPath))
            minutesSinceLastSleep := DateDiff(A_Now, lastSleep, "Minutes")
            if (minutesSinceLastSleep < 30)
                shouldWrite := false
        }
        if (shouldWrite) {
            try FileDelete(sleepLogPath)
            FileAppend(A_Now, sleepLogPath)
        }

        ; 就寝ブロック：指定の時間帯のスリープ時のみ発動
        h := Integer(FormatTime(, "H"))
        inNightHours := (nightBlockHourStart > nightBlockHourEnd)
            ? (h >= nightBlockHourStart || h < nightBlockHourEnd)
            : (h >= nightBlockHourStart && h < nightBlockHourEnd)

        ; ★ デバッグ用：スリープイベント受信の確認ログ
        dbgPath := A_ScriptDir "\night_debug.txt"
        FileAppend("Sleep detected at " FormatTime(, "HH:mm") " / h=" h " / inNight=" inNightHours "`n", dbgPath)

        ; 就寝ブロックは手動トリガー（トレイメニュー→就寝モード開始）に変更済み
        ; if (inNightHours)
        ;     ScheduleNightBlock()

        return
    }

    if (wParam = PBT_APMRESUMEAUTOMATIC) {

        ; スキップ曜日チェック
        for wday in skipWDays {
            if (A_WDay = wday)
                return
        }

        ; スリープ時間が閾値未満なら起動しない
        sleepHours := 0
        try {
            sleepStart := Trim(FileRead(sleepLogPath))
            sleepHours := DateDiff(A_Now, sleepStart, "Hours")
        }
        if (sleepHours < minSleepHours)
            return

        ; 就寝ブロックが実行されていれば起床時に解除
        if FileExist(nightBlockFlagPath) {
            try FileDelete(nightBlockFlagPath)
            Run('schtasks /delete /tn "NightBlock" /f', , "Hide")
            NightUnblock()
        }

        ; カウントダウン開始（まず通常待機、その後クロッキー）
        countdownEnd  := A_TickCount + (delayMinutes * 60 * 1000)
        countdownMode := "main"
        showAttempts  := 0
        SetTimer(UpdateCountdown, 1000)

        ; GUI表示：5秒・15秒・30秒の3段階でリトライ
        SetTimer(TryShowGui, -5000)
    }
}

; ===== GUI表示リトライ（変更不要）=====
TryShowGui() {
    global showAttempts, countdownEnd
    if (countdownEnd <= A_TickCount)
        return   ; すでにカウントダウン終了していたら何もしない
    showAttempts += 1
    ; 初回のみ前日サボりログを表示
    if (showAttempts = 1)
        ShowSaboLog()
    cdGui.Show("Center w240 h120 NoActivate")
    if (showAttempts = 1)
        SetTimer(TryShowGui, -10000)
    else if (showAttempts = 2)
        SetTimer(TryShowGui, -15000)
}

; ===== カウントダウン更新（変更不要）=====
; トレイアイコンのツールチップにも残り時間を表示します。
; タスクバーのランチャーアイコンにマウスを乗せると確認できます。
UpdateCountdown() {
    global countdownEnd, countdownMode
    remaining := countdownEnd - A_TickCount

    if (remaining <= 0) {
        SetTimer(UpdateCountdown, 0)
        SetTimer(TryShowGui, 0)
        cdGui.Hide()
        A_IconTip := "Work Launcher - 待機中"
        if (countdownMode = "main") {
            ; 食事時間内ならクロッキーを食事休憩終了まで延期
            if (IsMealTime()) {
                WaitForMealEnd()
            } else {
                LaunchCroquis()
            }
        } else if (countdownMode = "croquis") {
            LaunchMain()
        } else {
            LaunchCroquis()
        }
        return
    }

    secs := Ceil(remaining / 1000)
    mins := secs // 60
    secs := Mod(secs, 60)
    timeStr := Format("{:02d}:{:02d}", mins, secs)

    ; トレイアイコンのツールチップを更新（常に確実に表示される）
    label := (countdownMode = "croquis") ? "クロッキー開始まで " : "作業開始まで "
    A_IconTip := label timeStr

    ; GUIのカウントも更新
    try cdCount.Value := timeStr
}

; ===== 毎日23時にログファイルを書き出す（変更不要）=====
; 書き出し後、翌日の23時に再スケジュールします。
ScheduleDailyLog() {
    now      := A_Now
    target   := FormatTime(now, "yyyyMMdd") "230000"   ; 今日の23:00:00（DateDiff用にダッシュなし形式）
    msUntil  := DateDiff(target, now, "Seconds") * 1000
    if (msUntil <= 0)
        msUntil := msUntil + 86400000   ; すでに23時を過ぎていたら翌日
    SetTimer(WriteDailyLog, -msUntil)
}

WriteDailyLog() {
    global sabo, saboLogDir

    today   := FormatTime(, "yyyy-MM-dd")
    logPath := saboLogDir "\" today "_sabo.txt"

    ; ファイルを新規作成（上書き）
    try FileDelete(logPath)

    if (sabo.entries.Length = 0) {
        FileAppend("サボり検知なし`n", logPath)
    } else {
        for entry in sabo.entries
            FileAppend(entry "`n", logPath)
    }

    ; 翌日の23時に再スケジュール
    SetTimer(WriteDailyLog, -86400000)
}

; 起動時に23時タイマーをセット
ScheduleDailyLog()

; 起動時にクロッキー週次レポートタイマーをセット
ScheduleCroquisReport()

; ===== クロッキー週次レポート：スケジュール（変更不要）=====
ScheduleCroquisReport() {
    global croquisReportWDay, croquisReportHour

    ; 今週の「送信曜日」が何日後かを計算
    ; A_WDay: 1=日 ～ 7=土
    now        := A_Now
    todayWDay  := A_WDay
    todayH     := Integer(FormatTime(, "H"))
    todayM     := Integer(FormatTime(, "m"))

    ; 次の送信タイミングまでの日数を求める
    daysUntil := Mod(croquisReportWDay - todayWDay + 7, 7)
    ; 今日が送信曜日かつまだ送信時刻前なら今日送る、過ぎていれば7日後
    if (daysUntil = 0) {
        if (todayH > croquisReportHour || (todayH = croquisReportHour && todayM > 0))
            daysUntil := 7   ; 今日の時刻を過ぎていたら来週
    }

    targetDate   := FormatTime(DateAdd(now, daysUntil, "Days"), "yyyyMMdd")
    targetDT     := targetDate Format("{:02d}0000", croquisReportHour)
    msUntil      := DateDiff(targetDT, now, "Seconds") * 1000
    if (msUntil < 0)
        msUntil := 0

    SetTimer(SendCroquisWeeklyReport, -msUntil)
}

; ===== クロッキー週次レポート送信（変更不要）=====
SendCroquisWeeklyReport() {
    global croquisShotDir, croquisReportWebhook

    if (croquisReportWebhook = "") {
        ScheduleCroquisReport()   ; 次週へ
        return
    }

    ; 過去7日分の画像を収集
    shots := []
    loop files croquisShotDir "\*.png" {
        ; ファイル名から日付を取得（yyyy-MM-dd_HH-mm.png）
        fname := A_LoopFileName
        try {
            dateStr := SubStr(fname, 1, 10)                    ; "yyyy-MM-dd"
            fileDate := StrReplace(dateStr, "-", "")           ; "yyyyMMdd"
            weekAgo  := FormatTime(DateAdd(A_Now, -7, "Days"), "yyyyMMdd")
            if (fileDate >= weekAgo)
                shots.Push(A_LoopFileFullPath)
        }
    }

    ; 枚数・日付一覧テキストを作成
    count   := shots.Length
    dateSet := Map()
    for path in shots {
        fname   := SubStr(path, InStr(path, "\",, -1) + 1)
        dateStr := SubStr(fname, 1, 10)
        dateSet[dateStr] := true
    }
    dateList := []
    for d, _ in dateSet
        dateList.Push(d)

    ; 日付を昇順ソート（シンプルな文字列比較で可）
    n := dateList.Length
    loop n - 1 {
        i := A_Index
        loop n - i {
            j := A_Index + i
            if (dateList[j-1] > dateList[j]) {
                tmp          := dateList[j-1]
                dateList[j-1] := dateList[j]
                dateList[j]   := tmp
            }
        }
    }

    dateText := ""
    for d in dateList
        dateText .= d " / "
    dateText := RTrim(dateText, " / ")

    weekStart := FormatTime(DateAdd(A_Now, -6, "Days"), "yyyy/MM/dd")
    weekEnd   := FormatTime(A_Now, "yyyy/MM/dd")
    msgText   := "🎨 **クロッキー週次レポート** (" weekStart " ～ " weekEnd ")`n"
                . "今週の枚数：**" count " 枚**`n"
                . (dateText != "" ? "実施日：" dateText : "今週は0枚でした")

    if (count = 0) {
        ; 画像なしの場合はテキストのみ送信
        SendDiscordAlert(msgText)
        ScheduleCroquisReport()
        return
    }

    ; PowerShellで画像をmultipart送信
    q  := Chr(34)
    ps := "Add-Type -AssemblyName System.Net.Http`n"
    ps .= "$url    = " q croquisReportWebhook q "`n"
    ps .= "$client = [System.Net.Http.HttpClient]::new()`n"
    ps .= "$form   = [System.Net.Http.MultipartFormDataContent]::new()`n"

    ; テキスト部分（Content-Type を明示）
    safeMsg := StrReplace(StrReplace(msgText, '"', "'"), "`n", "\n")
    ps .= "$payload = [System.Net.Http.StringContent]::new(" q '{"content":"' safeMsg '"}' q ", [System.Text.Encoding]::UTF8, " q "application/json" q ")`n"
    ps .= "$payload.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse(" q "application/json" q ")`n"
    ps .= "$form.Add(`$payload, " q "payload_json" q ")`n"

    ; 画像ファイルを添付（最大10枚。超える場合は新しい順に切る）
    attachShots := shots
    if (attachShots.Length > 10) {
        trimmed := []
        startIdx := attachShots.Length - 9
        loop 10 {
            trimmed.Push(attachShots[startIdx + A_Index - 1])
        }
        attachShots := trimmed
    }

    for i, path in attachShots {
        fname := SubStr(path, InStr(path, "\",, -1) + 1)
        ps .= "$bytes" i " = [System.IO.File]::ReadAllBytes(" q path q ")`n"
        ps .= "$mem"   i " = [System.Net.Http.ByteArrayContent]::new(`$bytes" i ")`n"
        ps .= "$mem"   i ".Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse(" q "image/png" q ")`n"
        ps .= "$form.Add(`$mem" i ", " q "files[" (i-1) "]" q ", " q fname q ")`n"
    }

    ps .= "try {`n"
    ps .= "    $resp = $client.PostAsync(`$url, `$form).Result`n"
    ps .= "    if (-not $resp.IsSuccessStatusCode) { Write-Host ('HTTP ' + [int]$resp.StatusCode + ': ' + $resp.ReasonPhrase) }`n"
    ps .= "} catch { Write-Host $_.Exception.Message }`n"
    ps .= "$client.Dispose()`n"

    psPath := A_Temp "\croquis_weekly.ps1"
    try FileDelete(psPath)
    FileAppend(ps, psPath, "UTF-8-RAW")
    ; RunWait で完了を待ってからTrayTipを表示
    RunWait('powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File "' psPath '"',, "Hide")

    TrayTip("🎨 週次レポート送信", count " 枚をDiscordに送信しました", "Mute")

    ; 次週へ再スケジュール
    ScheduleCroquisReport()
}

; ===== 就寝ブロック：起動時にPS1を事前生成（変更不要）=====
; スリープ直前は処理時間が極短のため、PS1を起動時に生成しておく
nightBlockPsPath := A_Temp "\ndns_night_block.ps1"
{
    _q  := Chr(34)
    _ps := "$headers = @{ " _q "X-Api-Key" _q " = " _q nightdnsApiKey _q " }" . "`n"
    for _cat in nightdnsCategories {
        _body := "{" _q "id" _q ":" _q _cat _q "," _q "active" _q ":true}"
        _ps .= "$body = '" _body "'; try { Invoke-WebRequest -Uri " _q "https://api.nextdns.io/profiles/" nightdnsProfile "/parentalcontrol/categories" _q " -Method POST -Headers $headers -Body $body -ContentType " _q "application/json" _q " -UseBasicParsing | Out-Null } catch { }`n"
    }
    for _svc in nightdnsServices {
        _body := "{" _q "id" _q ":" _q _svc _q "," _q "active" _q ":true}"
        _ps .= "$body = '" _body "'; try { Invoke-WebRequest -Uri " _q "https://api.nextdns.io/profiles/" nightdnsProfile "/parentalcontrol/services" _q " -Method POST -Headers $headers -Body $body -ContentType " _q "application/json" _q " -UseBasicParsing | Out-Null } catch { }`n"
    }
    for _domain in nightdnsBlockList {
        _body := "{" _q "id" _q ":" _q _domain _q "," _q "active" _q ":true}"
        _ps .= "$body = '" _body "'; try { Invoke-WebRequest -Uri " _q "https://api.nextdns.io/profiles/" nightdnsProfile "/denylist" _q " -Method POST -Headers $headers -Body $body -ContentType " _q "application/json" _q " -UseBasicParsing | Out-Null } catch { }`n"
    }
    ; Wi-Fi再接続を待ってからAPI呼び出し、ログに結果を記録
    _logPath := A_ScriptDir "\night_block_result.txt"
    _lq := _q
    _ps .= "Add-Content " _lq _logPath _lq " " _lq "Started: $(Get-Date)" _lq "`n"
    _ps .= "Start-Sleep -Seconds 20`n"
    _ps .= "Add-Content " _lq _logPath _lq " " _lq "Network wait done" _lq "`n"
    _ps .= "try { Invoke-WebRequest -Uri " _q "https://api.nextdns.io/profiles/" nightdnsProfile "/parentalcontrol/categories/social-networks" _q " -Method DELETE -Headers " _q "$headers" _q " -UseBasicParsing | Out-Null; Add-Content " _lq _logPath _lq " " _lq "Pre-cleanup OK" _lq " } catch { Add-Content " _lq _logPath _lq " " _lq "Pre-cleanup ERR" _lq " }`n"
    _ps .= "try { $r = Invoke-WebRequest -Uri " _q "https://api.nextdns.io/profiles/" nightdnsProfile "/parentalcontrol/categories" _q " -Method POST -Headers " _q "$headers" _q " -Body " _q '{"id":"social-networks","active":true}' _q " -ContentType " _q "application/json" _q " -UseBasicParsing; Add-Content " _lq _logPath _lq " " _lq "API OK: $($r.StatusCode)" _lq " } catch { Add-Content " _lq _logPath _lq " (" _lq "API ERR: " _lq " + $_.Exception.Message) }`n"
    _ps .= "New-Item -Path " _q nightBlockFlagPath _q " -ItemType File -Force | Out-Null`n"
    _ps .= "Add-Content " _lq _logPath _lq " " _lq "Flag created. Done." _lq "`n"
    try FileDelete(nightBlockPsPath)
    FileAppend(_ps, nightBlockPsPath, "UTF-8-RAW")
}

; ===== 就寝ブロック：スケジュール登録（スリープ時に呼ばれる・変更不要）=====
; PS1は事前生成済みのため、タスク登録コマンドのみ実行する
ScheduleNightBlock() {
    global nightBlockDelay, nightBlockPsPath, nightBlockFlagPath

    triggerTime := FormatTime(DateAdd(A_Now, nightBlockDelay, "Minutes"), "HH:mm")

    ; ★ デバッグ用：PowerShellウィンドウを表示して登録結果を確認します
    q  := Chr(34)
    q2 := Chr(96) . Chr(34)
    registerCmd := "powershell -ExecutionPolicy Bypass -Command "
        . q . "$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-WindowStyle Hidden -ExecutionPolicy Bypass -File " q2 nightBlockPsPath q2 "'; "
        . "$t = New-ScheduledTaskTrigger -Once -At '" triggerTime "'; "
        . "$s = New-ScheduledTaskSettingsSet -WakeToRun; "
        . "Register-ScheduledTask -TaskName 'NightBlock' -Action $a -Trigger $t -Settings $s -Force; "
        . "Write-Host 'OK: NightBlock registered for " triggerTime "'; Start-Sleep 4" . q
    Run(registerCmd)
}

; ===== 就寝ブロック：起床時解除（変更不要）=====
NightUnblock() {
    global nightdnsApiKey, nightdnsProfile
    global nightdnsCategories, nightdnsServices, nightdnsBlockList

    psPath := A_Temp "\ndns_night_unblock.ps1"
    try FileDelete(psPath)

    q  := Chr(34)
    ps := "$headers = @{ " q "X-Api-Key" q " = " q nightdnsApiKey q " }" . "`n"

    for cat in nightdnsCategories {
        ps .= "try { Invoke-WebRequest -Uri " q "https://api.nextdns.io/profiles/" nightdnsProfile "/parentalcontrol/categories/" cat q " -Method DELETE -Headers $headers -UseBasicParsing | Out-Null } catch { }`n"
    }
    for svc in nightdnsServices {
        ps .= "try { Invoke-WebRequest -Uri " q "https://api.nextdns.io/profiles/" nightdnsProfile "/parentalcontrol/services/" svc q " -Method DELETE -Headers $headers -UseBasicParsing | Out-Null } catch { }`n"
    }
    for domain in nightdnsBlockList {
        ps .= "try { Invoke-WebRequest -Uri " q "https://api.nextdns.io/profiles/" nightdnsProfile "/denylist/" domain q " -Method DELETE -Headers $headers -UseBasicParsing | Out-Null } catch { }`n"
    }

    FileAppend(ps, psPath, "UTF-8-RAW")
    Run('powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File "' psPath '"', , "Hide")
    TrayTip("📶 スマホブロック解除", "起床を検知しました。NextDNS のブロックを解除します", "Mute")
}

SkipCountdown() {
    global countdownEnd
    countdownEnd := A_TickCount   ; 残り時間をゼロにして次のTickで即発火させる
}

; ===== 食事時間判定（変更不要）=====
IsMealTime() {
    global mealPauseStartH, mealPauseStartM, mealPauseEndH, mealPauseEndM
    nowMin   := Integer(FormatTime(, "H")) * 60 + Integer(FormatTime(, "m"))
    startMin := mealPauseStartH * 60 + mealPauseStartM
    endMin   := mealPauseEndH   * 60 + mealPauseEndM
    return (nowMin >= startMin && nowMin < endMin)
}

; ===== 食事休憩終了まで待機してからクロッキー起動（変更不要）=====
WaitForMealEnd() {
    global mealPauseEndH, mealPauseEndM
    endStr := Format("{:02d}:{:02d}", mealPauseEndH, mealPauseEndM)
    TrayTip("🍽️ 食事休憩中", "クロッキーは " endStr " に開始します", "Mute")
    try {
        cdLabel.Value := "食事休憩中..."
        cdGui.Show("Center w240 h120 NoActivate")
    }
    SetTimer(CheckMealEndForCroquis, 30000)
}

CheckMealEndForCroquis() {
    if (!IsMealTime()) {
        SetTimer(CheckMealEndForCroquis, 0)
        cdGui.Hide()
        TrayTip("🎨 クロッキー開始", "食事休憩が終わりました", "Mute")
        LaunchCroquis()
    }
}

; ===== クリップボードへの画像コピー（変更不要）=====
CopyImageToClipboard(path) {
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

; ===== クロッキー：画像選択（変更不要）=====
; 指定フォルダからランダムに1枚選ぶ。全周済みならリセットして再選択。
PickCroquisImage() {
    global croquisFolder, croquisUsedLog

    ; 対象拡張子
    exts := ["*.jpg", "*.jpeg", "*.png", "*.bmp", "*.webp"]

    ; フォルダ内の全画像を列挙
    allImages := []
    for ext in exts {
        loop files croquisFolder "\" ext {
            allImages.Push(A_LoopFileName)
        }
    }

    if (allImages.Length = 0)
        return ""   ; 画像なし

    ; 使用済みリストを読み込む
    usedList := []
    try {
        raw := FileRead(croquisUsedLog)
        loop parse raw, "`n", "`r" {
            if (Trim(A_LoopField) != "")
                usedList.Push(Trim(A_LoopField))
        }
    }

    ; 未使用画像を抽出
    unused := []
    for img in allImages {
        alreadyUsed := false
        for u in usedList {
            if (StrLower(u) = StrLower(img)) {
                alreadyUsed := true
                break
            }
        }
        if (!alreadyUsed)
            unused.Push(img)
    }

    ; 全周済みならリセット
    if (unused.Length = 0) {
        try FileDelete(croquisUsedLog)
        unused := allImages
        TrayTip("🎨 クロッキー", "全画像を使い切ったためリセットしました", "Mute")
    }

    ; ランダム選択
    idx      := Random(1, unused.Length)
    selected := unused[idx]

    ; 使用済みに追記
    FileAppend(selected "`n", croquisUsedLog)

    return croquisFolder "\" selected
}

; ===== クロッキー起動（変更不要）=====
LaunchCroquis() {
    global scriptPath, croquisFolder, croquisMode, croquisModeParams, delayMinutes, countdownEnd, countdownMode

    if (!DirExist(croquisFolder)) {
        TrayTip("⚠️ クロッキースキップ", "画像フォルダが見つかりません：" croquisFolder, "Mute")
        LaunchMain()
        return
    }

    imgPath := PickCroquisImage()
    if (imgPath = "") {
        TrayTip("⚠️ クロッキースキップ", "フォルダ内に画像が見つかりませんでした", "Mute")
        LaunchMain()
        return
    }

    ; 画像をクリップボードにコピー
    CopyImageToClipboard(imgPath)
    TrayTip("🎨 クロッキー開始", "モデル画像をクリップボードにコピーしました`nクリスタのサブビューに貼り付けてください", "Mute")

    ; モードパラメータ取得（未定義なら1にフォールバック）
    params := croquisModeParams.Has(croquisMode) ? croquisModeParams[croquisMode] : croquisModeParams[1]

    ; lock_window.ahk を /croquis モードで起動（パラメータを引数で渡す）
    Run('"' scriptPath '" /croquis:' params.lockSecs ':' params.sets ':' params.interSecs)

    ; クロッキー終了を監視（2秒ごとにフェーズファイルを確認）
    SetTimer(WaitForCroquisEnd, 2000)
}

WaitForCroquisEnd() {
    ; lock_window.ahk が終了したか確認（フェーズファイルが空になった）
    phaseNow := ""
    try phaseNow := Trim(FileRead(A_ScriptDir "\current_phase.txt"))

    ; プロセスが存在するか確認
    lockRunning := ProcessExist("AutoHotkey64.exe") || ProcessExist("AutoHotkey.exe")

    ; フェーズが "croquis_done" になったら通常フローへ移行
    if (phaseNow = "croquis_done") {
        SetTimer(WaitForCroquisEnd, 0)
        try FileDelete(A_ScriptDir "\current_phase.txt")
        TrayTip("🎨 クロッキー完了", "作業タイマーを開始します", "Mute")
        LaunchMain()
    }
}

; ===== クロッキー後の通常タイマー起動（変更不要）=====
LaunchMainAfterCroquis() {
    global countdownEnd, countdownMode, delayMinutes

    ; 残り待機時間のカウントダウンを再開
    countdownEnd  := A_TickCount + (delayMinutes * 60 * 1000)
    countdownMode := "main"

    ; GUIラベルを「作業開始まで」に更新して再表示
    try cdLabel.Value := "作業開始まで..."
    try cdGui.Opt("+AlwaysOnTop")
    cdGui.Show("Center w240 h120 NoActivate")
    SetTimer(UpdateCountdown, 1000)
    A_IconTip := "作業開始まで " delayMinutes " 分"
}

LaunchMain() {
    global scriptPath
    Run('"' scriptPath '" /auto')
}

; ================================================================
; ★ サボり検知の設定
;
;    absentThresholdMin
;      → 何分間操作がなければ「サボり離席」とみなすか。
;        食事・トイレ等を考慮して長めに設定することを推奨します。
;        警告通知はこの1分前（threshold-1分）に出ます。
; ================================================================
absentThresholdMin := 15

; ================================================================
; ★ Discord 通知設定（lock_window.ahk と同じURLを設定してください）
; ================================================================
discordWebhook := "https://discord.com/api/webhooks/1514960540949282948/QWx9sLWEDVBct8MUXU5EvsgiGKcY5C3BRriVil5Ye_yM2hvCKJPfFdI-MryZNVmhDXBS?thread_id=1514960461815353394"

; ================================================================
; ★ サボり警告の送信先（もうすぐサボり判定になります通知）
;    discordWebhook とは別のサーバーに送りたい場合はここに設定
; ================================================================
saboWarnWebhook := "https://discord.com/api/webhooks/1518930448896491520/Qg_f0kW5O-oj7Wysy5jn-VKax75jRV9cOpbIIPT7V1nOCgUE6Th4zWx3mRWR5UGN5_A5"   ; ← 警告専用の Webhook URL を入力してください

; ===== サボりログのパス（変更不要）=====
; 日付ごとに1ファイル作成されます。翌朝スリープ解除時に内容が表示されます。
; 手動でDiscordに貼り付けてください。
saboLogDir  := A_ScriptDir "\sabo_logs"
phaseFile   := A_ScriptDir "\current_phase.txt"
sentinelPath := A_ScriptDir "\launcher_running.txt"

; ===== サボり検知の内部状態（変更不要）=====
global sabo := {
    isAbsent:       false,
    absentStartMs:  0,
    saboCount:      0,
    warnedThisIdle: false,  ; 今回の離席で警告済みかどうか
    entries:        []      ; 当日のサボりログ（23時にファイルへ書き出し）
}

; ===== ログ保存先ディレクトリを作成（変更不要）=====
if !DirExist(saboLogDir)
    DirCreate(saboLogDir)

; ===== 起動時：前回の異常終了を記録（変更不要）=====
if FileExist(sentinelPath) {
    try {
        lastStart := Trim(FileRead(sentinelPath))
        interruptMins := DateDiff(A_Now, lastStart, "Minutes")
        if (interruptMins > 0 && interruptMins < 1440) {
            logDate  := FormatTime(lastStart, "yyyy-MM-dd")
            today    := FormatTime(, "yyyy-MM-dd")
            logPath  := saboLogDir "\" logDate "_sabo.txt"
            entry    := "・監視中断（異常終了）：約 " interruptMins " 分間"
            if (logDate = today) {
                ; 当日分はメモリに積む（23時にまとめて書き出す）
                sabo.entries.Push(entry)
            } else {
                ; 前日以前のものは直接ファイルへ追記
                FileAppend(entry "`n", logPath)
            }
        }
    }
}
try FileDelete(sentinelPath)
FileAppend(A_Now, sentinelPath)

; ===== 正常終了時に sentinel を削除（変更不要）=====
OnExit(LauncherCleanup)
LauncherCleanup(reason, code) {
    if (reason = "Reload")
        return
    global sentinelPath, discordWebhook
    try FileDelete(sentinelPath)
    ; WinHTTP で同期送信（PowerShell不要・OnExit内でも確実に動作）
    if (discordWebhook != "") {
        try {
            body := '{"content": "⚠️ 監視スクリプト (launcher.ahk) が終了しました。サボり検知が無効になっています。"}'
            http := ComObject("WinHttp.WinHttpRequest.5.1")
            http.Open("POST", discordWebhook, false)
            http.SetRequestHeader("Content-Type", "application/json")
            http.Send(body)
        }
    }
}

; ===== Discord 通知（変更不要）=====
SendDiscordAlert(msg) {
    global discordWebhook
    SendDiscordTo(discordWebhook, msg)
}

SendDiscord(msg) => SendDiscordAlert(msg)

SendDiscordTo(url, msg) {
    if (url = "")
        return
    try {
        safe := StrReplace(StrReplace(msg, '"', "'"), "`n", "\n")
        body := '{"content": "' safe '"}'
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("POST", url, false)
        http.SetRequestHeader("Content-Type", "application/json")
        http.Send(body)
    }
}
; ===== 離席検知：30秒ごとに監視（変更不要）=====
SetTimer(CheckAbsence, 30000)

CheckAbsence() {
    global sabo, absentThresholdMin, phaseFile, saboLogDir

    ; ロックフェーズ・中休みフェーズ中のみ計測
    phase := ""
    try phase := Trim(FileRead(phaseFile))
    if (phase != "lock" && phase != "intermission") {
        ; 監視対象外フェーズに入ったら離席状態をリセット
        ; （運動・食事休憩中の無操作が復帰後にサボりとして誤記録されるのを防ぐ）
        sabo.isAbsent       := false
        sabo.warnedThisIdle := false
        sabo.absentStartMs  := 0
        return
    }

    idleMs      := A_TimeIdlePhysical
    warnMs      := (absentThresholdMin - 1) * 60000   ; 警告タイミング（閾値の1分前）
    thresholdMs := absentThresholdMin * 60000

    ; 警告通知（閾値1分前・1回のみ）
    if (!sabo.warnedThisIdle && idleMs >= warnMs && idleMs < thresholdMs) {
        sabo.warnedThisIdle := true
        TrayTip("⚠️ もうすぐサボり判定", "あと1分操作がないとサボりとして記録されます", "Mute")
        global saboWarnWebhook
        wh := (saboWarnWebhook != "") ? saboWarnWebhook : discordWebhook
        SendDiscordTo(wh, "⏰ **もうすぐサボり判定** - あと1分で記録されます（" FormatTime(, "HH:mm") "）")
    }

    ; 閾値到達 → 離席開始とみなす
    if (!sabo.isAbsent && idleMs >= thresholdMs) {
        sabo.isAbsent      := true
        sabo.absentStartMs := A_TickCount - idleMs
    }

    ; 復帰を検知 → ログに記録
    if (sabo.isAbsent && idleMs < thresholdMs) {
        saboMins := Max(1, Round((A_TickCount - sabo.absentStartMs) / 60000))
        sabo.isAbsent       := false
        sabo.warnedThisIdle := false
        sabo.saboCount      += 1

        ; ファイルには書かず、メモリに蓄積して23時にまとめて書き出す
        sabo.entries.Push("・サボり離席 " sabo.saboCount " 回目：約 " saboMins " 分")
        SendDiscord("🛋️ **サボり離席が検知されました（" sabo.saboCount " 回目）**`n約 " saboMins " 分間離席していました（" FormatTime(, "HH:mm") " 復帰）")
        return
    }

    ; 操作が再開されたら警告フラグをリセット
    if (idleMs < warnMs)
        sabo.warnedThisIdle := false
}

; ===== スリープ解除時：前日ログをGUIで表示（変更不要）=====
ShowSaboLog() {
    global saboLogDir

    yesterday := FormatTime(DateAdd(A_Now, -1, "Days"), "yyyy-MM-dd")
    logPath   := saboLogDir "\" yesterday "_sabo.txt"

    if !FileExist(logPath)
        return

    logText := ""
    try logText := FileRead(logPath)
    if (Trim(logText) = "")
        return

    logGui := Gui("+AlwaysOnTop", yesterday " のサボりログ")
    logGui.SetFont("s10", "Segoe UI")
    logGui.BackColor := "1A1A2E"
    logGui.SetFont("s10 bold cWhite", "Segoe UI")
    logGui.Add("Text", "w320", yesterday " のサボり記録")
    logGui.SetFont("s9 cWhite", "Segoe UI")
    logGui.Add("Edit", "w320 h120 ReadOnly -E0x200 Background101020 cWhite", logText)
    logGui.SetFont("s9 c999999", "Segoe UI")
    logGui.Add("Text", "w320", "この内容を手動でDiscordに貼り付けてください。")
    logGui.Add("Button", "w320 y+8", "閉じる").OnEvent("Click", (*) => logGui.Destroy())
    logGui.Show("Center w340 NoActivate")
}
