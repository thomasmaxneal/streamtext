; =============================================================================
; StreamTextOverlay.ahk  —  AHK v2
; =============================================================================
;
; WHAT THIS SCRIPT DOES
; ---------------------
; Routes every keystroke from one specific keyboard ("overlay keyboard") to the
; StreamText live-captioning window (window title contains "Stream Text") without
; stealing focus from whatever window is currently active (e.g. a game).
;
; It uses the Windows Raw Input API (RegisterRawInputDevices + WM_INPUT) with the
; RIDEV_INPUTSINK flag so keystrokes are received even when this script is not the
; foreground window.  Matching keystrokes are forwarded to the Chrome/Edge render
; widget inside the Stream Text browser tab via ControlSend, which does NOT
; activate or steal focus.
;
; PREREQUISITE — HIDHIDE
; ----------------------
; Without extra filtering, your overlay keyboard will type into BOTH the game AND
; Stream Text.  To suppress it at the driver level so only this script sees it,
; install HidHide:
;
;   https://github.com/nefarius/HidHide/releases
;
; After installing HidHide, open the HidHide Configuration Client, add THIS
; script (or AutoHotkey64.exe) to the "Applications" whitelist, then hide the
; overlay keyboard device on the "Devices" tab.  The device will then be invisible
; to every application except the whitelisted ones — including this script.
;
; HOW TO USE
; ----------
; 1. First run: press F10 (or click the tray icon → "Pick keyboard (F10)") to open
;    the device picker.  Select your overlay keyboard from the list and click OK.
;    The choice is saved to StreamTextOverlay.ini next to the script.
; 2. Open your browser and navigate to your Stream Text session.
; 3. Type on the overlay keyboard — characters appear in Stream Text without
;    disturbing your game or other active window.
; 4. To change the keyboard, press F10 again at any time.
; 5. Right-click the tray icon → Exit to quit.
;
; =============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; ---------------------------------------------------------------------------
; Constants
; ---------------------------------------------------------------------------
WM_INPUT            := 0x00FF
RIDEV_INPUTSINK     := 0x00000100
RIM_TYPEKEYBOARD    := 1
RI_KEY_BREAK        := 1          ; Flags bit 0 set → key-up event

RAWINPUTHEADER_SIZE := 8 + A_PtrSize * 2   ; dwType(4)+dwSize(4)+hDevice(Ptr)+wParam(Ptr)

; RAWKEYBOARD offsets from start of RAWINPUT (i.e. after the header)
; MakeCode  UShort  +0
; Flags     UShort  +2
; Reserved  UShort  +4
; VKey      UShort  +6
; Message   UInt    +8
; ExtraInfo ULong   +12  (ULong = 4 bytes on both 32/64-bit in AHK)
RK_OFFSET_FLAGS := RAWINPUTHEADER_SIZE + 2
RK_OFFSET_VKEY  := RAWINPUTHEADER_SIZE + 6

; ---------------------------------------------------------------------------
; Config / state
; ---------------------------------------------------------------------------
IniFile        := A_ScriptDir "\StreamTextOverlay.ini"
SelectedDevice := ""      ; device path string (e.g. \Device\0000001a)
SelectedName   := ""      ; friendly name for tray tooltip

LoadConfig()

; ---------------------------------------------------------------------------
; Register for Raw Input (keyboard, all devices, input-sink)
; ---------------------------------------------------------------------------
RegisterRawKeyboard()

; ---------------------------------------------------------------------------
; Hook WM_INPUT
; ---------------------------------------------------------------------------
OnMessage(WM_INPUT, OnRawInput)

; ---------------------------------------------------------------------------
; Tray icon setup
; ---------------------------------------------------------------------------
BuildTray()

; ---------------------------------------------------------------------------
; Hotkey — F10 opens device picker from anywhere
; ---------------------------------------------------------------------------
HotKey "F10", (*) => ShowDevicePicker()

; =============================================================================
; Raw Input registration
; =============================================================================
RegisterRawKeyboard() {
    ; RAWINPUTDEVICE: usUsagePage(UShort) usUsage(UShort) dwFlags(UInt) hwndTarget(Ptr)
    rid := Buffer(8 + A_PtrSize, 0)
    NumPut "UShort", 1,                 rid, 0   ; HID_USAGE_PAGE_GENERIC
    NumPut "UShort", 6,                 rid, 2   ; HID_USAGE_GENERIC_KEYBOARD
    NumPut "UInt",   RIDEV_INPUTSINK,   rid, 4
    NumPut "Ptr",    A_ScriptHwnd,      rid, 8   ; target window for INPUTSINK
    if !DllCall("RegisterRawInputDevices", "Ptr", rid, "UInt", 1,
                "UInt", 8 + A_PtrSize, "Int")
        MsgBox "RegisterRawInputDevices failed.`nLastError: " A_LastError, , 16
}

; =============================================================================
; WM_INPUT handler
; =============================================================================
OnRawInput(wParam, lParam, msg, hwnd) {
    global SelectedDevice, RAWINPUTHEADER_SIZE, RK_OFFSET_FLAGS, RK_OFFSET_VKEY

    ; Get required buffer size
    cbSize := 0
    DllCall("GetRawInputData",
        "Ptr",  lParam,
        "UInt", 0x10000003,   ; RID_INPUT
        "Ptr",  0,
        "UInt*", &cbSize,
        "UInt", RAWINPUTHEADER_SIZE)

    if cbSize = 0
        return

    buf := Buffer(cbSize, 0)
    ret := DllCall("GetRawInputData",
        "Ptr",  lParam,
        "UInt", 0x10000003,
        "Ptr",  buf,
        "UInt*", &cbSize,
        "UInt", RAWINPUTHEADER_SIZE,
        "Int")

    if ret = -1 || ret = 0
        return

    ; Check type == keyboard
    dwType := NumGet(buf, 0, "UInt")
    if dwType != RIM_TYPEKEYBOARD
        return

    ; Get device handle and match against selected device
    hDevice := NumGet(buf, 8, "Ptr")   ; offset 8 = after dwType(4)+dwSize(4)

    if SelectedDevice = ""
        return

    devPath := GetDevicePath(hDevice)
    if devPath != SelectedDevice
        return

    ; Check flags — skip key-up
    flags := NumGet(buf, RK_OFFSET_FLAGS, "UShort")
    if (flags & RI_KEY_BREAK)
        return

    ; Virtual key code
    vkey := NumGet(buf, RK_OFFSET_VKEY, "UShort")

    ; Route to Stream Text
    SendToStreamText(vkey)
}

; =============================================================================
; Get device path string from a raw input device handle
; =============================================================================
GetDevicePath(hDevice) {
    cbSize := 0
    DllCall("GetRawInputDeviceInfoW",
        "Ptr",  hDevice,
        "UInt", 0x20000007,   ; RIDI_DEVICENAME
        "Ptr",  0,
        "UInt*", &cbSize)

    if cbSize = 0
        return ""

    buf := Buffer(cbSize * 2, 0)
    DllCall("GetRawInputDeviceInfoW",
        "Ptr",  hDevice,
        "UInt", 0x20000007,
        "Ptr",  buf,
        "UInt*", &cbSize)

    return StrGet(buf, "UTF-16")
}

; =============================================================================
; Enumerate connected keyboard devices with friendly names
; Returns an array of objects: [{path, name}, ...]
; =============================================================================
EnumerateKeyboards() {
    devices := []

    ; Get count
    nDevices := 0
    DllCall("GetRawInputDeviceList",
        "Ptr",  0,
        "UInt*", &nDevices,
        "UInt", 8 + A_PtrSize)   ; sizeof RAWINPUTDEVICELIST

    if nDevices = 0
        return devices

    listBuf := Buffer(nDevices * (8 + A_PtrSize), 0)
    DllCall("GetRawInputDeviceList",
        "Ptr",  listBuf,
        "UInt*", &nDevices,
        "UInt", 8 + A_PtrSize)

    stride := 8 + A_PtrSize   ; hDevice(Ptr) + dwType(UInt) + padding(UInt on 64-bit) … actually:
    ; RAWINPUTDEVICELIST = { HANDLE hDevice; DWORD dwType }
    ; on 64-bit: HANDLE=8, DWORD=4 → struct is 12 bytes but padded to 16? Let's use correct layout:
    ; Actually AHK Ptr = 8 on 64-bit.  struct { HANDLE hDevice; DWORD dwType; } = 8+4=12, no implicit pad needed by GetRawInputDeviceList docs.
    ; But we should use the size we passed (8+A_PtrSize).  On 64-bit that's 16 which matches natural alignment padding.
    ; We'll just index by stride = A_PtrSize + 4 aligned up to A_PtrSize.
    itemSize := (A_PtrSize = 8) ? 16 : 8

    Loop nDevices {
        offset  := (A_Index - 1) * itemSize
        hDevice := NumGet(listBuf, offset, "Ptr")
        dwType  := NumGet(listBuf, offset + A_PtrSize, "UInt")

        if dwType != RIM_TYPEKEYBOARD
            continue

        path := GetDevicePath(hDevice)
        name := FriendlyNameFromPath(path)

        devices.Push({path: path, name: name, handle: hDevice})
    }

    return devices
}

; =============================================================================
; Derive a friendly name from a raw device path via registry lookup
; Raw path example:  \\?\HID#VID_046D&PID_C31C&MI_00#8&1a2b3c4d&0&0000#{884b96c3-...}
; Registry key:      HKLM\SYSTEM\CurrentControlSet\Enum\HID\VID_046D&PID_C31C&MI_00\8&1a2b3c4d&0&0000
; =============================================================================
FriendlyNameFromPath(rawPath) {
    ; Strip leading \\?\ or \??\
    p := RegExReplace(rawPath, "^\\\\[?\\]\\", "")
    ; Replace # with \
    p := StrReplace(p, "#", "\")
    ; Strip the trailing GUID suffix: \{xxxxxxxx-...}
    p := RegExReplace(p, "\\\{[0-9A-Fa-f\-]+\}$", "")

    regKey := "HKLM\SYSTEM\CurrentControlSet\Enum\" p

    try {
        friendlyName := RegRead(regKey, "FriendlyName")
        return friendlyName
    }
    try {
        deviceDesc := RegRead(regKey, "DeviceDesc")
        ; DeviceDesc may be "@oem42.inf,%strkey%;Actual Name" — take part after last semicolon
        if InStr(deviceDesc, ";")
            deviceDesc := SubStr(deviceDesc, InStr(deviceDesc, ";",, -1) + 1)
        return Trim(deviceDesc)
    }
    return rawPath   ; fallback: raw path
}

; =============================================================================
; Route a virtual key to Stream Text
; =============================================================================
SendToStreamText(vkey) {
    ; Find the Stream Text window
    stWin := WinExist("Stream Text")
    if !stWin {
        ; Try partial title match
        stWin := WinExist("Stream Text ahk_exe chrome.exe")
        if !stWin
            stWin := WinExist("Stream Text ahk_exe msedge.exe")
        if !stWin
            return
    }

    ; Find the Chrome render widget inside that window
    renderHwnd := 0
    try renderHwnd := ControlGetHwnd("Chrome_RenderWidgetHostHWND1", stWin)

    ; Map vkey to a sendable string
    keyStr := VKeyToSendStr(vkey)
    if keyStr = ""
        return

    if renderHwnd {
        ; Send directly to the render widget handle, no focus change
        ControlSend keyStr, , "ahk_id " renderHwnd
    } else {
        ; Fallback: send to the window itself
        ControlSend keyStr, , "ahk_id " stWin
    }
}

; =============================================================================
; Map a Windows virtual key code to an AHK send string
; =============================================================================
VKeyToSendStr(vkey) {
    ; Printable ASCII range via VkKeyScan — try to get the character
    ; VkKeyScanEx / GetKeyNameText path for printable chars:
    static vkMap := Map(
        0x08, "{BS}",       ; Backspace
        0x09, "{Tab}",      ; Tab
        0x0D, "{Enter}",    ; Enter
        0x1B, "{Escape}",   ; Escape
        0x20, "{Space}",    ; Space
        0x25, "{Left}",
        0x26, "{Up}",
        0x27, "{Right}",
        0x28, "{Down}",
        0x2E, "{Delete}",
        0x24, "{Home}",
        0x23, "{End}",
        0x21, "{PgUp}",
        0x22, "{PgDn}"
    )

    if vkMap.Has(vkey)
        return vkMap[vkey]

    ; For printable characters, convert vkey → char using MapVirtualKey
    ; MAPVK_VK_TO_CHAR = 2
    ch := DllCall("MapVirtualKeyW", "UInt", vkey, "UInt", 2, "UInt")
    if ch > 0x20 && ch < 0x7F {
        ; Check shift state from keyboard (but since we're intercepting raw input
        ; independently, we check the current physical shift state)
        shiftDown := (GetKeyState("Shift", "P"))
        capsLock   := GetKeyState("CapsLock", "T")

        charStr := Chr(ch)
        ; MapVirtualKey returns the unshifted lowercase char
        ; Apply shift / capslock logic for alpha
        if charStr ~= "[a-zA-Z]" {
            upper := (shiftDown XOR capsLock)
            charStr := upper ? StrUpper(charStr) : StrLower(charStr)
        } else if shiftDown {
            ; Shifted symbols — use a lookup for US layout
            charStr := ShiftedChar(charStr)
        }
        ; Escape AHK special chars
        charStr := StrReplace(charStr, "{", "{{}")
        charStr := StrReplace(charStr, "}", "{}}")
        charStr := StrReplace(charStr, "!", "{!}")
        charStr := StrReplace(charStr, "#", "{#}")
        charStr := StrReplace(charStr, "+", "{+}")
        charStr := StrReplace(charStr, "^", "{^}")
        return charStr
    }

    return ""
}

; =============================================================================
; Return the shifted version of a symbol character (US layout)
; =============================================================================
ShiftedChar(ch) {
    static shiftMap := Map(
        "`", "~",
        "1", "!", "2", "@", "3", "#", "4", "$", "5", "%",
        "6", "^", "7", "&", "8", "*", "9", "(", "0", ")",
        "-", "_", "=", "+",
        "[", "{", "]", "}", "\", "|",
        ";", ":", "'", '"',
        ",", "<", ".", ">", "/", "?"
    )
    return shiftMap.Has(ch) ? shiftMap[ch] : ch
}

; =============================================================================
; Load saved device selection from INI
; =============================================================================
LoadConfig() {
    global SelectedDevice, SelectedName, IniFile
    try {
        SelectedDevice := IniRead(IniFile, "Device", "Path", "")
        SelectedName   := IniRead(IniFile, "Device", "Name", "")
    }
}

; =============================================================================
; Save device selection to INI
; =============================================================================
SaveConfig() {
    global SelectedDevice, SelectedName, IniFile
    IniWrite SelectedDevice, IniFile, "Device", "Path"
    IniWrite SelectedName,   IniFile, "Device", "Name"
}

; =============================================================================
; Device picker GUI
; =============================================================================
ShowDevicePicker() {
    global SelectedDevice, SelectedName

    keyboards := EnumerateKeyboards()
    if keyboards.Length = 0 {
        MsgBox "No keyboard devices found.", "StreamTextOverlay", 48
        return
    }

    picker := Gui("+AlwaysOnTop", "Select Overlay Keyboard")
    picker.SetFont("s10")
    picker.Add("Text", "w400", "Select the keyboard to route to Stream Text:")
    lv := picker.Add("ListView", "w400 h220 r8", ["Friendly Name", "Device Path"])

    currentRow := 0
    for idx, dev in keyboards {
        displayName := dev.name != "" ? dev.name : dev.path
        row := lv.Add("", displayName, dev.path)
        if dev.path = SelectedDevice
            currentRow := row
    }
    lv.ModifyCol(1, 240)
    lv.ModifyCol(2, 150)
    if currentRow
        lv.Modify(currentRow, "Select Focus")

    btnOK     := picker.Add("Button", "w80 Default", "OK")
    btnCancel := picker.Add("Button", "w80 x+10", "Cancel")

    btnOK.OnEvent("Click", (*) => PickerOK())
    btnCancel.OnEvent("Click", (*) => picker.Destroy())
    picker.OnEvent("Close", (*) => picker.Destroy())

    picker.Show()

    PickerOK() {
        row := lv.GetNext(0, "Focused")
        if !row
            row := lv.GetNext(0, "Selected")
        if !row {
            MsgBox "Please select a keyboard from the list.", "StreamTextOverlay", 48
            return
        }
        SelectedDevice := lv.GetText(row, 2)
        SelectedName   := lv.GetText(row, 1)
        SaveConfig()
        BuildTray()
        picker.Destroy()
        TrayTip "StreamTextOverlay", "Overlay keyboard set to:`n" SelectedName, 3
    }
}

; =============================================================================
; Build / rebuild the tray icon and menu
; =============================================================================
BuildTray() {
    global SelectedName

    A_TrayMenu.Delete()

    deviceLabel := SelectedName != "" ? SelectedName : "(none selected)"
    A_TrayMenu.Add("Device: " deviceLabel, (*) => {})
    A_TrayMenu.Disable("Device: " deviceLabel)
    A_TrayMenu.Add()   ; separator
    A_TrayMenu.Add("Pick keyboard (F10)", (*) => ShowDevicePicker())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", (*) => ExitApp())
    A_TrayMenu.Default := "Pick keyboard (F10)"

    tip := "StreamTextOverlay`n"
    tip .= (SelectedName != "") ? "Device: " SelectedName : "No device selected — press F10"
    A_IconTip := tip
}
