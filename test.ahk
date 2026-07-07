#Requires AutoHotkey v2.0

path := A_ScriptDir "\test_write.txt"
try FileDelete(path)
FileAppend("test", path)

if FileExist(path)
    MsgBox("書き込み成功: " path)
else
    MsgBox("書き込み失敗")