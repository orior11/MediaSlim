#!/usr/bin/env bash
# Turns build.log into GitHub annotations and publishes a compact copy on the branch
# ci-logs/<job>, so build results can be read through git and the REST API without
# downloading artifacts.
set -u
JOB="$1"
LOG=build.log
[ -f "$LOG" ] || { echo "no $LOG"; exit 0; }

# Errors, failing tests and accessibility findings, de-duplicated.
grep -E "error:|: error|Test Case .* failed|failed \(|ACCESSIBILITY|XCTAssert|Fatal error|\*\* (BUILD|TEST) (FAILED|SUCCEEDED)|Test run with|✘|✔ Test run" "$LOG" \
  | sed "s|$GITHUB_WORKSPACE/||g" | awk '!seen[$0]++' > summary.txt || true

count=0
while IFS= read -r line && [ $count -lt 45 ]; do
  if [[ "$line" =~ ^([^:]+\.swift):([0-9]+):([0-9]+):\ error:\ (.*)$ ]]; then
    echo "::error file=${BASH_REMATCH[1]},line=${BASH_REMATCH[2]},col=${BASH_REMATCH[3]}::${BASH_REMATCH[4]}"
    count=$((count + 1))
  elif [[ "$line" == *"error"* || "$line" == *"failed"* || "$line" == *"ACCESSIBILITY"* || "$line" == *"✘"* ]]; then
    echo "::error::${line:0:900}"
    count=$((count + 1))
  fi
done < summary.txt

# Publish summary and the full (compressed) log to an orphan branch.
dir="$RUNNER_TEMP/ci-logs"
rm -rf "$dir" && mkdir -p "$dir"
cp summary.txt "$dir/summary.txt"
gzip -c "$LOG" > "$dir/build.log.gz"
echo "$GITHUB_SHA" > "$dir/commit.txt"
cd "$dir"
git init -q
git checkout -q -b "ci-logs/$JOB"
git add -A
git -c user.name="ci" -c user.email="ci@users.noreply.github.com" commit -q -m "CI logs for $GITHUB_SHA ($JOB)"
git push -q -f "https://x-access-token:${TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:refs/heads/ci-logs/$JOB" || echo "could not publish logs"
