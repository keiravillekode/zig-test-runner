# Scrape an Exercism Zig test file into a stream of test descriptors.
#
# Emits one record per top-level `test "..."` block, in declaration order:
#
#     <RS> task_id <US> name <US> test_code
#
# where RS is ASCII 0x1e and US is ASCII 0x1f, and `task_id` is empty unless
# the test is preceded by a `// task_id = N` comment. Concept Exercises use
# that comment to link a test to a numbered task in their instructions.md.
#
# Delimiting rather than emitting JSON directly keeps all string escaping in
# jq, where it is correct by construction.
#
# This relies on the track's `zig fmt --check` guarantee: a top-level test
# block opens with `test "<name>" {` at column 0, closes with `}` at column 0,
# and its body is indented by four spaces per level.

function emit(    i, code, line) {
    # Drop trailing blank lines so a test's code does not end in whitespace.
    while (body_n > 0 && body[body_n] ~ /^[[:space:]]*$/)
        body_n--

    code = ""
    for (i = 1; i <= body_n; i++) {
        line = body[i]
        sub(/^    /, "", line) # Remove one level of zig fmt indentation.
        code = code (i > 1 ? "\n" : "") line
    }

    printf "%c%s%c%s%c%s", 30, (have_task ? task_id : ""), 31, name, 31, code
}

# A task annotation preceding a test. Inside a test body it is just a comment.
!in_test && /^[[:space:]]*\/\/[[:space:]]*task_id[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$/ {
    task_id = $0
    sub(/^[^=]*=[[:space:]]*/, "", task_id)
    sub(/[[:space:]]*$/, "", task_id)
    have_task = 1
    next
}

in_test && /^\}[[:space:]]*$/ {
    emit()
    in_test = 0
    have_task = 0
    next
}

in_test {
    body[++body_n] = $0
    next
}

!in_test && /^test "/ {
    # An empty test body stays on one line: `test "name" {}`.
    if (match($0, /^test "(.*)" \{\}[[:space:]]*$/, m)) {
        name = m[1]
        body_n = 0
        emit()
        have_task = 0
        next
    }
    if (match($0, /^test "(.*)" \{[[:space:]]*$/, m)) {
        name = m[1]
        in_test = 1
        body_n = 0
        next
    }
}

# Any other top-level content detaches a dangling annotation from the next
# test. Blank lines between the comment and the test are fine.
!in_test && !/^[[:space:]]*$/ {
    have_task = 0
}
