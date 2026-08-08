#!/usr/bin/env bash

# Synopsis:
# Run the Exercism Zig test runner on a solution.

# Arguments:
# $1: exercise slug
# $2: path to solution folder
# $3: path to output directory

# Output:
# Writes a v3 results.json to the output directory, per
# https://github.com/exercism/docs/blob/main/building/tooling/test-runners/interface.md

# Example:
# ./bin/run.sh two-fer path/to/solution/folder/ path/to/output/directory/

readonly INTERFACE_VERSION=3

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"
readonly script_dir

# Print usage and exit non-zero. Called when required args are missing.
usage() {
    echo "usage: ./bin/run.sh exercise-slug path/to/solution/folder/ path/to/output/directory/"
    exit 1
}

# Parse positional args, set globals consumed by later stages.
# Sets: slug, test_file, solution_dir, output_dir, results_file.
parse_args() {
    [[ -z "$1" || -z "$2" || -z "$3" ]] && usage
    slug="$1"
    test_file="$(echo "test_${slug}.zig" | tr '-' '_')"
    solution_dir=$(realpath "${2%/}")
    output_dir=$(realpath "${3%/}")
    results_file="${output_dir}/results.json"
}

# Compile and run the solution's test file, strip the solution-dir prefix
# and the "test command failed" trailer from the output so it is portable.
# Prints the sanitized output to stdout and returns zig's exit code.
run_zig_test() {
    local raw_output zig_exit
    raw_output=$(cd "${solution_dir}" && zig test -target x86_64-linux-musl "${test_file}" 2>&1)
    zig_exit=$?
    printf '%s' "${raw_output}" \
        | sed -e "s#${solution_dir}/\{0,1\}##g" \
              -e '/error: the following test command failed/,$d'
    return "${zig_exit}"
}

# Emit a top-level error report (compile failure) and exit successfully —
# the runner completed its job even though the solution did not build.
emit_compile_error() {
    jq -n --argjson version "${INTERFACE_VERSION}" --arg message "${test_output}" \
        '{version: $version, status: "error", message: $message}' > "${results_file}"
    echo "${slug}: done"
    exit 0
}

# Read the exercise's test file and return a JSON array of test descriptors:
# [{name, test_code, task_id?}], in declaration order.
#
# `test_code` is required for Concept Exercises, because students are never
# shown the test file — without it the exercise cannot be solved. `task_id`
# links a test to a numbered task in the exercise's instructions.md.
#
# Students can edit the test file of a Practice Exercise and submit it, so a
# file that does not parse yields an empty array rather than an error.
read_test_file() {
    local path="${solution_dir}/${test_file}"
    [[ -f "${path}" ]] || { echo '[]'; return; }

    awk -f "${script_dir}/scrape-tests.awk" "${path}" | jq -Rs '
        split("\u001e")[1:]
        | map(
            split("\u001f")
            | {name: .[1], test_code: .[2]}
            + (if .[0] == "" then {} else {task_id: (.[0] | tonumber)} end)
        )
    '
}

# Parse Zig's per-test output into a JSON array of test records.
# Zig test output has one line per test, optionally followed by user
# stdout and a status line:
#   1/5 test_file.test.TEST NAME...OK                     (no user output)
#   2/5 test_file.test.TEST NAME...Hello, World!          (user output)
#   OK                                                     (status on next line)
#   3/5 test_file.test.TEST NAME...FAIL (reason)          (immediate fail)
# Failed tests are followed by stack trace lines until the next test line
# or the summary ("N passed; N skipped; N failed."). Parsing is done in
# two passes: `segment` groups the raw lines into per-test blocks, then
# `classify` turns each block into a single JSON test record.
build_tests_json() {
    printf '%s' "${test_output}" | jq -Rs '
        def test_name: capture("test\\.(?<n>.+)\\.\\.\\.") | .n;
        def user_output: (capture("\\.\\.\\.(?<o>.+)$") | .o) // "";
        def is_test_line: test("[0-9]+/[0-9]+ .*\\.test\\..*\\.\\.\\.");
        def is_summary: startswith("All ") or test("[0-9]+ passed;");
        def is_ok: . == "OK" or endswith("OK");
        def is_fail: startswith("FAIL") or test("\\.\\.\\.(FAIL|expected )");

        # Per-outcome record constructors. These set the leading fields;
        # classify extends records via `.field = ...` in the same order,
        # producing {name, status, message, output}.
        def pass_record(name): {name: name, status: "pass"};
        def fail_record(name): {name: name, status: "fail", message: ""};

        # Pass 1 — segment the flat output into per-test line groups.
        # A new group opens on a test-header line; the current group
        # closes on the next test-header line or on the summary line.
        def segment:
            split("\n")
            | reduce .[] as $line (
                {current: null, groups: []};
                if ($line | is_test_line) then
                    (if .current then .groups += [.current] else . end)
                    | .current = [$line]
                elif ($line | is_summary) then
                    (if .current then .groups += [.current] else . end)
                    | .current = null
                elif .current then
                    .current += [$line]
                else . end
            )
            | if .current then .groups += [.current] else .groups end;

        # Pass 2 — turn one line group into one test record.
        # Three shapes handled:
        #   (a) header ends with OK       → immediate pass, no output
        #   (b) header has FAIL/expected  → immediate fail, message is
        #                                    the stack trace in $rest
        #   (c) otherwise                 → pending: user output on the
        #                                    header, status line lives
        #                                    somewhere in $rest
        def classify:
            .[0] as $header
            | ($header | test_name) as $name
            | ($header | user_output) as $header_output
            | .[1:] as $rest
            | if ($header | endswith("OK")) then
                pass_record($name)
            elif ($header | is_fail) then
                fail_record($name)
                | .message = ($rest | join("\n") | sub("\n+$"; ""))
            else
                ($rest | map(is_ok or is_fail) | index(true)) as $i
                | $rest[:$i] as $extra_output
                | $rest[$i:] as $from_status
                | ($header_output
                   + (if ($extra_output | length) > 0
                      then "\n" + ($extra_output | join("\n"))
                      else "" end)
                   | sub("^\n"; "")) as $output
                | if $from_status[0] | is_ok then
                    pass_record($name) | .output = $output
                else
                    fail_record($name)
                    | .message = ($from_status | join("\n") | sub("\n+$"; ""))
                    | .output = $output
                end
            end;

        segment
        | map(classify)
        | map(
            if .message == "" or .message == null then del(.message) else . end
            | if .output == "" or .output == null then del(.output) else . end
        )
    '
}

# Attach each scraped `test_code` and `task_id` to the matching test record.
#
# The interface requires results in the order the tests appear in the test
# file, so when both sides describe exactly the same tests the test file
# decides the order. If they disagree — a hand-edited test file, a test the
# parser did not recognize — zig's own ordering is kept and only the records
# that do match gain the extra fields. Nothing is invented or dropped.
merge_tests() {
    local tests_json="$1"
    local scraped_json="$2"
    jq -n --argjson tests "${tests_json}" --argjson scraped "${scraped_json}" '
        # Number each element among its same-named siblings, so that tests
        # sharing a name still pair up one-to-one.
        def with_occ:
            [ foreach .[] as $e ({seen: {}};
                  .seen[$e.name] = ((.seen[$e.name] // 0) + 1)
                  | .out = ($e + {occ: .seen[$e.name]});
                  .out) ];
        def key: "\(.name) \(.occ)";

        ($tests | with_occ) as $t
        | ($scraped | with_occ) as $s
        | ($s | INDEX(key)) as $scraped_by_key
        | ($t | INDEX(key)) as $result_by_key
        | (if ($t | map(key) | sort) == ($s | map(key) | sort)
           then $s | map($result_by_key[key])
           else $t
           end)
        | map(
            ($scraped_by_key[key]) as $sc
            | del(.occ)
            | if ($sc.test_code // "") != "" then .test_code = $sc.test_code else . end
            | if $sc.task_id != null then .task_id = $sc.task_id else . end
        )
    '
}

# Write the final results.json. Truncates each test's "output" field to
# 500 chars to bound report size.
assemble_report() {
    local overall="$1"
    local tests_json="$2"
    jq -n --argjson version "${INTERFACE_VERSION}" \
          --arg status "${overall}" --argjson tests "${tests_json}" '
        def trunc: if length > 500 then .[:481] + " [output truncated]" else . end;
        {version: $version, status: $status, tests: ($tests | map(
            if .output then .output |= trunc else . end
        ))}
    ' > "${results_file}"
}

main() {
    parse_args "$@"
    mkdir -p "${output_dir}"
    echo "${slug}: testing..."

    local any_failed=0
    test_output=$(run_zig_test) || any_failed=1

    local tests_json
    tests_json=$(build_tests_json)

    # Report a top-level error only when the run produced no test results at
    # all, which is what a compile error looks like. Matching on the string
    # "error:" instead would misread a runtime stack trace that happens to
    # contain it, hiding every test result behind a single message.
    if (( any_failed )) && [[ "$(jq 'length' <<< "${tests_json}")" -eq 0 ]]; then
        emit_compile_error
    fi

    local overall
    if (( any_failed == 0 )); then
        overall="pass"
    else
        overall="fail"
    fi
    assemble_report "${overall}" "$(merge_tests "${tests_json}" "$(read_test_file)")"

    echo "${slug}: done"
}

main "$@"
