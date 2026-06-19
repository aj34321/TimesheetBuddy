# Timesheet Buddy
# No install. No admin. Local-only system tray timesheet reminder.
# Ultra-compact bottom-right popup.
#
# Behaviour:
# - Starts in system tray
# - On first start of the day: asks Plan for today / backlog items
# - If today's entries already exist: shows normal popup
# - Current task pre-fills with previous task
# - Enter saves and closes
# - Escape saves and closes
# - X saves and closes
# - Ctrl+S pauses the 60-second auto-save timer
# - Tiny || button also pauses the timer
# - Detects Windows lock/unlock and records away time

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# =========================
# APP CONFIG
# =========================

$AppName = "Timesheet Buddy"
$AppVersion = "v1.0"
$AppCaption = "$AppName $AppVersion"
$BaseFolder = Join-Path $env:USERPROFILE "Documents\TimesheetBuddy"
$LogFile = Join-Path $BaseFolder "timesheet_log.json"
$SettingsFile = Join-Path $BaseFolder "settings.json"
$PidFile = Join-Path $BaseFolder "timesheet_buddy.pid"

$ScriptFolder = Split-Path -Parent $PSCommandPath
$VbsLauncherFile = Join-Path $ScriptFolder "Start_TimesheetBuddy.vbs"

$DefaultReminderMinutes = 60
$MinReminderMinutes = 1
$MaxReminderMinutes = 240
$PopupAutoSaveSeconds = 60

# Theme options:
# light = Sky Blue
# dark  = Navy Blue
$DefaultThemeMode = "light"

# =========================
# SINGLE INSTANCE / SILENT RESTART GUARD
# =========================

# If user starts Timesheet Buddy again while it is already running:
# - do not show any notification
# - stop the old hidden instance
# - continue starting this new instance

if (!(Test-Path $BaseFolder)) {
    New-Item -ItemType Directory -Path $BaseFolder | Out-Null
}

function Stop-ExistingTimesheetBuddyInstance {
    try {
        if (-not (Test-Path $PidFile)) {
            return
        }

        $pidText = (Get-Content $PidFile -Raw -ErrorAction SilentlyContinue).Trim()

        if ([string]::IsNullOrWhiteSpace($pidText)) {
            return
        }

        $existingPid = 0
        $ok = [int]::TryParse($pidText, [ref]$existingPid)

        if (-not $ok -or $existingPid -le 0 -or $existingPid -eq $PID) {
            return
        }

        $shouldStop = $false

        try {
            $procInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $existingPid" -ErrorAction SilentlyContinue

            if ($null -ne $procInfo -and [string]$procInfo.CommandLine -like "*TimesheetBuddy.ps1*") {
                $shouldStop = $true
            }
        }
        catch {
            # Fallback: only stop if process exists and is a PowerShell host.
            try {
                $proc = Get-Process -Id $existingPid -ErrorAction SilentlyContinue

                if ($null -ne $proc -and ($proc.ProcessName -like "powershell*" -or $proc.ProcessName -like "pwsh*")) {
                    $shouldStop = $true
                }
            }
            catch {}
        }

        if ($shouldStop) {
            try {
                Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue
            }
            catch {}

            Start-Sleep -Milliseconds 800
        }
        else {
            # Stale or unrelated PID file.
            try {
                Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
            }
            catch {}
        }
    }
    catch {}
}

$mutexName = "Global\TimesheetBuddy_AnilJagtap"
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)

if (-not $createdNew) {
    try {
        $mutex.Dispose()
    }
    catch {}

    Stop-ExistingTimesheetBuddyInstance

    $createdNew = $false
    $mutex = $null

    for ($i = 0; $i -lt 12; $i++) {
        try {
            $createdNew = $false
            $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)

            if ($createdNew) {
                break
            }

            try {
                $mutex.Dispose()
            }
            catch {}

            Start-Sleep -Milliseconds 250
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
    }

    if (-not $createdNew) {
        # Could not restart cleanly. Exit silently as requested.
        exit
    }
}

try {
    Set-Content -Path $PidFile -Value $PID -Encoding ASCII
}
catch {}

# =========================
# COLOUR HELPERS
# =========================

function C($hex) {
    return [System.Drawing.ColorTranslator]::FromHtml($hex)
}

# Runtime theme colours, populated by Apply-Theme
$script:ColorBg = C "#BAE6FD"
$script:ColorInputBg = C "#F8FAFC"
$script:ColorText = C "#0F172A"
$script:ColorInputText = C "#0F172A"
$script:ColorMuted = C "#334155"
$script:ColorAccent = C "#0369A1"
$script:ColorTimerTrack = C "#7DD3FC"
$script:ColorTimerFill = C "#0284C7"
$script:ColorPauseBg = C "#0369A1"
$script:ColorPauseText = C "#FFFFFF"

function New-Label($text, $x, $y, $w, $h, $size, $bold, $foreColor) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.Left = $x
    $lbl.Top = $y
    $lbl.Width = $w
    $lbl.Height = $h

    $style = [System.Drawing.FontStyle]::Regular
    if ($bold) {
        $style = [System.Drawing.FontStyle]::Bold
    }

    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", $size, $style)
    $lbl.ForeColor = $foreColor
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    return $lbl
}

function Ensure-Storage {
    try {
        if (!(Test-Path $BaseFolder)) {
            New-Item -ItemType Directory -Path $BaseFolder -Force | Out-Null
        }

        if (!(Test-Path $LogFile)) {
            "[]" | Out-File -FilePath $LogFile -Encoding UTF8
        }

        if (!(Test-Path $SettingsFile)) {
            @{
                reminderMinutes = $DefaultReminderMinutes
                themeMode       = $DefaultThemeMode
            } | ConvertTo-Json -Depth 5 | Out-File -FilePath $SettingsFile -Encoding UTF8
        }
    }
    catch {
        # Storage creation is best-effort. Later read/write functions handle failures safely.
    }
}

# =========================
# STORAGE SETUP
# =========================

Ensure-Storage

# =========================
# SETTINGS
# =========================

function Write-Settings($settings) {
    Ensure-Storage
    ConvertTo-Json -InputObject $settings -Depth 5 | Out-File -FilePath $SettingsFile -Encoding UTF8
}

function Read-Settings {
    Ensure-Storage

    try {
        $content = Get-Content $SettingsFile -Raw -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($content)) {
            throw "Settings file is empty."
        }

        $settings = $content | ConvertFrom-Json

        if ($null -eq $settings.reminderMinutes) {
            $settings | Add-Member -NotePropertyName reminderMinutes -NotePropertyValue $DefaultReminderMinutes -Force
        }

        if ($null -eq $settings.themeMode) {
            $settings | Add-Member -NotePropertyName themeMode -NotePropertyValue $DefaultThemeMode -Force
        }

        $validThemes = @("light", "dark")
        if ($validThemes -notcontains [string]$settings.themeMode) {
            $settings.themeMode = $DefaultThemeMode
        }

        $mins = [int]$settings.reminderMinutes
        if ($mins -lt $MinReminderMinutes -or $mins -gt $MaxReminderMinutes) {
            $settings.reminderMinutes = $DefaultReminderMinutes
        }

        return $settings
    }
    catch {
        $settings = [PSCustomObject]@{
            reminderMinutes = $DefaultReminderMinutes
            themeMode       = $DefaultThemeMode
        }

        Write-Settings $settings
        return $settings
    }
}

$script:Settings = Read-Settings
$script:ReminderMinutes = [int]$script:Settings.reminderMinutes

function Apply-Theme {
    if ([string]$script:Settings.themeMode -eq "dark") {
        # Dark Theme: Navy Blue
        $script:ColorBg = C "#0B1F3A"
        $script:ColorInputBg = C "#102A43"
        $script:ColorText = C "#F8FAFC"
        $script:ColorInputText = C "#F8FAFC"
        $script:ColorMuted = C "#BFDBFE"
        $script:ColorAccent = C "#60A5FA"
        $script:ColorTimerTrack = C "#1E3A5F"
        $script:ColorTimerFill = C "#FACC15"
        $script:ColorPauseBg = C "#60A5FA"
        $script:ColorPauseText = C "#0B1F3A"
    }
    else {
        # Light Theme: Sky Blue
        $script:Settings.themeMode = "light"
        $script:ColorBg = C "#BAE6FD"
        $script:ColorInputBg = C "#F8FAFC"
        $script:ColorText = C "#0F172A"
        $script:ColorInputText = C "#0F172A"
        $script:ColorMuted = C "#334155"
        $script:ColorAccent = C "#0369A1"
        $script:ColorTimerTrack = C "#7DD3FC"
        $script:ColorTimerFill = C "#0284C7"
        $script:ColorPauseBg = C "#0369A1"
        $script:ColorPauseText = C "#FFFFFF"
    }
}

function Update-ThemeMenuText {
    if ($null -ne $script:MenuToggleTheme) {
        if ([string]$script:Settings.themeMode -eq "dark") {
            $script:MenuToggleTheme.Text = "Use Light Theme"
        }
        else {
            $script:MenuToggleTheme.Text = "Use Dark Theme"
        }
    }
}

function Toggle-ThemeMode {
    if ([string]$script:Settings.themeMode -eq "dark") {
        $script:Settings.themeMode = "light"
    }
    else {
        $script:Settings.themeMode = "dark"
    }

    Write-Settings $script:Settings
    Apply-Theme
    Update-ThemeMenuText
}

Apply-Theme

# =========================
# ENTRY STORAGE
# =========================

function Read-Entries {
    Ensure-Storage

    try {
        $content = Get-Content $LogFile -Raw -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($content)) {
            return @()
        }

        $data = $content | ConvertFrom-Json

        if ($null -eq $data) {
            return @()
        }

        if ($data -is [System.Array]) {
            return @($data)
        }

        return @($data)
    }
    catch {
        return @()
    }
}

function Write-Entries($entries) {
    Ensure-Storage

    if ($null -eq $entries) {
        $entries = @()
    }

    ConvertTo-Json -InputObject @($entries) -Depth 10 | Out-File -FilePath $LogFile -Encoding UTF8
}

function Today-Key {
    return (Get-Date).ToString("yyyy-MM-dd")
}

function Get-TodayEntries {
    $today = Today-Key
    return @(Read-Entries | Where-Object { $_.date -eq $today })
}

function Get-EntriesForDate($dateKey) {
    return @(Read-Entries | Where-Object { $_.date -eq $dateKey })
}

function Get-PreviousTaskText {
    $entries = @(Read-Entries)

    if ($entries.Count -eq 0) {
        return ""
    }

    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $entry = $entries[$i]

        if ([string]$entry.sourceAction -like "system_*") {
            continue
        }

        if ([string]::IsNullOrWhiteSpace([string]$entry.activity)) {
            continue
        }

        return [string]$entry.activity
    }

    return ""
}

function Get-TodayUserEntries {
    $today = Today-Key

    return @(Read-Entries | Where-Object {
        $_.date -eq $today `
        -and [string]$_.sourceAction -notlike "system_*" `
        -and -not [string]::IsNullOrWhiteSpace([string]$_.activity)
    })
}

function Resolve-PopupMode([string]$RequestedMode = "auto") {
    if ($RequestedMode -eq "startup_plan") {
        return "startup_plan"
    }

    if ($RequestedMode -eq "timesheet") {
        $todayUserEntries = @(Get-TodayUserEntries)

        if ($todayUserEntries.Count -eq 0) {
            return "startup_plan"
        }

        return "timesheet"
    }

    $todayUserEntries = @(Get-TodayUserEntries)

    if ($todayUserEntries.Count -eq 0) {
        return "startup_plan"
    }

    return "timesheet"
}

function Add-Entry($from, $to, $activity, $sourceAction) {
    $activity = [string]$activity

    if ([string]::IsNullOrWhiteSpace($activity)) {
        return
    }

    $entries = @(Read-Entries)

    $entry = [PSCustomObject]@{
        date            = Today-Key
        from            = $from
        to              = $to
        durationMinutes = $script:ReminderMinutes
        activity        = $activity.Trim()
        sourceAction    = $sourceAction
        createdAt       = (Get-Date).ToString("yyyy-MM-dd HH:mm")
    }

    $entries += $entry
    Write-Entries $entries
}

function Add-IntervalChangeEntry($oldMinutes, $newMinutes) {
    if ([int]$oldMinutes -eq [int]$newMinutes) {
        return
    }

    $now = Get-Date
    $entries = @(Read-Entries)

    $entry = [PSCustomObject]@{
        date               = Today-Key
        from               = $now.ToString("HH:mm")
        to                 = $now.ToString("HH:mm")
        durationMinutes    = 0
        activity           = "Reminder Interval Changed: $newMinutes minute(s)"
        sourceAction       = "system_interval_changed"
        oldReminderMinutes = [int]$oldMinutes
        newReminderMinutes = [int]$newMinutes
        createdAt          = $now.ToString("yyyy-MM-dd HH:mm")
    }

    $entries += $entry
    Write-Entries $entries
}

function Add-AwayEntry($lockedAt, $unlockedAt) {
    if ($null -eq $lockedAt -or $null -eq $unlockedAt) {
        return
    }

    $awayMinutes = [math]::Round(($unlockedAt - $lockedAt).TotalMinutes, 2)

    if ($awayMinutes -lt 0) {
        return
    }

    $entries = @(Read-Entries)

    $entry = [PSCustomObject]@{
        date            = $lockedAt.ToString("yyyy-MM-dd")
        from            = $lockedAt.ToString("HH:mm")
        to              = $unlockedAt.ToString("HH:mm")
        durationMinutes = $awayMinutes
        activity        = "PC locked / away"
        sourceAction    = "system_locked_away"
        lockedAt        = $lockedAt.ToString("yyyy-MM-dd HH:mm")
        unlockedAt      = $unlockedAt.ToString("yyyy-MM-dd HH:mm")
        createdAt       = $unlockedAt.ToString("yyyy-MM-dd HH:mm")
    }

    $entries += $entry
    Write-Entries $entries
}

function Show-SmallNotification($title, $message) {
    try {
        if ($null -ne $script:NotifyIcon) {
            $script:NotifyIcon.BalloonTipTitle = $title
            $script:NotifyIcon.BalloonTipText = $message
            $script:NotifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            $script:NotifyIcon.ShowBalloonTip(5000)
        }
    }
    catch {
        # Notification is best-effort only. Do not block the user.
    }
}

function Get-StartupFolderPath {
    return [Environment]::GetFolderPath("Startup")
}

function Get-StartupShortcutPath {
    return (Join-Path (Get-StartupFolderPath) "Timesheet Buddy.lnk")
}

function Test-TimesheetBuddyStartupShortcut {
    try {
        $startupFolder = Get-StartupFolderPath

        if ([string]::IsNullOrWhiteSpace($startupFolder) -or -not (Test-Path $startupFolder)) {
            return $false
        }

        if (-not (Test-Path $VbsLauncherFile)) {
            return $false
        }

        $expectedTarget = [System.IO.Path]::GetFullPath($VbsLauncherFile)

        $shell = New-Object -ComObject WScript.Shell
        $shortcuts = @(Get-ChildItem -Path $startupFolder -Filter "*.lnk" -ErrorAction SilentlyContinue)

        foreach ($shortcutFile in $shortcuts) {
            try {
                $shortcut = $shell.CreateShortcut($shortcutFile.FullName)
                $target = [string]$shortcut.TargetPath

                if (-not [string]::IsNullOrWhiteSpace($target)) {
                    $targetFull = [System.IO.Path]::GetFullPath($target)

                    if ($targetFull.Equals($expectedTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
                        return $true
                    }
                }
            }
            catch {}
        }

        return $false
    }
    catch {
        return $false
    }
}

function Add-TimesheetBuddyToStartup {
    try {
        if (-not (Test-Path $VbsLauncherFile)) {
            [System.Windows.Forms.MessageBox]::Show(
                "Unable to add to Windows startup because Start_TimesheetBuddy.vbs was not found in the app folder.",
                $AppName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        $shortcutPath = Get-StartupShortcutPath
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)

        $shortcut.TargetPath = $VbsLauncherFile
        $shortcut.WorkingDirectory = $ScriptFolder
        $shortcut.Description = "Start Timesheet Buddy automatically"
        $shortcut.Save()
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Unable to add Timesheet Buddy to Windows startup.",
            $AppCaption,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

function Prompt-AddToStartupIfMissing {
    if (Test-TimesheetBuddyStartupShortcut) {
        return
    }

    $result = [System.Windows.Forms.MessageBox]::Show(
        "Timesheet Buddy is not added to Windows startup yet.`n`nDo you want it to start automatically when you log in to Windows?",
        $AppCaption,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        Add-TimesheetBuddyToStartup
    }
}

# =========================
# EXPORT FUNCTIONS
# =========================

function Format-MinutesText($minutesValue) {
    try {
        $m = [double]$minutesValue
    }
    catch {
        $m = 0
    }

    if ([math]::Abs($m - [math]::Round($m)) -lt 0.01) {
        return ([int][math]::Round($m)).ToString()
    }

    return $m.ToString("0.##")
}

function Export-SummaryForDate($dateKey) {
    Ensure-Storage
    $entries = @(Get-EntriesForDate $dateKey)

    if ($entries.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "No entries found for $dateKey.",
            $AppCaption,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    $path = Join-Path $BaseFolder "timesheet_summary_$dateKey.txt"

    $lines = @()
    $lines += "Timesheet Summary - $dateKey"
    $lines += ""

    foreach ($e in $entries) {
        $source = [string]$e.sourceAction

        if ($source -eq "system_interval_changed") {
            $newInterval = $e.newReminderMinutes

            if ($null -eq $newInterval) {
                $newInterval = ""
            }

            if ([string]::IsNullOrWhiteSpace([string]$newInterval)) {
                $lines += "$($e.from) Reminder Interval Changed"
            }
            else {
                $lines += "$($e.from) Reminder Interval Changed: $newInterval minute(s)"
            }

            continue
        }

        $minsText = Format-MinutesText $e.durationMinutes
        $lines += "$($e.from) - $($e.to) ($minsText mins): $($e.activity)"
    }

    $lines | Out-File -FilePath $path -Encoding UTF8

    Show-SmallNotification `
        -title $AppCaption `
        -message "Summary exported: $path"
}

function Export-TodaySummary {
    Export-SummaryForDate (Today-Key)
}

function Export-SummaryForSpecificDate {
    $defaultDate = Today-Key

    $inputValue = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Enter date to export in yyyy-MM-dd format:`n`nExample: 2026-06-19",
        "Export Summary for Date",
        $defaultDate
    )

    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        return
    }

    $dateKey = $inputValue.Trim()

    if ($dateKey -notmatch '^\d{4}-\d{2}-\d{2}$') {
        [System.Windows.Forms.MessageBox]::Show(
            "Please enter the date in yyyy-MM-dd format.",
            $AppCaption,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    Export-SummaryForDate $dateKey
}

function Open-JsonLogReadOnly {
    Ensure-Storage

    try {
        $viewFile = Join-Path $BaseFolder "timesheet_log_readonly_view.json"

        if (Test-Path $viewFile) {
            try {
                Set-ItemProperty -Path $viewFile -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
            }
            catch {}
        }

        Copy-Item -Path $LogFile -Destination $viewFile -Force

        try {
            Set-ItemProperty -Path $viewFile -Name IsReadOnly -Value $true -ErrorAction SilentlyContinue
        }
        catch {}

        Start-Process notepad.exe $viewFile
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Unable to open JSON log file.",
            $AppCaption,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

function Open-SettingsFile {
    Ensure-Storage
    Start-Process notepad.exe $SettingsFile
}

# =========================
# GLOBAL APP STATE
# =========================

$script:Timer = $null
$script:NotifyIcon = $null
$script:MenuToggleTheme = $null
$script:AppShouldExit = $false

$script:IsSessionLocked = $false
$script:LockedAt = $null
$script:ActivePopupForm = $null
$script:SuppressPopupSaveOnClose = $false
$script:SessionSwitchHandler = $null
$script:IsPopupOpen = $false

# =========================
# TIMER / INTERVAL
# =========================

function Update-TrayText {
    if ($null -ne $script:NotifyIcon) {
        $text = "$AppCaption - every $script:ReminderMinutes min"

        if ($text.Length -gt 63) {
            $text = $text.Substring(0, 63)
        }

        $script:NotifyIcon.Text = $text
    }
}

function Restart-ReminderTimer {
    if ($null -eq $script:Timer) {
        return
    }

    $script:Timer.Stop()
    $script:Timer.Interval = $script:ReminderMinutes * 60 * 1000
    $script:Timer.Start()

    Update-TrayText
}

function Set-ReminderInterval {
    $inputValue = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Enter reminder interval in minutes:`n`nMinimum: $MinReminderMinutes`nMaximum: $MaxReminderMinutes",
        "Set Reminder Interval",
        "$script:ReminderMinutes"
    )

    if ([string]::IsNullOrWhiteSpace($inputValue)) {
        return
    }

    $parsed = 0
    $ok = [int]::TryParse($inputValue.Trim(), [ref]$parsed)

    if (-not $ok -or $parsed -lt $MinReminderMinutes -or $parsed -gt $MaxReminderMinutes) {
        [System.Windows.Forms.MessageBox]::Show(
            "Please enter a whole number between $MinReminderMinutes and $MaxReminderMinutes.",
            $AppCaption,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $oldReminderMinutes = [int]$script:ReminderMinutes

    $script:ReminderMinutes = $parsed
    $script:Settings.reminderMinutes = $parsed

    Write-Settings $script:Settings
    Add-IntervalChangeEntry $oldReminderMinutes $parsed
    Restart-ReminderTimer
}

# =========================
# WINDOWS LOCK / UNLOCK
# =========================

function Handle-SessionLock {
    if (-not $script:IsSessionLocked) {
        $script:IsSessionLocked = $true
        $script:LockedAt = Get-Date
    }

    try {
        if ($null -ne $script:Timer) {
            $script:Timer.Stop()
        }
    }
    catch {}

    try {
        if ($null -ne $script:ActivePopupForm -and -not $script:ActivePopupForm.IsDisposed) {
            $script:SuppressPopupSaveOnClose = $true
            $script:ActivePopupForm.Close()
        }
    }
    catch {}
}

function Handle-SessionUnlock {
    if ($script:IsSessionLocked) {
        $unlockedAt = Get-Date
        $lockedAt = $script:LockedAt

        Add-AwayEntry $lockedAt $unlockedAt

        $script:IsSessionLocked = $false
        $script:LockedAt = $null
        $script:SuppressPopupSaveOnClose = $false
    }

    Restart-ReminderTimer
}

function Register-SessionLockEvents {
    try {
        $script:SessionSwitchHandler = [Microsoft.Win32.SessionSwitchEventHandler]{
            param($sender, $eventArgs)

            if ($eventArgs.Reason -eq [Microsoft.Win32.SessionSwitchReason]::SessionLock) {
                Handle-SessionLock
            }
            elseif ($eventArgs.Reason -eq [Microsoft.Win32.SessionSwitchReason]::SessionUnlock) {
                Handle-SessionUnlock
            }
        }

        [Microsoft.Win32.SystemEvents]::add_SessionSwitch($script:SessionSwitchHandler)
    }
    catch {
        # If this is blocked, the rest of the app still runs.
    }
}

function Unregister-SessionLockEvents {
    try {
        if ($null -ne $script:SessionSwitchHandler) {
            [Microsoft.Win32.SystemEvents]::remove_SessionSwitch($script:SessionSwitchHandler)
        }
    }
    catch {}
}

# =========================
# POPUP FORM
# =========================

function Show-TimesheetPopup([string]$Mode = "auto") {
    if ($script:IsSessionLocked) {
        return
    }

    if ($script:IsPopupOpen) {
        return
    }

    Ensure-Storage
    $Mode = Resolve-PopupMode $Mode

    $script:IsPopupOpen = $true

    $now = Get-Date
    $fromTime = $now.AddMinutes(-$script:ReminderMinutes).ToString("HH:mm")
    $toTime = $now.ToString("HH:mm")

    $isStartupPlan = ($Mode -eq "startup_plan")

    $fieldLabel = "Task"
    $headerText = "$fromTime to $toTime  |  every $script:ReminderMinutes min"
    $prefillText = Get-PreviousTaskText
    $saveActionPrefix = ""

    if ($isStartupPlan) {
        $fieldLabel = "Plan"
        $headerText = "Plan for today / backlog items"
        $prefillText = ""
        $saveActionPrefix = "startup_plan_"
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $AppCaption
    $form.Width = 430
    $form.Height = 150
    $form.StartPosition = "Manual"
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedToolWindow"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.BackColor = $script:ColorBg
    $form.KeyPreview = $true

    $script:ActivePopupForm = $form
    $script:SuppressPopupSaveOnClose = $false

    $workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Left = $workArea.Right - $form.Width - 18
    $form.Top = $workArea.Bottom - $form.Height - 18

    $header = New-Label $headerText 12 10 400 20 8 $true $script:ColorMuted
    $form.Controls.Add($header)

    $taskLabel = New-Label $fieldLabel 12 42 40 22 8 $true $script:ColorAccent
    $form.Controls.Add($taskLabel)

    $activityBox = New-Object System.Windows.Forms.TextBox
    $activityBox.Left = 55
    $activityBox.Top = 40
    $activityBox.Width = 355
    $activityBox.Height = 23
    $activityBox.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $activityBox.BackColor = $script:ColorInputBg
    $activityBox.ForeColor = $script:ColorInputText
    $activityBox.BorderStyle = "FixedSingle"
    $activityBox.Text = $prefillText
    $form.Controls.Add($activityBox)

    $progressTrack = New-Object System.Windows.Forms.Panel
    $progressTrack.Left = 55
    $progressTrack.Top = 78
    $progressTrack.Width = 285
    $progressTrack.Height = 8
    $progressTrack.BackColor = $script:ColorTimerTrack
    $progressTrack.BorderStyle = "None"
    $form.Controls.Add($progressTrack)

    $progressFill = New-Object System.Windows.Forms.Panel
    $progressFill.Left = 0
    $progressFill.Top = 0
    $progressFill.Width = 0
    $progressFill.Height = 8
    $progressFill.BackColor = $script:ColorTimerFill
    $progressFill.BorderStyle = "None"
    $progressTrack.Controls.Add($progressFill)

    $countLabel = New-Label "60s" 344 72 38 18 7 $false $script:ColorMuted
    $countLabel.TextAlign = "MiddleRight"
    $form.Controls.Add($countLabel)

    $pauseButton = New-Object System.Windows.Forms.Button
    $pauseButton.Text = "||"
    $pauseButton.Left = 386
    $pauseButton.Top = 72
    $pauseButton.Width = 24
    $pauseButton.Height = 18
    $pauseButton.FlatStyle = "Flat"
    $pauseButton.FlatAppearance.BorderSize = 0
    $pauseButton.BackColor = $script:ColorPauseBg
    $pauseButton.ForeColor = $script:ColorPauseText
    $pauseButton.Font = New-Object System.Drawing.Font("Segoe UI", 6, [System.Drawing.FontStyle]::Bold)
    $pauseButton.Cursor = [System.Windows.Forms.Cursors]::Hand

    $pauseTip = New-Object System.Windows.Forms.ToolTip
    $pauseTip.SetToolTip($pauseButton, "Pause auto-save timer. Ctrl+S also pauses.")

    $form.Controls.Add($pauseButton)

    $script:popupActionDone = $false
    $script:popupTimerPaused = $false

    function Save-CurrentAndClose($sourceAction) {
        if (-not $script:popupActionDone) {
            $typedText = $activityBox.Text.Trim()

            Add-Entry `
                -from $fromTime `
                -to $toTime `
                -activity $typedText `
                -sourceAction ($saveActionPrefix + $sourceAction)

            $script:popupActionDone = $true
        }

        $form.Close()
    }

    $stopwatch = New-Object System.Diagnostics.Stopwatch
    $countTimer = New-Object System.Windows.Forms.Timer
    $countTimer.Interval = 250

    function Pause-AutoSaveTimer {
        if (-not $script:popupTimerPaused) {
            $script:popupTimerPaused = $true

            try {
                $countTimer.Stop()
                $stopwatch.Stop()
            }
            catch {}

            $countLabel.Left = 330
            $countLabel.Width = 52
            $countLabel.Text = "paused"
            $countLabel.Refresh()

            $pauseButton.Text = "off"
            $pauseButton.BackColor = C "#9CA3AF"
            $pauseButton.Refresh()
        }
    }

    $pauseButton.Add_Click({
        Pause-AutoSaveTimer
        $activityBox.Focus()
    })

    $activityBox.Add_KeyDown({
        param($sender, $e)

        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::A) {
            $e.SuppressKeyPress = $true
            $activityBox.SelectAll()
            return
        }

        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::C) {
            $e.SuppressKeyPress = $true
            $activityBox.Copy()
            return
        }

        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::X) {
            $e.SuppressKeyPress = $true
            $activityBox.Cut()
            return
        }

        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::V) {
            $e.SuppressKeyPress = $true
            $activityBox.Paste()
            return
        }

        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::S) {
            $e.SuppressKeyPress = $true
            Pause-AutoSaveTimer
            return
        }

        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            Save-CurrentAndClose "enter_saved"
        }
    })

    $form.Add_KeyDown({
        param($sender, $e)

        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::S) {
            $e.SuppressKeyPress = $true
            Pause-AutoSaveTimer
            return
        }

        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            $e.SuppressKeyPress = $true
            Save-CurrentAndClose "escape_saved"
        }
    })

    $countTimer.Add_Tick({
        if ($script:IsSessionLocked) {
            $countTimer.Stop()
            $script:SuppressPopupSaveOnClose = $true
            $form.Close()
            return
        }

        $elapsedSecondsExact = $stopwatch.Elapsed.TotalSeconds

        if ($elapsedSecondsExact -lt 0) {
            $elapsedSecondsExact = 0
        }

        if ($elapsedSecondsExact -gt $PopupAutoSaveSeconds) {
            $elapsedSecondsExact = $PopupAutoSaveSeconds
        }

        $fillWidth = [int](($elapsedSecondsExact / $PopupAutoSaveSeconds) * $progressTrack.Width)

        if ($fillWidth -lt 0) {
            $fillWidth = 0
        }

        if ($fillWidth -gt $progressTrack.Width) {
            $fillWidth = $progressTrack.Width
        }

        $progressFill.Width = $fillWidth
        $progressFill.Refresh()
        $progressTrack.Refresh()

        $remaining = [int][math]::Ceiling($PopupAutoSaveSeconds - $elapsedSecondsExact)

        if ($remaining -lt 0) {
            $remaining = 0
        }

        $countLabel.Text = "$remaining" + "s"
        $countLabel.Refresh()

        if ($elapsedSecondsExact -ge $PopupAutoSaveSeconds) {
            $countTimer.Stop()
            Save-CurrentAndClose "auto_saved"
        }
    })

    $form.Add_Shown({
        $form.Activate()
        $activityBox.Focus()
        $activityBox.SelectAll()

        $script:popupTimerPaused = $false

        $progressFill.Width = 0
        $progressFill.Refresh()

        $countLabel.Left = 344
        $countLabel.Width = 38
        $countLabel.Text = "$PopupAutoSaveSeconds" + "s"
        $countLabel.Refresh()

        $pauseButton.Text = "||"
        $pauseButton.BackColor = $script:ColorPauseBg
        $pauseButton.Refresh()

        $stopwatch.Reset()
        $stopwatch.Start()
        $countTimer.Start()
    })

    $form.Add_FormClosing({
        try {
            $countTimer.Stop()
            $stopwatch.Stop()
        }
        catch {}

        if ($script:SuppressPopupSaveOnClose) {
            $script:popupActionDone = $true
            return
        }

        if (-not $script:popupActionDone -and -not $script:AppShouldExit) {
            $typedText = $activityBox.Text.Trim()

            Add-Entry `
                -from $fromTime `
                -to $toTime `
                -activity $typedText `
                -sourceAction ($saveActionPrefix + "closed_saved")

            $script:popupActionDone = $true
        }
    })

    [void]$form.ShowDialog()

    if ($script:ActivePopupForm -eq $form) {
        $script:ActivePopupForm = $null
    }

    $script:SuppressPopupSaveOnClose = $false
    $script:IsPopupOpen = $false
}

# =========================
# SYSTEM TRAY
# =========================

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$script:NotifyIcon.Visible = $true

Update-TrayText

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

$menuOpenNow = New-Object System.Windows.Forms.ToolStripMenuItem
$menuOpenNow.Text = "Open Popup Now"

$menuSetInterval = New-Object System.Windows.Forms.ToolStripMenuItem
$menuSetInterval.Text = "Set Reminder Interval"

$script:MenuToggleTheme = New-Object System.Windows.Forms.ToolStripMenuItem
Update-ThemeMenuText

$menuExportSummary = New-Object System.Windows.Forms.ToolStripMenuItem
$menuExportSummary.Text = "Export Today Summary"

$menuExportSpecificDate = New-Object System.Windows.Forms.ToolStripMenuItem
$menuExportSpecificDate.Text = "Export Summary for Date"

$menuOpenFolder = New-Object System.Windows.Forms.ToolStripMenuItem
$menuOpenFolder.Text = "Open JSON Log (Read Only)"

$menuOpenSettings = New-Object System.Windows.Forms.ToolStripMenuItem
$menuOpenSettings.Text = "Open Settings File"

$menuExit = New-Object System.Windows.Forms.ToolStripMenuItem
$menuExit.Text = "Exit"

$contextMenu.Items.Add($menuOpenNow) | Out-Null
$contextMenu.Items.Add($menuSetInterval) | Out-Null
$contextMenu.Items.Add($script:MenuToggleTheme) | Out-Null
$contextMenu.Items.Add("-") | Out-Null
$contextMenu.Items.Add($menuExportSummary) | Out-Null
$contextMenu.Items.Add($menuExportSpecificDate) | Out-Null
$contextMenu.Items.Add($menuOpenFolder) | Out-Null
$contextMenu.Items.Add($menuOpenSettings) | Out-Null
$contextMenu.Items.Add("-") | Out-Null
$contextMenu.Items.Add($menuExit) | Out-Null

$script:NotifyIcon.ContextMenuStrip = $contextMenu

$menuOpenNow.Add_Click({
    Show-TimesheetPopup

    if ($script:AppShouldExit) {
        [System.Windows.Forms.Application]::Exit()
    }
})

$menuSetInterval.Add_Click({
    Set-ReminderInterval
})

$script:MenuToggleTheme.Add_Click({
    Toggle-ThemeMode
})

$menuExportSummary.Add_Click({
    Export-TodaySummary
})

$menuExportSpecificDate.Add_Click({
    Export-SummaryForSpecificDate
})

$menuOpenFolder.Add_Click({
    Open-JsonLogReadOnly
})

$menuOpenSettings.Add_Click({
    Open-SettingsFile
})

$menuExit.Add_Click({
    $script:AppShouldExit = $true
    [System.Windows.Forms.Application]::Exit()
})

$script:NotifyIcon.Add_DoubleClick({
    Show-TimesheetPopup

    if ($script:AppShouldExit) {
        [System.Windows.Forms.Application]::Exit()
    }
})

# =========================
# MAIN TIMER
# =========================

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = $script:ReminderMinutes * 60 * 1000

$script:Timer.Add_Tick({
    if ($script:IsSessionLocked) {
        return
    }

    Show-TimesheetPopup

    if ($script:AppShouldExit) {
        $script:Timer.Stop()
        [System.Windows.Forms.Application]::Exit()
    }
})

Register-SessionLockEvents

Prompt-AddToStartupIfMissing

$script:Timer.Start()

# Smart startup popup:
# If there are no user entries today, this shows Plan/Backlog.
# If entries already exist today, this shows the normal Task popup.
if (-not $script:IsSessionLocked) {
    Show-TimesheetPopup
}

if ($script:AppShouldExit) {
    $script:Timer.Stop()
    [System.Windows.Forms.Application]::Exit()
}

[System.Windows.Forms.Application]::Run()

# =========================
# CLEANUP
# =========================

try {
    $script:Timer.Stop()
    Unregister-SessionLockEvents

    $script:NotifyIcon.Visible = $false
    $script:NotifyIcon.Dispose()

    try {
        if (Test-Path $PidFile) {
            $pidText = (Get-Content $PidFile -Raw -ErrorAction SilentlyContinue).Trim()
            if ($pidText -eq [string]$PID) {
                Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {}

    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
catch {}
