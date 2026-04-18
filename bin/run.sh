#!/usr/bin/env sh

# Synopsis:
# Run the Exercism Zig test runner on a solution.

# Arguments:
# $1: exercise slug
# $2: path to solution folder
# $3: path to output directory

# Output:
# Writes a v2 results.json to the output directory, per
# https://github.com/exercism/docs/blob/main/building/tooling/test-runners/interface.md

# Example:
# ./bin/run.sh two-fer path/to/solution/folder/ path/to/output/directory/

# If any required arguments is missing, print the usage and exit
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "usage: ./bin/run.sh exercise-slug path/to/solution/folder/ path/to/output/directory/"
    exit 1
fi

slug="$1"
test_file="$(echo "test_${slug}.zig" | tr '-' '_')"
solution_dir=$(realpath "${2%/}")
output_dir=$(realpath "${3%/}")
results_file="${output_dir}/results.json"

# Create the output directory if it doesn't exist
mkdir -p "${output_dir}"

echo "${slug}: testing..."

start_dir="$(pwd)"
cd "${solution_dir}" || exit 1

test_output=$(zig test -target x86_64-linux-musl "${test_file}" 2>&1)
exit_code=$?

cd "${start_dir}" || exit 1

# Strip solution directory prefix and the "error: the following test
# command failed" trailer so output is portable and concise.
test_output=$(printf '%s' "${test_output}" \
    | sed -e "s#${solution_dir}/\{0,1\}##g" \
          -e '/error: the following test command failed/,$d')

# ---------- Error case (compile failure) ----------
# If the output contains "error:" with no test result lines,
# it's a compilation error — report as top-level error.
if [ ${exit_code} -ne 0 ] && printf '%s' "${test_output}" | grep -q "error:"; then
    jq -n --arg message "${test_output}" \
        '{version: 2, status: "error", message: $message}' > "${results_file}"
    echo "${slug}: done"
    exit 0
fi

# ---------- Parse per-test results ----------
# Zig test output has one line per test, optionally followed by user
# stdout and a status line:
#   1/5 test_file.test.TEST NAME...OK                     (no user output)
#   2/5 test_file.test.TEST NAME...Hello, World!          (user output)
#   OK                                                     (status on next line)
#   3/5 test_file.test.TEST NAME...FAIL (reason)          (immediate fail)
# Failed tests are followed by stack trace lines until the next
# test line or the summary ("N passed; N skipped; N failed.").
# User output between "..." and the status is captured in "output".
tests_json=$(printf '%s' "${test_output}" | jq -Rs '
    def test_name: capture("test\\.(?<n>.+)\\.\\.\\.") | .n;
    def user_output: capture("\\.\\.\\.((?<o>.+)$)") | .o // "";
    def is_test_line: test("[0-9]+/[0-9]+ .*\\.test\\..*\\.\\.\\.");
    def is_summary: startswith("All ") or test("[0-9]+ passed;");
    def is_ok: . == "OK" or endswith("OK");
    def is_fail: startswith("FAIL") or test("\\.\\.\\.(FAIL|expected )");

    split("\n") |
    reduce .[] as $line (
        {current: null, tests: []};
        if ($line | is_test_line) then
            (if .current then .tests += [.current] else . end) |
            if ($line | endswith("OK")) then
                .current = {name: ($line | test_name), status: "pass"}
            elif ($line | is_fail) then
                .current = {name: ($line | test_name), status: "fail", message: ""}
            else
                .current = {
                    name: ($line | test_name),
                    status: "pending",
                    output: ($line | user_output),
                    message: ""
                }
            end
        elif .current and .current.status == "pending" then
            if ($line | is_ok) then
                .current.status = "pass"
            elif ($line | is_fail) then
                .current.status = "fail"
                | .current.message = $line
            else
                .current.output += (if .current.output != "" then "\n" + $line else $line end)
            end
        elif .current and .current.status == "fail" and ($line | is_summary | not) then
            .current.message += (if .current.message != "" then "\n" + $line else $line end)
        elif ($line | is_summary) then
            (if .current then .tests += [.current] else . end) | .current = null
        else . end
    ) | if .current then .tests += [.current] else . end
    | .tests
    | map(
        if .message then .message |= sub("\n+$"; "") else . end
        | if .output == "" or .output == null then del(.output) else . end
    )
')

# ---------- Assemble results and truncate output fields to 500 chars ----------
if [ ${exit_code} -eq 0 ]; then
    overall="pass"
else
    overall="fail"
fi

jq -n --arg status "${overall}" --argjson tests "${tests_json}" '
    def trunc: if length > 500 then .[:481] + " [output truncated]" else . end;
    {version: 2, status: $status, tests: ($tests | map(
        if .output then .output |= trunc else . end
    ))}
' > "${results_file}"

echo "${slug}: done"
