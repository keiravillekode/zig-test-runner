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

# Locate the parser binary. When installed via Docker it lives next to this
# script; when running from a checkout it's also in bin/ after a local build.
script_dir=$(dirname "$(realpath "$0")")
parser="${script_dir}/exercism-parser"

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

# Hand the raw output to the Zig parser, which writes results.json.
printf '%s' "${test_output}" | "${parser}" \
    --exit-code "${exit_code}" \
    --output "${results_file}"

echo "${slug}: done"
