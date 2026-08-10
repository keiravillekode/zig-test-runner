#!/usr/bin/gawk -f

# Synopsis:
# Split the output of `zig test` into one JSON record per test case.

# Arguments (set with -v):
# test_file: path to the exercise's test file, scanned for v3 metadata

# Input:
# The sanitized output of `zig test`, on stdin.

# Output:
# One compact JSON object per line, holding the "name" and "status" of a test
# and, when they are not empty, its "message", "output", "test_code" and
# "task_id". jq slurps the stream and assembles results.json, so this only has
# to emit valid JSON — escaping need not be canonical, and jq still owns
# formatting and truncation.

BEGIN {
    # A JSON string may not hold a raw C0 control character.
    for (i = 1; i < 32; i++) escape[sprintf("%c", i)] = sprintf("\\u%04x", i)
    escape[sprintf("%c", 8)] = "\\b"
    escape[sprintf("%c", 9)] = "\\t"
    escape[sprintf("%c", 10)] = "\\n"
    escape[sprintf("%c", 12)] = "\\f"
    escape[sprintf("%c", 13)] = "\\r"
    escape["\""] = "\\\""
    escape["\\"] = "\\\\"

    scan_test_file()
}

{
    lines[NR] = $0
}

END {
    segment()
    for (group = 1; group <= group_count; group++) classify(group)
}

# The interface asks for the code of each test — mandatory for concept
# exercises, where the student is never shown the test file — and for the task
# each test belongs to. A test is linked to a task by a `// task N` comment on
# its own line above it:
#
#     // task 1
#     test "expected minutes in oven" {
#         try testing.expectEqual(40, lasagna.expected_minutes_in_oven);
#     }
#
# A marker applies to the next test only, so a test covering several tasks is
# left unlinked, which is what the interface asks for. Practice exercises
# carry no markers, and so report test_code without task_id.
function scan_test_file(   i, to, m, name, pending, src_line) {
    if (test_file == "") return
    while ((getline src_line < test_file) > 0) src[++src_count] = src_line
    close(test_file)

    for (i = 1; i <= src_count; i++) {
        if (match(src[i], /^[[:space:]]*\/\/[[:space:]]*task[[:space:]]+([0-9]+)[[:space:]]*$/, m)) {
            pending = m[1]
            continue
        }
        # zig fmt keeps an empty test body on one line: `test "name" {}`.
        if (match(src[i], /^test "(.*)" \{\}[[:space:]]*$/, m)) {
            claim_task(m[1], pending)
            pending = ""
            continue
        }
        if (!match(src[i], /^test "(.*)" \{[[:space:]]*$/, m)) continue
        name = claim_task(m[1], pending)
        pending = ""
        # zig fmt closes a top-level test block with `}` in column one.
        for (to = i + 1; to <= src_count && src[to] != "}"; to++) continue
        test_code[name] = extract_code(i + 1, to - 1)
        i = to
    }
}

function claim_task(name, pending) {
    if (pending != "") task_id[name] = pending
    return name
}

# The body of a test block, stripped of surrounding blank lines and outdented
# to column one, as the interface's examples show it.
function extract_code(from, to,   i, indent, code) {
    while (from <= to && src[from] ~ /^[[:space:]]*$/) from++
    while (to >= from && src[to] ~ /^[[:space:]]*$/) to--
    indent = -1
    for (i = from; i <= to; i++) {
        if (src[i] ~ /^[[:space:]]*$/) continue
        match(src[i], /^[[:space:]]*/)
        if (indent < 0 || RLENGTH < indent) indent = RLENGTH
    }
    if (indent < 0) indent = 0
    for (i = from; i <= to; i++) code = code (i > from ? "\n" : "") substr(src[i], indent + 1)
    return code
}

# zig prints one header line per test, optionally followed by user output and
# a status line:
#   1/5 test_file.test.TEST NAME...OK              (no user output)
#   2/5 test_file.test.TEST NAME...Hello, World!   (user output)
#   OK                                             (status on the next line)
#   3/5 test_file.test.TEST NAME...FAIL (reason)   (immediate fail)
# A rich helper such as expectEqualStrings prints its diagnostic before the
# status, leaving the header ending in a bare "...".
# A failed test is followed by stack trace lines, up to the next header or the
# summary ("N passed; N failed."). Parsing takes two passes: `segment` groups
# the flat lines per test, then `classify` reduces a group to one record.
function is_header(s) { return s ~ /[0-9]+\/[0-9]+ .*\.test\..*\.\.\./ }
function is_summary(s) { return s ~ /^All / || s ~ /[0-9]+ passed;/ }
function is_ok(s) { return s ~ /OK$/ }
function is_fail(s) { return s ~ /^FAIL/ || s ~ /\.\.\.(FAIL|expected )/ }

# Pass 1 — a new group opens on a header line; the current group closes on the
# next header line or on the summary.
function segment(   i, line, current) {
    for (i = 1; i <= NR; i++) {
        line = lines[i]
        if (is_header(line)) {
            current = ++group_count
            group_size[current] = 1
            group_line[current, 1] = line
        } else if (is_summary(line)) {
            current = 0
        } else if (current) {
            group_line[current, ++group_size[current]] = line
        }
    }
}

# Pass 2 — reduce one group to one test record.
function classify(g,   header, name, size, i, status_at, output) {
    header = group_line[g, 1]
    name = header_name(header)
    size = group_size[g]

    # (a) The header carries the status, so there is no user output.
    if (is_ok(header)) {
        emit(name, "pass", "", "")
        return
    }
    if (is_fail(header)) {
        emit(name, "fail", trim(join(g, 2, size)), "")
        return
    }

    # (b) The status is still to come, because the test printed first — on the
    # header line, on lines of its own, or both.
    status_at = size + 1
    for (i = 2; i <= size; i++) {
        if (is_ok(group_line[g, i]) || is_fail(group_line[g, i])) {
            status_at = i
            break
        }
    }

    output = header_output(header)
    if (status_at > 2) output = output "\n" join(g, 2, status_at - 1)
    sub(/^\n/, "", output)

    # A group with no status line means zig was cut off mid-report. Call the
    # test failed rather than dropping it from the results.
    if (status_at <= size && is_ok(group_line[g, status_at]))
        emit(name, "pass", "", output)
    else
        emit(name, "fail", trim(join(g, status_at, size)), output)
}

# The test name runs from the first "test." to the last "...", so a name
# holding dots survives and user output on the header is left out: matching is
# leftmost-longest, so the capture stretches to the final "...".
function header_name(s,   m) {
    return match(s, /test\.(.+)\.\.\./, m) ? m[1] : s
}

# Whatever the test printed before zig reached the status, which zig appends
# to the header after the first "...".
function header_output(s,   m) {
    return match(s, /\.\.\.(.+)$/, m) ? m[1] : ""
}

function join(g, from, to,   i, s) {
    if (from > to) return ""
    s = group_line[g, from]
    for (i = from + 1; i <= to; i++) s = s "\n" group_line[g, i]
    return s
}

function trim(s) { sub(/\n+$/, "", s); return s }

function json_string(s,   i, n, c, out) {
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        out = out (c in escape ? escape[c] : c)
    }
    return out
}

function emit(name, status, message, output) {
    printf "{\"name\":\"%s\",\"status\":\"%s\"", json_string(name), status
    if (message != "") printf ",\"message\":\"%s\"", json_string(message)
    if (output != "") printf ",\"output\":\"%s\"", json_string(output)
    if (test_code[name] != "") printf ",\"test_code\":\"%s\"", json_string(test_code[name])
    if (name in task_id) printf ",\"task_id\":%d", task_id[name]
    print "}"
}
