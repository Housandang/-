#Requires AutoHotkey v2.0
#SingleInstance Force   ; 既存のインスタンスを確認なしで自動終了・上書き

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
autoLockSecs  := 1800
autoBreakSecs := 300
autoTotalSets := 3

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
    "Spotify.exe"
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

; ===== タイマー状態管理オブジェクト（変更不要）=====
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
    exemptHwnd:        0,      ; BGMウィンドウとして登録されたウィンドウのハンドル
    focusMode:            false,  ; 集中モード中かどうか
    focusModeIsAuto:      false,  ; true=自動発動 / false=手動発動
    focusCountdownEnd:    0,      ; 集中モード猶予カウントダウン用
    focusCountingDown:    false,  ; カウントダウン中はブロックを一時停止
    focusMinimizedHwnds:  []      ; 集中モードで最小化したウィンドウのHWND一覧（復元用）
}

; ===== 運動ボタン：本日使用済みか確認（変更不要）=====
exerciseUsedToday := false
try {
    lastUsed := Trim(FileRead(exerciseLogPath))
    if (lastUsed = FormatTime(, "yyyyMMdd"))
        exerciseUsedToday := true
}

; ===== カウントダウンGUI（変更不要）=====
global timerGui := Gui("+AlwaysOnTop +ToolWindow", "Timer")
timerGui.SetFont("s13 bold", "Segoe UI")
timerGui.BackColor := "CC3333"

global timerTitle := timerGui.Add("Text", "w200 Center cWhite",     "")
timerGui.SetFont("s28 bold", "Segoe UI")
global timerCount := timerGui.Add("Text", "w200 Center cWhite y+5", "00:00")
timerGui.SetFont("s10", "Segoe UI")
global timerSub   := timerGui.Add("Text", "w200 Center cWhite y+5", "")

; ================================================================
; ★ コンパクトボタン行（変更不要）
;    各ボタンにマウスを乗せると操作の説明がツールチップで表示されます。
;
;    ボタン一覧:
;    🚴 … 運動モード（Steam を一定時間解除・1日1回）
;    ➕ … セットを1つ追加
;    🎵 … BGMウィンドウを登録（ブロック除外対象）
;    🎯 … 集中モード（許可リスト以外のウィンドウをすべて最小化）
; ================================================================
timerGui.SetFont("s11", "Segoe UI")
global exerciseBtn := timerGui.Add("Button", "x5 w46 y+10", "🚴")
exerciseBtn.OnEvent("Click", OnExerciseStart)
if (exerciseUsedToday)
    exerciseBtn.Enabled := false

global addSetBtn := timerGui.Add("Button", "x+3 w46 yp", "➕")
addSetBtn.OnEvent("Click", OnAddSet)

global bgmBtn := timerGui.Add("Button", "x+3 w46 yp", "🎵")
bgmBtn.OnEvent("Click", OnBgmRegister)

global focusBtn := timerGui.Add("Button", "x+3 w46 yp", "🎯")
focusBtn.OnEvent("Click", OnFocusMode)
focusBtn.Enabled := false   ; タイマー未起動中は無効

timerGui.Show("Center w210 h158 NoActivate Hide")

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
    } else if (ctrlHwnd = bgmBtn.Hwnd) {
        if (g.exemptHwnd != 0)
            ToolTip("🎵 BGMウィンドウ登録済み`nクリックで登録を解除します")
        else
            ToolTip("🎵 BGMウィンドウを登録`nクリック後3秒以内に対象ウィンドウをアクティブにしてください`n登録したウィンドウはブロックされません")
    } else if (ctrlHwnd = focusBtn.Hwnd) {
        if (g.phase = "lock" && g.focusMode)
            ToolTip("🎯 集中モード ON（解除は休憩中のみ）`n許可リスト以外のウィンドウを最小化しています")
        else if (g.focusMode)
            ToolTip("🎯 集中モード ON`nクリックで解除できます")
        else
            ToolTip("🎯 集中モードを開始`n許可リスト以外のウィンドウをすべて最小化します`n解除は休憩中のみ可能です")
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

    if (g.phase = "done") {
        g.focusMode := false
        RunPomodoro(g.targetTitles, g.lockSecs, g.breakSecs, g.totalSets)
        return
    }

    if (!g.inMealPause && !g.isExercise) {
        if (g.phase = "lock")
            timerTitle.Value := "🔒 Lock  -  Set " g.currentSet "/" g.totalSets
        else if (g.phase = "break")
            timerTitle.Value := "☕ Break  -  Set " g.currentSet "/" g.totalSets
    }
}

; ===== BGMウィンドウ登録ボタン処理（変更不要）=====
OnBgmRegister(btn, *) {
    global g, bgmBtn

    if (g.exemptHwnd != 0) {
        g.exemptHwnd := 0
        TrayTip("BGM登録解除", "ブロック除外ウィンドウを解除しました", "Mute")
        return
    }

    bgmBtn.Text    := "🎵"
    bgmBtn.Enabled := false
    SetTimer(CaptureBgmWindow, -3000)
}

CaptureBgmWindow() {
    global g, bgmBtn
    hwnd := WinGetID("A")
    if (hwnd = 0 || hwnd = timerGui.Hwnd) {
        bgmBtn.Text    := "🎵"
        bgmBtn.Enabled := true
        TrayTip("登録失敗", "有効なウィンドウが取得できませんでした", "Mute")
        return
    }
    g.exemptHwnd   := hwnd
    bgmBtn.Text    := "🎵"
    bgmBtn.Enabled := true
    TrayTip("BGM登録完了", "このウィンドウはブロックされません", "Mute")
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
    } else if (g.phase = "break" || g.phase = "done") {
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

            ; BGM登録ウィンドウはスキップ
            if (IsExemptHwnd(hwnd))
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
            g.focusMinimizedHwnds.Push(hwnd)   ; 復元用に記録
        }
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

; ===== 除外ウィンドウ判定（変更不要）=====
IsExemptHwnd(hwnd) {
    global g
    return (g.exemptHwnd != 0 && hwnd = g.exemptHwnd)
}

; ===== 食事休憩チェック：15秒ごとに監視（変更不要）=====
SetTimer(CheckMealPause, 15000)

CheckMealPause() {
    global g, timerGui, timerTitle, timerCount, timerSub
    global mealPauseStartH, mealPauseStartM, mealPauseEndH, mealPauseEndM

    if (g.phase = "")
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

        timerGui.BackColor := "37474F"
        timerTitle.Value   := "🍽️ 食事休憩中"
        timerCount.Value   := "--:--"
        endTimeStr         := Format("{:02d}:{:02d}", mealPauseEndH, mealPauseEndM)
        timerSub.Value     := endTimeStr " に自動で再開します"
        SoundPlay("*48")
        TrayTip("食事休憩", endTimeStr " にタイマーを再開します", "Mute")

    } else if (!inWindow && g.inMealPause) {
        g.inMealPause := false

        if (g.isExercise)
            return

        g.isPaused := false
        g.endTick  := A_TickCount + g.pausedRemainingMs

        if (g.phase = "lock") {
            timerGui.BackColor := "CC3333"
            timerTitle.Value   := "🔒 Lock  -  Set " g.currentSet "/" g.totalSets
            timerSub.Value     := "remaining time"
        } else {
            timerGui.BackColor := "2E7D32"
            timerTitle.Value   := "☕ Break  -  Set " g.currentSet "/" g.totalSets
            timerSub.Value     := "enjoy your break!"
        }
        SoundPlay("*48")
        TrayTip("作業再開", "タイマーを再開します", "Mute")
    }
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
    global g, exerciseUnlockKey, timerGui, timerTitle, timerCount, timerSub
    global mealPauseEndH, mealPauseEndM

    g.targetTitles.Push(exerciseUnlockKey)
    g.isExercise := false

    if (g.inMealPause) {
        timerGui.BackColor := "37474F"
        timerTitle.Value   := "🍽️ 食事休憩中"
        timerCount.Value   := "--:--"
        endTimeStr         := Format("{:02d}:{:02d}", mealPauseEndH, mealPauseEndM)
        timerSub.Value     := endTimeStr " に自動で再開します"
    } else {
        g.isPaused := false
        g.endTick  := A_TickCount + g.pausedRemainingMs

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

    SoundPlay("*48")
    TrayTip("運動終了", exerciseUnlockKey " のブロックを再開しました", "Mute")
}

; ===== 起動モード判定（変更不要）=====
isAuto := false
for arg in A_Args {
    if (arg = "/auto")
        isAuto := true
}

if (isAuto) {
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

; ===== ポモドーロ本体（変更不要）=====
RunPomodoro(targetTitles, lockSecs, breakSecs, totalSets) {
    global g, timerGui, timerTitle, timerCount, timerSub

    g.targetTitles := targetTitles
    g.totalSets    := totalSets
    g.lockSecs     := lockSecs
    g.breakSecs    := breakSecs

    RunSet(currentSet) {

        if (currentSet > g.totalSets) {
            g.phase := "done"
            SoundPlay("*48")
            TrayTip("All done!", "All " g.totalSets " sets complete！お疲れ様でした！")
            timerGui.BackColor := "1A1A2E"
            timerTitle.SetFont("cWhite")
            timerCount.SetFont("cWhite")
            timerSub.SetFont("cWhite")
            timerTitle.Value := "✅ All done!"
            timerCount.Value := "--:--"
            timerSub.Value   := "➕ ボタンで追加セットを開始"
            UpdateFocusBtnState()
            FocusModeRestore()
            return
        }

        g.currentSet := currentSet
        g.phase      := "lock"
        g.endTick    := A_TickCount + (lockSecs * 1000)
        g.isPaused   := false

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
            if (g.isPaused)
                return

            remaining := g.endTick - A_TickCount

            if (remaining <= 0) {
                SetTimer(LockWindow, 0)

                g.phase   := "break"
                g.endTick := A_TickCount + (breakSecs * 1000)

                timerGui.BackColor := "2E7D32"
                timerTitle.SetFont("cWhite")
                timerCount.SetFont("cWhite")
                timerSub.SetFont("cWhite")
                timerTitle.Value := "☕ Break  -  Set " currentSet "/" g.totalSets
                timerSub.Value   := g.focusMode ? "enjoy your break!  🎯 ON" : "enjoy your break!"
                SoundPlay("*48")
                TrayTip("Break! [Set " currentSet "/" g.totalSets "]", breakSecs // 60 " min break - enjoy!", "Mute")
                UpdateFocusBtnState()
                ; 集中モードで最小化したウィンドウを休憩開始時に復元
                FocusModeRestore()

                SetTimer(BreakTimer, 300)

                BreakTimer() {
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
                return
            }

            secs := Ceil(remaining / 1000)
            mins := secs // 60
            secs := Mod(secs, 60)
            timerCount.Value := Format("{:02d}:{:02d}", mins, secs)

            ; カウントダウン中はブロック処理を一時停止
            if (g.focusCountingDown)
                return

            ; 通常ブロック
            for targetTitle in g.targetTitles {
                winList := WinGetList(targetTitle)
                for hwnd in winList {
                    try {
                        state := WinGetMinMax("ahk_id " hwnd)
                        if (state != -1 && !IsExemptHwnd(hwnd))
                            WinMinimize("ahk_id " hwnd)
                    }
                }
            }

            ; 集中モード：許可リスト以外のすべてのウィンドウを最小化
            ; （カウントダウンはセット開始時のみ。ループ中は直接最小化）
            if (g.focusMode)
                FocusModeMinimize()
        }
    }

    RunSet(1)
}
