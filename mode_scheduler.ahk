#Requires AutoHotkey v2.0
#SingleInstance Force

; ================================================================
; クロッキーモード週間スケジュール設定ツール
;
;    曜日ごとにクロッキーモードを選んで「保存」を押すと、
;    croquis_schedule.txt に保存されます。
;    launcher.ahk はクロッキー起動のたびにこのファイルを確認し、
;    今日の曜日に対応するモードが設定されていれば、
;    croquisMode の設定やランダム抽選より優先してそのモードを使います。
;    「ランダム」を選んだ曜日は、これまでどおりの抽選（1周するまで
;    被りなし）が行われます。
;
;    土曜日は元々「休み・何もしない曜日」（skipWDays設定）のため、
;    このスケジュールには含めていません（日〜金の6曜日のみ）。
;
;    このファイルは launcher.ahk・lock_window.ahk と同じフォルダに
;    置いて実行してください（croquis_schedule.txt を同じ場所に保存するため）。
;
;    保存したスケジュールは、変更するまで毎週繰り返し使われ続けます
;    （「次の1週間だけ」ではなく、次回このツールで変更するまでの
;    テンプレートとして扱われます）。
; ================================================================

schedulePath := A_ScriptDir "\croquis_schedule.txt"
weekdays     := ["日", "月", "火", "水", "木", "金"]   ; 土曜日は休みのため対象外

; モード一覧（croquisModeParams と合わせること。モード6はテスト専用のためここには含めない）
; modeOptions（表示名）と modeValues（実際のモード番号）は同じ順序・同じ要素数にすること。
; モード番号は必ずしも「表示順−1」と一致しない（モード6を飛ばしているため）ので、
; 位置計算ではなくこの対応表を使って変換する。
modeOptions := [
    "ランダム",
    "モード1（25分×1枚）",
    "モード2（15分×2枚）",
    "モード3（5分×5枚）",
    "モード4（記憶描画）",
    "モード5（教本模写・60分）",
    "モード7（教本模写・30分）",
    "モード8（右脳ドローイング軽め・1分×10枚）"
]
modeValues := [0, 1, 2, 3, 4, 5, 7, 8]

; ===== 既存のスケジュールを読み込む（無ければ全曜日ランダム=0）=====
; saved には「DDLの選択インデックス（1始まり）」を入れる（モード番号そのものではない）
saved := [1, 1, 1, 1, 1, 1]   ; 1 = "ランダム"
try {
    raw := Trim(FileRead(schedulePath))
    parts := StrSplit(raw, "|")
    if (parts.Length = 6) {
        for i, v in parts {
            n := Integer(v)
            for idx, mv in modeValues {
                if (mv = n) {
                    saved[i] := idx
                    break
                }
            }
        }
    }
}

; ===== GUI構築 =====
myGui := Gui("+Resize", "クロッキーモード 週間スケジュール")
myGui.SetFont("s10")
myGui.MarginX := 16
myGui.MarginY := 14

myGui.Add("Text", "w420", "曜日ごとにクロッキーモードを選んで「保存」を押してください。")
myGui.Add("Text", "w420 c6B6577", "「ランダム」の曜日は、これまでどおり自動抽選（1周するまで被りなし）になります。")
myGui.Add("Text", "w420 c6B6577", "土曜日は休みのため対象外です。")

ddls := []
loop 6 {
    i := A_Index
    myGui.Add("Text", "w50 y+14 Section", weekdays[i] "曜日")
    ddl := myGui.Add("DropDownList", "x+10 w240 Choose" saved[i], modeOptions)
    ddls.Push(ddl)
}

statusText := myGui.Add("Text", "w420 y+16 cGreen", "")

btnSave := myGui.Add("Button", "w120 y+10 Default", "💾 保存")
btnClose := myGui.Add("Button", "x+10 w120", "閉じる")
btnClearAll := myGui.Add("Button", "x+10 w160", "全曜日をランダムに戻す")

btnSave.OnEvent("Click", OnSave)
btnClose.OnEvent("Click", (*) => ExitApp())
btnClearAll.OnEvent("Click", OnClearAll)
myGui.OnEvent("Close", (*) => ExitApp())

myGui.Show()

OnSave(*) {
    global ddls, schedulePath, statusText, modeValues

    values := []
    for ddl in ddls
        values.Push(modeValues[ddl.Value])   ; DDLのValue（1始まりのindex）→ 対応表で実際のモード番号に変換

    line := ""
    for i, v in values
        line .= (i = 1 ? "" : "|") v

    try FileDelete(schedulePath)
    FileAppend(line, schedulePath)

    statusText.Text := "✅ 保存しました（" FormatTime(, "yyyy-MM-dd HH:mm") "）"
}

OnClearAll(*) {
    global ddls
    for ddl in ddls
        ddl.Choose(1)   ; 1番目 = "ランダム"
}
