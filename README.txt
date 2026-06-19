Timesheet Buddy v1.0 - Smart Startup + Lock Aware + Storage Safe

Files:
1. TimesheetBuddy.ps1
2. Start_TimesheetBuddy.vbs

Version:
- v1.0

Silent restart behaviour:
- If Timesheet Buddy is already running and the user opens it again:
  - no notification is shown
  - the old running instance is stopped
  - the new instance starts fresh
- The app uses this local PID file to identify the old instance:
  Documents\TimesheetBuddy\timesheet_buddy.pid
Storage safety:
- Before every read/write, the app checks whether Documents\TimesheetBuddy exists.
- If the folder or timesheet_log.json is deleted while the app is running, it recreates them automatically.
- If today's user entries are missing, the next popup becomes the Plan/Backlog popup again.
- System-only entries like PC locked/away or interval changes do not count as user task entries for deciding the Plan/Backlog popup.


Recommended way to start:
- Double-click Start_TimesheetBuddy.vbs
- This starts the app silently without showing a blank Command Prompt window.

Automatic Windows startup:
- When the app starts, it checks whether a shortcut already exists in the user's shell:startup folder.
- If the shortcut already exists, no popup is shown.
- If the shortcut does not exist, the app asks whether Timesheet Buddy should start automatically when the user logs in to Windows.
- If the user selects Yes, the app silently creates this shortcut:
  shell:startup\Timesheet Buddy.lnk
- The shortcut points to:
  Start_TimesheetBuddy.vbs

Manual auto-start setup:
1. Keep TimesheetBuddy.ps1 and Start_TimesheetBuddy.vbs together in the same folder.
2. Press Win + R.
3. Type:
   shell:startup
4. Press Enter.
5. Right-click inside the Startup folder.
6. Choose New > Shortcut.
7. Browse/select Start_TimesheetBuddy.vbs.
8. Finish the shortcut creation.

Default schedule:
- On a brand-new computer / first run with no settings file:
  reminder interval = 60 minutes
- Popup auto-save countdown = 60 seconds
- Minimum reminder interval allowed = 1 minute, useful for testing.

Smart startup behaviour:
- If today has no saved entries:
  shows "Plan for today / backlog items"
- If today already has saved entries:
  shows the normal timesheet popup with previous task pre-filled

Themes:
- Light Theme = Sky Blue
- Dark Theme = Navy Blue
- Tray menu shows only the opposite option:
  Use Dark Theme / Use Light Theme

Lock/unlock behaviour:
- Detects Windows lock and unlock.
- When Windows is locked:
  timer stops and open popup closes without saving.
- When Windows is unlocked:
  app records "PC locked / away" with lockedAt and unlockedAt timestamps.

Timestamp format in JSON:
- createdAt, lockedAt, and unlockedAt use:
  yyyy-MM-dd HH:mm

Reminder interval change tracking:
- If the user changes reminder interval during the day, it is recorded in the JSON log.
- Example log activity:
  Reminder Interval Changed: 5 minute(s)

Summary export:
- Tray menu has:
  Export Today Summary
  Export Summary for Date
- Export Today CSV has been removed.
- Summary line format:
  From Time - To Time (X mins): Task Details
- When a summary file is created, the app shows a small Windows/tray notification instead of a blocking OK message box.
- Notification display duration is requested as 5 seconds. Windows may shorten or group notifications depending on user notification settings.

JSON log viewing:
- Tray menu has:
  Open JSON Log (Read Only)
- This creates a read-only snapshot copy:
  Documents\TimesheetBuddy\timesheet_log_readonly_view.json
- That snapshot opens in Notepad.
- The real working log remains:
  Documents\TimesheetBuddy\timesheet_log.json
- This avoids accidental edits to the active JSON log file while the app is running.

Example summary:
Timesheet Summary - 2026-06-19

09:00 - 10:00 (60 mins): Project work
10:00 Reminder Interval Changed: 5 minute(s)
10:00 - 10:05 (5 mins): Team call
10:20 - 11:10 (50 mins): PC locked / away


Textbox shortcuts:
- Ctrl+A = Select all text
- Ctrl+C = Copy
- Ctrl+X = Cut
- Ctrl+V = Paste
- Ctrl+S = Pause auto-save timer

Normal behaviour:
- Current task field is automatically pre-filled with the previous task.
- No previous task display.
- No main buttons.
- Tiny "||" button pauses the 60-second auto-save timer.
- Ctrl+S also pauses the timer.
- Press Enter to save and close.
- Press Escape to save and close.
- Clicking X saves and closes.
- Popup appears bottom-right and does not show in the Windows taskbar.

Tray menu:
- Open Popup Now
- Set Reminder Interval
- Use Dark Theme / Use Light Theme
- Export Today Summary
- Export Summary for Date
- Open JSON Log (Read Only)
- Open Settings File
- Exit

Where files are saved:
Documents\TimesheetBuddy\timesheet_log.json
Documents\TimesheetBuddy\settings.json
