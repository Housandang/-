#Requires AutoHotkey v2.0
#SingleInstance Force

; ================================================================
; ★ お絵描き練習用：モデル画像ランダム表示ツール
;
;    クロッキー用モデル画像フォルダ（croquis_models_1〜3。サブフォルダも
;    再帰的に検索する）から完全にランダムに1枚を選んで表示するだけの、
;    独立した単純なツール。作業ロック・タイマー・使用済み管理など、
;    lock_window.ahk / launcher.ahk のクロッキーシステムとは一切連携しない
;    （何度でも自由に、好きな時に、好きなだけ起動して使える練習用。同じ
;    画像が何度も出ることもある＝使用済み管理はあえて実装していない）。
;
;    画像の表示方式は、lock_window.ahkの参照ウィンドウ（右脳ドローイング）
;    で確立した仕組み（Shell.Explorer ActiveXにHTML/CSS/JSを表示し、
;    拡大縮小・中央寄せはJS側で行う）をそのまま流用している。AHK標準の
;    Picture/Staticコントロールで踏んだ数々の不具合（.Destroy()が無い・
;    同名コントロールの重複エラー・.Valueでの再スケール不良等）を
;    繰り返さないため。詳細な経緯はlock_window.ahk側の仕様書を参照。
;
;    【操作方法】
;      ・スペースキー、または右下の「🎲 次の画像」ボタン → 次の画像へ
;      ・マウスホイール → 拡大縮小
;      ・左ドラッグ → 画像の位置調整（パン）
;      ・右ドラッグ → ウィンドウ自体の移動
;      ・端をドラッグ → ウィンドウのリサイズ
;      ・×ボタン / Alt+F4 → 終了
;
;    【対象フォルダを変える場合】下記 poseFolders の配列を編集してください。
; ================================================================

; DPI認識（変更不要）。ディスプレイ拡大率が100%以外の環境で、ウィンドウの
; ドラッグリサイズがマウスの移動量と一致しなくなる問題を防ぐ
; （lock_window.ahk側で踏んだのと同じ問題のため、最初から対応しておく）
try DllCall("SetProcessDpiAwarenessContext", "ptr", -4)
catch {
    try DllCall("Shcore\SetProcessDpiAwareness", "int", 2)
    catch {
        try DllCall("SetProcessDPIAware")
    }
}
CoordMode("Mouse", "Screen")

poseFolders := [
    A_ScriptDir "\croquis_models_1",
    A_ScriptDir "\croquis_models_2",
    A_ScriptDir "\croquis_models_3"
]
poseExts := ["*.jpg", "*.jpeg", "*.png", "*.bmp"]   ; webpは表示エンジン(IE/Trident)が非対応のため対象外

htmlPath := A_ScriptDir "\random_pose_viewer.html"

global viewGui  := ""
global wbCtrl   := ""
global wb       := ""

; ===== 画像選択（使用済み管理なし・完全ランダム）=====
PickRandomPoseImage() {
    global poseFolders, poseExts
    allImgs := []
    for folder in poseFolders {
        if !DirExist(folder)
            continue
        for ext in poseExts {
            loop files folder "\" ext, "R"
                allImgs.Push(A_LoopFileFullPath)
        }
    }
    if (allImgs.Length = 0)
        return ""
    return allImgs[Random(1, allImgs.Length)]
}

; ===== 表示用HTMLの書き出し（lock_window.ahkの参照ウィンドウと同じ仕組み）=====
WritePoseViewerHtml() {
    global htmlPath
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
    if (typeof e.deltaY !== 'undefined') delta = -e.deltaY;
    else if (typeof e.wheelDelta !== 'undefined') delta = e.wheelDelta;
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
    if (e.button !== 0) return;
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
document.oncontextmenu = function() { return false; };
</script>
</head>
<body><img id="ref" alt=""></body>
</html>
    )"
    try FileDelete(htmlPath)
    FileAppend(html, htmlPath, "UTF-8")
}

; ===== ウィンドウ作成 =====
CreateViewerWindow() {
    global viewGui, wbCtrl, wb, htmlPath

    viewGui := Gui("+Resize", "モデル画像 - お絵描き練習")
    viewGui.MarginX := 0
    viewGui.MarginY := 0
    viewGui.BackColor := "000000"
    viewGui.OnEvent("Size", OnViewerResize)
    viewGui.OnEvent("Close", (*) => ExitApp())
    viewGui.Show("w520 h560")

    WritePoseViewerHtml()

    wbCtrl := viewGui.Add("ActiveX", "x0 y0 w520 h520", "Shell.Explorer")
    wb := wbCtrl.Value
    wb.Navigate("file:///" StrReplace(htmlPath, "\", "/"))
    loop 50 {
        if (wb.ReadyState = 4)
            break
        Sleep(20)
    }

    nextBtn := viewGui.Add("Button", "x0 y520 w520 h40", "🎲 次の画像（Spaceキーでも可）")
    nextBtn.OnEvent("Click", (*) => ShowNextImage())

    ShowNextImage()
}

; リサイズ時：下部のボタン分（40px）を除いた領域にActiveXを合わせる
OnViewerResize(GuiObj, MinMax, Width, Height) {
    global wbCtrl
    if (MinMax = -1)
        return
    newH := Max(0, Height - 40)
    try wbCtrl.Move(0, 0, Width, newH)
}

ShowNextImage() {
    global wb, viewGui
    path := PickRandomPoseImage()
    if (path = "") {
        MsgBox("画像が見つかりませんでした。`ncroquis_models_1〜3 フォルダに画像が入っているか確認してください。")
        return
    }
    try {
        win := wb.Document.parentWindow
        fileUrl := "file:///" StrReplace(path, "\", "/")
        win.setImage(fileUrl)
    }
    try viewGui.Title := "モデル画像 - お絵描き練習  (" StrSplit(path, "\")[-1] ")"
}

; スペースキーで次の画像へ（このウィンドウがアクティブな時だけ）
IsViewerActive() {
    global viewGui
    if (viewGui = "")
        return false
    return WinActive("ahk_id " viewGui.Hwnd) ? true : false
}

#HotIf IsViewerActive()
Space::ShowNextImage()
#HotIf

CreateViewerWindow()
