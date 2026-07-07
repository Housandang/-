#Requires AutoHotkey v2.0

; ================================================================
; クリップボード画像コピー テスト
; 使い方：
;   1. このスクリプトをlauncherと同じフォルダに置く
;   2. imgPath に確認したい画像のフルパスを入力する
;   3. スクリプトを実行する
;   4. クリスタのサブビューなどに Ctrl+V で貼り付けて確認する
; ================================================================

imgPath := "D:\OlDocuments\sagyoukanshi\croquis_models\DSC00616.jpg"   ; ← ここを実際の画像パスに変更

if (!FileExist(imgPath)) {
    MsgBox("画像ファイルが見つかりません：`n" imgPath, "エラー", "Icon!")
    ExitApp()
}

CopyImageToClipboard(imgPath)

CopyImageToClipboard(path) {
    hGdiPlus := DllCall("LoadLibrary", "Str", "gdiplus.dll", "Ptr")
    if (!hGdiPlus) {
        MsgBox("gdiplus.dll のロードに失敗しました。", "エラー", "Icon!")
        return
    }

    token := 0
    si    := Buffer(24, 0)
    NumPut("UInt", 1, si, 0)
    DllCall("gdiplus\GdiplusStartup", "Ptr*", &token, "Ptr", si, "Ptr", 0)

    pBitmap := 0
    r := DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", path, "Ptr*", &pBitmap)
    if (r != 0 || !pBitmap) {
        MsgBox("画像の読み込みに失敗しました。コード: " r, "エラー", "Icon!")
        DllCall("gdiplus\GdiplusShutdown", "Ptr", token)
        return
    }

    ; 画像サイズ取得
    width := 0, height := 0
    DllCall("gdiplus\GdipGetImageWidth",  "Ptr", pBitmap, "UInt*", &width)
    DllCall("gdiplus\GdipGetImageHeight", "Ptr", pBitmap, "UInt*", &height)

    ; CF_DIB 用の BITMAPINFOHEADER + ピクセルデータを作成
    stride   := width * 4                          ; 32bpp（BGRA）
    dibSize  := 40 + (stride * height)             ; BITMAPINFOHEADER(40) + pixels
    hDib     := DllCall("GlobalAlloc", "UInt", 2, "UPtr", dibSize, "Ptr")  ; GMEM_MOVEABLE=2
    pDib     := DllCall("GlobalLock", "Ptr", hDib, "Ptr")

    ; BITMAPINFOHEADER を書き込む
    NumPut("UInt",  40,       pDib,  0)   ; biSize
    NumPut("Int",   width,    pDib,  4)   ; biWidth
    NumPut("Int",   -height,  pDib,  8)   ; biHeight（負=トップダウン）
    NumPut("UShort", 1,       pDib, 12)   ; biPlanes
    NumPut("UShort", 32,      pDib, 14)   ; biBitCount
    NumPut("UInt",  0,        pDib, 16)   ; biCompression（BI_RGB）
    NumPut("UInt",  stride * height, pDib, 20)  ; biSizeImage
    loop 5
        NumPut("UInt", 0, pDib, 24 + (A_Index - 1) * 4)

    ; GDI+ でピクセルデータを取得してDIBバッファに書き込む
    rect := Buffer(16, 0)
    NumPut("Int", 0,      rect,  0)
    NumPut("Int", 0,      rect,  4)
    NumPut("Int", width,  rect,  8)
    NumPut("Int", height, rect, 12)

    bmpData := Buffer(32, 0)
    NumPut("UInt", stride, bmpData, 8)    ; stride
    NumPut("UInt", 0x0026200A, bmpData, 12)  ; PixelFormat32bppARGB
    NumPut("Ptr",  pDib + 40, bmpData, 16)   ; ピクセルデータ先頭

    DllCall("gdiplus\GdipBitmapLockBits",
        "Ptr", pBitmap, "Ptr", rect,
        "UInt", 5,           ; ImageLockModeRead | ImageLockModeUserInputBuf
        "Int", 0x0026200A,   ; PixelFormat32bppARGB
        "Ptr", bmpData)
    DllCall("gdiplus\GdipBitmapUnlockBits", "Ptr", pBitmap, "Ptr", bmpData)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
    DllCall("gdiplus\GdiplusShutdown", "Ptr", token)

    DllCall("GlobalUnlock", "Ptr", hDib)

    ; CF_BITMAP も用意する
    hBitmap := 0
    hdc  := DllCall("GetDC", "Ptr", 0, "Ptr")
    hBitmap := DllCall("CreateDIBitmap", "Ptr", hdc,
        "Ptr", pDib, "UInt", 4,
        "Ptr", pDib + 40, "Ptr", pDib, "UInt", 0, "Ptr")
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)

    ; クリップボードに CF_BITMAP と CF_DIB を両方登録
    DllCall("OpenClipboard", "Ptr", 0)
    DllCall("EmptyClipboard")
    if (hBitmap)
        DllCall("SetClipboardData", "UInt", 2,  "Ptr", hBitmap)  ; CF_BITMAP
    DllCall("SetClipboardData",     "UInt", 8,  "Ptr", hDib)     ; CF_DIB
    DllCall("CloseClipboard")

    MsgBox("成功しました。クリスタに貼り付けて確認してください。", "成功", "Icon!")
}
