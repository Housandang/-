#Requires AutoHotkey v2.0

webhook := "https://discord.com/api/webhooks/1514416259574272100/SyzjM2OJ7twizEhE89qD1kw71QbiktOX5TT4KOkhgC1Un45XnzB9V5Gw6PELgskJkG2r"
msg     := "テスト：日本語と絵文字🎯"

safe := StrReplace(StrReplace(msg, '"', "'"), "`n", "\n")
body := '{"content": "' safe '"}'

try {
    http := ComObject("WinHttp.WinHttpRequest.5.1")
    http.Open("POST", webhook, false)
    http.SetRequestHeader("Content-Type", "application/json")
    http.Send(body)
    MsgBox("送信完了: " http.Status)
} catch as e {
    MsgBox("エラー: " e.Message)
}