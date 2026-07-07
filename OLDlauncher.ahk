#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; ================================================================
; ★ スリープ復帰から何分後に自動起動するか
; ================================================================
delayMinutes := 25

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

; ===== トレイアイコン設定（変更不要）=====
; スリープ復帰後、タスクバーのこのアイコンにマウスを乗せると
; 「作業開始まで XX:XX」という残り時間が常に表示されます。
A_IconTip := "Work Launcher - 待機中"

; ===== カウントダウンGUI（変更不要）=====
; ※ GUIはモニター環境によって表示されない場合があります。
;    トレイアイコンのツールチップが確実な確認方法です。
cdGui := Gui("+AlwaysOnTop +ToolWindow", "Work Mode")
cdGui.SetFont("s11 bold", "Segoe UI")
cdGui.BackColor := "1A1A2E"

cdGui.SetFont("s10", "Segoe UI")
cdGui.Add("Text", "w220 Center cWhite", "作業モード開始まで...")
cdGui.SetFont("s32 bold", "Segoe UI")
cdCount := cdGui.Add("Text", "w220 Center cWhite y+5", "00:00")
cdGui.SetFont("s9", "Segoe UI")
cdGui.Add("Text", "w220 Center c999999 y+5", "準備ができたら作業を始めましょう")
cdGui.Show("Center w240 h120 NoActivate Hide")

; ===== スリープ復帰の検知（変更不要）=====
WM_POWERBROADCAST      := 0x0218
PBT_APMSUSPEND         := 0x4
PBT_APMRESUMEAUTOMATIC := 0x12

OnMessage(WM_POWERBROADCAST, OnPower)
countdownEnd  := 0
showAttempts  := 0

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

        ; カウントダウン開始
        countdownEnd := A_TickCount + (delayMinutes * 60 * 1000)
        showAttempts := 0
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
    global countdownEnd
    remaining := countdownEnd - A_TickCount

    if (remaining <= 0) {
        SetTimer(UpdateCountdown, 0)
        SetTimer(TryShowGui, 0)
        cdGui.Hide()
        A_IconTip := "Work Launcher - 待機中"
        LaunchMain()
        return
    }

    secs := Ceil(remaining / 1000)
    mins := secs // 60
    secs := Mod(secs, 60)
    timeStr := Format("{:02d}:{:02d}", mins, secs)

    ; トレイアイコンのツールチップを更新（常に確実に表示される）
    A_IconTip := "作業開始まで " timeStr

    ; GUIのカウントも更新
    try cdCount.Value := timeStr
}

LaunchMain() {
    global scriptPath
    Run('"' scriptPath '" /auto')
}
