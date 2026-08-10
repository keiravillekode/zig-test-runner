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

awk_script="$(dirname "$0")/process_results.awk"

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
    jq -n --arg message "${test_output}" \
        '{version: 3, status: "error", message: $message}' > "${results_file}"
    echo "${slug}: done"
    exit 0
}

# Parse Zig's per-test output into a JSON array of test records. The awk
# script emits one record per line; jq slurps them and truncates each test's
# "output" field to 500 chars to bound report size.
build_tests_json() {
    printf '%s' "${test_output}" \
        | gawk -f "${awk_script}" -v test_file="${solution_dir}/${test_file}" \
        | jq -s '
            def trunc: if length > 500 then .[:481] + " [output truncated]" else . end;
            map(if .output then .output |= trunc else . end)
        '
}

# Write the final results.json.
assemble_report() {
    local overall="$1"
    local tests_json="$2"
    jq -n --arg status "${overall}" --argjson tests "${tests_json}" \
        '{version: 3, status: $status, tests: $tests}' > "${results_file}"
}

main() {
    parse_args "$@"
    mkdir -p "${output_dir}"
    echo "${slug}: testing..."

    local any_failed=0
    test_output=$(run_zig_test) || any_failed=1

    local tests_json overall
    tests_json=$(build_tests_json)

    # A compile error is a failed run that produced no test results at all.
    # Testing the output for "error:" instead would misread a stack trace, or
    # a student's own debug output, as a compile error and hide every result.
    if (( any_failed )) && [[ "${tests_json}" == "[]" ]]; then
        emit_compile_error
    fi

    if (( any_failed == 0 )); then
        overall="pass"
    else
        overall="fail"
    fi
    assemble_report "${overall}" "${tests_json}"

    echo "${slug}: done"
}

main "$@"
