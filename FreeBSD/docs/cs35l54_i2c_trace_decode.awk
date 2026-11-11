# Decode a Linux ftrace i2c log into register operations for 32-bit
# address / 32-bit big-endian value devices (CS35L54).
# Output: time addr R reg = val | W reg val [val...] (n words)
function hex(s) { gsub(/-/, "", s); return s }
/i2c_write:/ {
	match($0, /a=0[0-9a-f]+/); a = substr($0, RSTART + 3, RLENGTH - 3)
	match($0, /l=[0-9]+/); l = substr($0, RSTART + 2, RLENGTH - 2) + 0
	match($0, /l=[0-9]+ \[[0-9a-f-]+\]/); d = substr($0, RSTART, RLENGTH); sub(/^l=[0-9]+ \[/, "", d); sub(/\]$/, "", d); d = hex(d)
	t = $4; sub(/:$/, "", t)
	if (l == 4) { pend[a] = substr(d, 1, 8); ptime[a] = t; next }
	reg = substr(d, 1, 8); n = (l - 4) / 4
	if (n == 1)
		printf "%s %s W %s %s\n", t, a, reg, substr(d, 9, 8)
	else
		printf "%s %s W %s block %d words, first %s\n", t, a, reg, n, substr(d, 9, 8)
}
/i2c_reply:/ {
	match($0, /a=0[0-9a-f]+/); a = substr($0, RSTART + 3, RLENGTH - 3)
	match($0, /l=[0-9]+ \[[0-9a-f-]+\]/); d = substr($0, RSTART, RLENGTH); sub(/^l=[0-9]+ \[/, "", d); sub(/\]$/, "", d); d = hex(d)
	match($0, /l=[0-9]+/); l = substr($0, RSTART + 2, RLENGTH - 2) + 0
	if (l == 4)
		printf "%s %s R %s = %s\n", ptime[a], a, pend[a], d
	else
		printf "%s %s R %s block %d words\n", ptime[a], a, pend[a], l / 4
}
