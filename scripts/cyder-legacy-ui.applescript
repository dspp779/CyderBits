#!/usr/bin/env osascript
-- Legacy Cyder UI for macOS < 12: progress + optional file picker + shell launcher.
-- argv: SCRIPTS_DIR ENGINE_SRC [EXE_PATH] [-- GAME_ARGS...]
on run argv
	if (count of argv) < 2 then error "usage: cyder-legacy-ui.applescript SCRIPTS ENGINE_SRC [EXE] [-- args...]"
	set scriptsDir to item 1 of argv
	set engineSrc to item 2 of argv
	set exePath to ""
	set gameArgs to {}
	set sawSeparator to false
	if (count of argv) ≥ 3 then
		set i to 3
		repeat while i ≤ (count of argv)
			set token to item i of argv
			if sawSeparator then
				set end of gameArgs to token
			else if token is "--" then
				set sawSeparator to true
			else if exePath is "" then
				set exePath to token
			else
				set end of gameArgs to token
			end if
			set i to i + 1
		end repeat
	end if

	set progress total steps to -1
	set progress description to "Cyder"
	set progress additional description to "準備中…"

	set launcher to scriptsDir & "/cyder_launcher.sh"
	set progressFile to (do shell script "/usr/bin/mktemp -t cyder-progress")
	set statusFile to progressFile & ".status"
	set supportLogs to (do shell script "printf '%s' \"$HOME/Library/Application Support/Cyder/Logs\"")
	do shell script "/bin/mkdir -p " & quoted form of supportLogs

	set envPrefix to "export CYDER_RETINA_MODE=0 CYDER_PROGRESS_FILE=" & quoted form of progressFile & "; "

	try
		set progress additional description to "正在準備遊戲執行元件…"
		do shell script envPrefix & "/bin/bash " & quoted form of launcher & " --engine-src " & quoted form of engineSrc & " --ensure-engine-only"

		set progress additional description to "正在準備遊戲環境…"
		set bootstrapLog to supportLogs & "/legacy-bootstrap.log"
		set bootstrapCmd to envPrefix & "{ /bin/bash " & quoted form of launcher & " --engine-src " & quoted form of engineSrc & " --bootstrap-only >" & quoted form of bootstrapLog & " 2>&1; echo $? >" & quoted form of statusFile & "; } & echo $!"
		set bootstrapPid to do shell script bootstrapCmd
		repeat
			try
				do shell script "/bin/kill -0 " & bootstrapPid
			on error
				exit repeat
			end try
			try
				set raw to do shell script "/bin/cat " & quoted form of progressFile & " 2>/dev/null || true"
				if raw is not "" then set progress additional description to raw
			end try
			delay 0.35
		end repeat
		set bootstrapStatus to do shell script "/bin/cat " & quoted form of statusFile & " 2>/dev/null || echo 1"
		if bootstrapStatus is not "0" then error "bootstrap failed (see Logs/legacy-bootstrap.log)"

		if exePath is "" then
			set progress additional description to "請選擇遊戲…"
			set chosen to choose file with prompt "選擇 Windows 遊戲執行檔 (.exe)" of type {"com.microsoft.windows-executable", "exe", "public.executable"}
			set exePath to POSIX path of chosen
		end if

		set progress additional description to "正在啟動遊戲…"
		set launchCmd to envPrefix & "/bin/bash " & quoted form of launcher & " --engine-src " & quoted form of engineSrc & " --launch-exe " & quoted form of exePath
		if (count of gameArgs) > 0 then
			set launchCmd to launchCmd & " --"
			repeat with arg in gameArgs
				set launchCmd to launchCmd & " " & quoted form of (arg as text)
			end repeat
		end if
		do shell script launchCmd & " >/dev/null 2>&1 &"
	on error errMsg number errNum
		try
			display alert "Cyder 無法完成啟動" message errMsg as warning
		end try
		try
			do shell script "/bin/rm -f " & quoted form of progressFile & " " & quoted form of statusFile
		end try
		error errMsg number errNum
	end try

	try
		do shell script "/bin/rm -f " & quoted form of progressFile & " " & quoted form of statusFile
	end try
	set progress completed steps to -1
	set progress additional description to ""
end run
