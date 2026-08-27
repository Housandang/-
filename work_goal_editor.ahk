#Requires AutoHotkey v2.0
#SingleInstance Force

; ================================================================
; 作業ノルマ 手動編集ツール
;
;    PCの予期せぬ再起動などで、本来正しく繰り越されているはずの
;    実効ノルマ・進捗（work_goal.txt）が失われてしまった場合に、
;    手動で直接内容を確認・修正するためのツールです。
;
;    このファイルは launcher.ahk・lock_window.ahk と同じフォルダに
;    置いて実行してください（work_goal.txt・day_state.txt を
;    同じ場所から読み書きするため）。
;
;    ★ 注意
;    lock_window.ahk が起動中にここで保存しても、その後
;    lock_window.ahk 側が次に自動保存したタイミングで上書きされます。
;    なるべく lock_window.ahk を終了した状態（作業タイマーが
;    動いていない状態）で使ってください。
; ================================================================

workGoalLogPath := A_ScriptDir "\work_goal.txt"
dayStatePath    := A_ScriptDir "\day_state.txt"
phaseFilePath   := A_ScriptDir "\current_phase.txt"

; ===== 現在のdayIdを読み込む =====
currentDayId := 1
try currentDayId := Integer(Trim(FileRead(dayStatePath)))

; ===== 現在のwork_goal.txtの内容を読み込む =====
savedDayId     := 0
savedActiveMs  := 0
savedReached   := false
savedGoalMin   := 150
fileDayMatches := false
try {
    parts := StrSplit(Trim(FileRead(workGoalLogPath)), "|")
    if (parts.Length >= 4) {
        savedDayId    := Integer(parts[1])
        savedActiveMs := Integer(parts[2])
        savedReached  := (parts[3] = "1")
        savedGoalMin  := Integer(parts[4])
        fileDayMatches := (savedDayId = currentDayId)
    }
}

; ===== lock_window.ahk が動作中か確認 =====
lockRunning := false
try lockRunning := (Trim(FileRead(phaseFilePath)) != "")

; ===== GUI構築 =====
myGui := Gui("+Resize", "作業ノルマ 手動編集")
myGui.SetFont("s10")
myGui.MarginX := 16
myGui.MarginY := 14

myGui.Add("Text", "w440", "本日（dayId=" currentDayId "）の作業ノルマ・進捗を直接編集できます。")

if (!fileDayMatches) {
    myGui.Add("Text", "w440 cC0392B", "⚠️ work_goal.txt の記録（dayId="
        (savedDayId = 0 ? "記録なし" : savedDayId) "）が本日と一致していません。")
    myGui.Add("Text", "w440 c6B6577", "下の初期値は空欄扱い（実効ノルマは通常値）で表示しています。保存すると本日の新しい記録として作成されます。")
}

if (lockRunning) {
    myGui.Add("Text", "w440 cC0392B", "⚠️ lock_window.ahk が動作中の可能性があります。保存してもすぐ上書きされることがあるため、できれば終了してから使ってください。")
}

myGui.Add("Text", "w200 y+16 Section", "本日の実効ノルマ（分）")
editGoal := myGui.Add("Edit", "x+10 w100", fileDayMatches ? savedGoalMin : 150)

myGui.Add("Text", "w200 y+10 Section", "現在の作業時間（分）")
editActive := myGui.Add("Edit", "x+10 w100", fileDayMatches ? Round(savedActiveMs / 60000) : 0)

chkReached := myGui.Add("Checkbox", "y+10", "本日のノルマを達成済みにする")
chkReached.Value := fileDayMatches ? savedReached : false

statusText := myGui.Add("Text", "w440 y+16 cGreen", "")

btnSave  := myGui.Add("Button", "w120 y+10 Default", "💾 保存")
btnClose := myGui.Add("Button", "x+10 w120", "閉じる")

btnSave.OnEvent("Click", OnSave)
btnClose.OnEvent("Click", (*) => ExitApp())
myGui.OnEvent("Close", (*) => ExitApp())

myGui.Show()

OnSave(*) {
    global editGoal, editActive, chkReached, currentDayId, workGoalLogPath, statusText

    goalMin   := 0
    activeMin := 0
    try goalMin   := Integer(editGoal.Text)
    try activeMin := Integer(editActive.Text)

    if (goalMin <= 0 || activeMin < 0) {
        statusText.Text := "⚠️ 実効ノルマ・作業時間には正しい数値を入力してください"
        return
    }

    reached  := chkReached.Value ? "1" : "0"
    activeMs := activeMin * 60000

    try FileDelete(workGoalLogPath)
    FileAppend(currentDayId "|" activeMs "|" reached "|" goalMin, workGoalLogPath)

    statusText.Text := "✅ 保存しました（dayId=" currentDayId "）"
}
