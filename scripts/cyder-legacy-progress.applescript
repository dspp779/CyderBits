-- Poll a progress text file and drive AppleScript's progress UI.
-- Used as Cyder.app's visible progress owner on macOS < 12.
on run argv
	if (count of argv) < 1 then error "usage: cyder-legacy-progress.applescript PROGRESS_FILE"
	set progressFile to item 1 of argv
	set doneFile to progressFile & ".done"
	set progress total steps to -1
	set progress description to "Cyder"
	set progress additional description to "準備中…"
	repeat
		try
			do shell script "/bin/test -f " & quoted form of doneFile
			exit repeat
		end try
		try
			set raw to do shell script "/bin/cat " & quoted form of progressFile & " 2>/dev/null || true"
			if raw is not "" then
				set progress additional description to raw
			end if
		end try
		delay 0.35
	end repeat
	set progress completed steps to -1
	set progress additional description to ""
end run
