#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# Config / env
# -------------------------
SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

INVENTORY_FILE="${INVENTORY_FILE:-}"     # REQUIRED: GitLab inventory CSV (gitlab-stats output + mapping cols)
BRANCH_VALIDATION_THRESHOLD="${BRANCH_VALIDATION_THRESHOLD:-10}"

# Fallback in case config.sh line is not added yet
POST_MIGRATION_VALIDATION_LOG="${POST_MIGRATION_VALIDATION_LOG:-$LOG_DIR/post-migration-validation}"

RUN_TS="$(date +"%Y%m%d_%H%M%S")"
OUTPUT_DIR="$ARTIFACTS_DIR/post-migration-validation"
LOG_FILE="${POST_MIGRATION_VALIDATION_LOG}-${RUN_TS}.log"
SUMMARY_CSV="${OUTPUT_DIR}/validation-summary_${RUN_TS}.csv"
SUMMARY_MD="${OUTPUT_DIR}/validation-summary_${RUN_TS}.md"

mkdir -p "$LOG_DIR"
mkdir -p "$OUTPUT_DIR"

# Save all stdout+stderr to logfile AND still show on terminal
exec > >(tee -a "$LOG_FILE") 2>&1

# -------------------------
# Pre-flight checks
# -------------------------
command -v gh >/dev/null 2>&1 || { echo "ERROR: GitHub CLI (gh) not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 1; }
[[ -z "${GITLAB_API_ENDPOINT:-}" ]] && echo "[ERROR] GITLAB_API_ENDPOINT not set" && exit 1
[[ -z "${GITLAB_API_PRIVATE_TOKEN:-}" ]] && echo "[ERROR] GITLAB_API_PRIVATE_TOKEN not set" && exit 1

if [[ -z "${INVENTORY_FILE}" ]]; then
  echo "ERROR: INVENTORY_FILE is not set" >&2
  exit 1
fi

if [[ ! -f "${INVENTORY_FILE}" ]]; then
  echo "ERROR: INVENTORY_FILE not found: ${INVENTORY_FILE}" >&2
  exit 1
fi

if [[ -z "${GH_TOKEN:-}" && -n "${GH_PAT:-}" ]]; then
  export GH_TOKEN="${GH_PAT}"
fi

# If neither env token exists, require stored gh auth login
if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
  if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: GitHub CLI not authenticated." >&2
    echo "       Set GH_TOKEN (preferred) or GH_PAT, or run: gh auth login" >&2
    exit 1
  fi
fi

# Sanity check: auth works for API calls
if ! gh api -X GET /user >/dev/null 2>&1; then
  echo "ERROR: GitHub auth check failed (cannot call /user)." >&2
  echo "       Verify GH_TOKEN/GH_PAT/GITHUB_TOKEN scopes and SSO authorization if applicable." >&2
  exit 1
fi

echo "[INFO] Starting GitLab -> GitHub validation using GitLab API and GitHub API"
echo "[INFO] Inventory: ${INVENTORY_FILE}"
echo "[INFO] Output Dir: ${OUTPUT_DIR}"
echo "[INFO] Log File  : ${LOG_FILE}"
echo "[INFO] Summary   : ${SUMMARY_CSV}"

# -------------------------
# Output header
# -------------------------
printf 'github_org,github_repo,gitlab_namespace,gitlab_project,github_repo_exists,exists_status,github_branch_count,branches_status,github_default_branch,default_branch_status,github_commit_count_default_branch,commits_status,github_latest_sha_default_branch,gitlab_branch_count,branch_count_match,gitlab_commit_count,commit_count_match,notes\n' > "${SUMMARY_CSV}"

# -------------------------
# Helpers
# -------------------------
dequote() {
  local field="${1:-}"
  field="${field%$'\r'}"
  field="${field%\"}"
  field="${field#\"}"
  echo "${field}"
}

parse_csv_line() {
  local line="$1"
  local -a fields=()
  local field=""
  local in_quotes=false
  local char
  local i

  for (( i=0; i<${#line}; i++ )); do
    char="${line:$i:1}"

    if [[ "$char" == '"' ]]; then
      if [[ "$in_quotes" == true && $((i + 1)) -lt ${#line} && "${line:$((i + 1)):1}" == '"' ]]; then
        field+='"'
        ((i++))
      else
        if [[ "$in_quotes" == true ]]; then
          in_quotes=false
        else
          in_quotes=true
        fi
      fi
    elif [[ "$char" == ',' && "$in_quotes" == false ]]; then
      fields+=("$field")
      field=""
    else
      field+="$char"
    fi
  done

  fields+=("$field")
  printf '%s\n' "${fields[@]}"
}

find_col() {
  local name="$1"
  for i in "${!cols[@]}"; do
    [[ "$(dequote "${cols[$i]}")" == "$name" ]] && { echo "$i"; return 0; }
  done
  return 1
}

urlencode() {
  jq -rn --arg s "$1" '$s|@uri'
}

array_contains() {
  local seeking="$1"
  shift
  local item

  for item in "$@"; do
    [[ "$item" == "$seeking" ]] && return 0
  done

  return 1
}

gitlab_api_get() {
  local path="$1"

  curl -sS \
    --header "PRIVATE-TOKEN: ${GITLAB_API_PRIVATE_TOKEN}" \
    --header "Accept: application/json" \
    "${GITLAB_API_ENDPOINT}${path}"
}

gitlab_project_id() {
  local gitlab_namespace="$1"
  local gitlab_project="$2"
  local full_path
  local encoded_path

  full_path="${gitlab_namespace}/${gitlab_project}"
  encoded_path="$(urlencode "$full_path")"

  gitlab_api_get "/projects/${encoded_path}" | jq -r '.id // empty'
}

gitlab_branches_json() {
  local project_id="$1"

  local page=1
  local per=100
  local result="[]"
  local chunk
  local count

  while :; do
    chunk="$(gitlab_api_get "/projects/${project_id}/repository/branches?per_page=${per}&page=${page}")"
    count="$(printf '%s' "$chunk" | jq 'length')"

    result="$(jq -s '.[0] + .[1]' <(printf '%s' "$result") <(printf '%s' "$chunk"))"

    if [[ "$count" -lt "$per" ]]; then
      break
    fi

    page=$((page + 1))
  done

  printf '%s' "$result"
}

gitlab_commit_count() {
  local project_id="$1"
  local branch="$2"

  local branch_q
  local page=1
  local per=100
  local total=0
  local chunk
  local count

  branch_q="$(urlencode "$branch")"

  while :; do
    chunk="$(gitlab_api_get "/projects/${project_id}/repository/commits?ref_name=${branch_q}&per_page=${per}&page=${page}")"
    count="$(printf '%s' "$chunk" | jq 'length')"

    total=$((total + count))

    if [[ "$count" -lt "$per" ]]; then
      break
    fi

    page=$((page + 1))
  done

  echo "$total"
}

gitlab_latest_sha() {
  local project_id="$1"
  local branch="$2"
  local branch_q

  branch_q="$(urlencode "$branch")"

  gitlab_api_get "/projects/${project_id}/repository/commits?ref_name=${branch_q}&per_page=1" \
    | jq -r '.[0].id // empty'
}

gh_commit_count() {
  local github_org="$1"
  local github_repo="$2"
  local branch="$3"
  local branch_q

  branch_q="$(urlencode "$branch")"

  gh api "/repos/${github_org}/${github_repo}/commits?sha=${branch_q}&per_page=100" --paginate \
    | jq -s 'map(length) | add // 0'
}

gh_latest_sha() {
  local github_org="$1"
  local github_repo="$2"
  local branch="$3"
  local branch_q

  branch_q="$(urlencode "$branch")"

  gh api "/repos/${github_org}/${github_repo}/commits?sha=${branch_q}&per_page=1" \
    --jq '.[0].sha // empty'
}

# -------------------------
# Read header / validate headers
# -------------------------
header="$(head -n 1 "${INVENTORY_FILE}" | tr -d $'\r')"
readarray -t cols < <(parse_csv_line "$header")

array_of_err_messages=()

NS_IDX="$(find_col "Namespace")" || array_of_err_messages+=("[ERROR] Missing required header: Namespace")
PR_IDX="$(find_col "Project")" || array_of_err_messages+=("[ERROR] Missing required header: Project")
BC_IDX="$(find_col "Branch_Count")" || array_of_err_messages+=("[ERROR] Missing required header: Branch_Count")
CC_IDX="$(find_col "Commit_Count")" || array_of_err_messages+=("[ERROR] Missing required header: Commit_Count")
GH_ORG_IDX="$(find_col "github_org")" || array_of_err_messages+=("[ERROR] Missing required header: github_org")
GH_REPO_IDX="$(find_col "github_repo")" || array_of_err_messages+=("[ERROR] Missing required header: github_repo")

if ((${#array_of_err_messages[@]})); then
  printf '%s\n' "${array_of_err_messages[@]}" >&2
  echo "[ERROR] Header must contain 'Namespace', 'Project', 'Branch_Count', 'Commit_Count', 'github_org', 'github_repo'" >&2
  exit 1
fi

# -------------------------
# Summary counters
# -------------------------
total=0
skipped=0
ok=0
fail=0

# -------------------------
# Iterate inventory rows
# -------------------------
while IFS= read -r raw; do
  line="$(echo "$raw" | tr -d $'\r')"
  [[ -z "$line" ]] && continue

  total=$((total + 1))

  readarray -t flds < <(parse_csv_line "$line")

  gitlab_namespace="$(dequote "${flds[$NS_IDX]:-}")"
  gitlab_project="$(dequote "${flds[$PR_IDX]:-}")"
  gitlab_branch_count="$(dequote "${flds[$BC_IDX]:-}")"
  gitlab_commit_count="$(dequote "${flds[$CC_IDX]:-}")"

  github_org="$(dequote "${flds[$GH_ORG_IDX]:-}")"
  github_repo_from_inv="$(dequote "${flds[$GH_REPO_IDX]:-}")"

  # Normalize empties
  [[ -z "${gitlab_branch_count}" ]] && gitlab_branch_count=0
  [[ -z "${gitlab_commit_count}" ]] && gitlab_commit_count=0

  # Guard
  if [[ -z "$gitlab_namespace" || -z "$gitlab_project" || -z "$github_org" || -z "$github_repo_from_inv" ]]; then
    echo "[WARN] Row: ${total} - Skipping due to missing Namespace/Project/github_org/github_repo"
    skipped=$((skipped + 1))
    continue
  fi

  # Target GitHub repo name is taken from inventory github_repo column
  github_repo="${github_repo_from_inv}"

  echo "[$(date)] ▶ Processing: GitLab ${gitlab_namespace}/${gitlab_project} -> GitHub ${github_org}/${github_repo}"

  # Snapshot
  gh repo view "${github_org}/${github_repo}" --json createdAt,diskUsage,defaultBranchRef,isPrivate \
    > "${OUTPUT_DIR}/validation-${github_repo}.json" 2>/dev/null || true

  # Existence
  if gh api -X GET "/repos/${github_org}/${github_repo}" >/dev/null 2>&1; then
    github_repo_exists=true
    exists_status="✅"
  else
    github_repo_exists=false
    exists_status="❌"
  fi

  notes=""
  github_branch_count=0
  github_default_branch=""
  github_commit_count_default_branch=0
  github_latest_sha_default_branch=""
  gitlab_branch_count_api=""
  gitlab_default_branch=""
  branches_status="❌"
  default_branch_status="❌"
  commits_status="❌"
  branch_count_match="❌"
  commit_count_match="❌"
  latest_sha_match="❌"

  if [[ "${github_repo_exists}" == true ]]; then
    # Resolve GitLab project ID
    gitlab_project_id_value="$(gitlab_project_id "$gitlab_namespace" "$gitlab_project")"

    if [[ -z "$gitlab_project_id_value" || "$gitlab_project_id_value" == "null" ]]; then
      notes="GitLab project not found or no access"
      echo "[$(date)]   ❌ GitLab project not found or no access: ${gitlab_namespace}/${gitlab_project}"
    else
      # GitLab branches
      gitlab_branches_api_json="$(gitlab_branches_json "$gitlab_project_id_value")"

      mapfile -t gitlab_branch_array < <(printf '%s' "$gitlab_branches_api_json" | jq -r '.[].name')
      gitlab_branch_count_api="${#gitlab_branch_array[@]}"
      gitlab_default_branch="$(printf '%s' "$gitlab_branches_api_json" | jq -r '.[] | select(.default == true) | .name' | head -n 1)"

      # GitHub branches
      github_branches_json="$(gh api "/repos/${github_org}/${github_repo}/branches?per_page=100" --paginate \
        | jq -r '.[].name' \
        | jq -R -s -c 'split("\n") | map(select(length>0))')"

      mapfile -t github_branch_array < <(printf '%s' "$github_branches_json" | jq -r '.[]')
      github_branch_count="${#github_branch_array[@]}"
      branches_status=$([[ "$github_branch_count" -gt 0 ]] && echo "✅" || echo "❌")

      # GitHub default branch
      github_default_branch="$(gh api "/repos/${github_org}/${github_repo}" | jq -r '.default_branch // ""')"

      echo "[$(date)]   GitLab Default Branch: ${gitlab_default_branch:-'(none)'}"
      echo "[$(date)]   GitHub Default Branch: ${github_default_branch:-'(none)'}"

      if [[ -n "$gitlab_default_branch" && -n "$github_default_branch" && "$gitlab_default_branch" == "$github_default_branch" ]]; then
        default_branch_status="✅"
      else
        default_branch_status="❌"
        notes="${notes:+$notes; }Default branch mismatch: GitLab=${gitlab_default_branch:-'(none)'}; GitHub=${github_default_branch:-'(none)'}"
      fi

      # Compare branch count using API values
      branch_count_match=$([[ "$github_branch_count" -eq "$gitlab_branch_count_api" ]] && echo "✅" || echo "❌")

      # Compare branch names
      missing_in_github=()
      missing_in_gitlab=()

      for gl_branch in "${gitlab_branch_array[@]}"; do
        if ! array_contains "$gl_branch" "${github_branch_array[@]}"; then
          missing_in_github+=("$gl_branch")
        fi
      done

      for gh_branch in "${github_branch_array[@]}"; do
        if ! array_contains "$gh_branch" "${gitlab_branch_array[@]}"; then
          missing_in_gitlab+=("$gh_branch")
        fi
      done

      if [[ "${#missing_in_github[@]}" -gt 0 ]]; then
        echo "[$(date)]   Branches missing in GitHub: ${missing_in_github[*]}"
        notes="${notes:+$notes; }Branches missing in GitHub: ${missing_in_github[*]}"
        branch_count_match="❌"
      fi

      if [[ "${#missing_in_gitlab[@]}" -gt 0 ]]; then
        echo "[$(date)]   Branches missing in GitLab: ${missing_in_gitlab[*]}"
        notes="${notes:+$notes; }Branches missing in GitLab: ${missing_in_gitlab[*]}"
        branch_count_match="❌"
      fi

      # Decide branches to validate
      branches_to_validate=()
      max_branch_count="$gitlab_branch_count_api"

      if (( github_branch_count > max_branch_count )); then
        max_branch_count="$github_branch_count"
      fi

      commit_count_match="✅"
      latest_sha_match="✅"

      if (( max_branch_count > BRANCH_VALIDATION_THRESHOLD )); then
        if [[ -n "$gitlab_default_branch" ]]; then
          branches_to_validate=("$gitlab_default_branch")
          echo "[$(date)]   Branch count is above ${BRANCH_VALIDATION_THRESHOLD}. Validating default branch only: ${gitlab_default_branch}"
        else
          echo "[$(date)]   ⚠️ GitLab default branch not found. Cannot validate default branch commits."
          notes="${notes:+$notes; }GitLab default branch not found"
          commit_count_match="❌"
          latest_sha_match="❌"
        fi
      else
        branches_to_validate=("${gitlab_branch_array[@]}")
        echo "[$(date)]   Branch count is ${BRANCH_VALIDATION_THRESHOLD} or below. Validating all branches."
      fi

      for branch_name in "${branches_to_validate[@]}"; do
        [[ -z "$branch_name" ]] && continue

        if ! array_contains "$branch_name" "${github_branch_array[@]}"; then
          echo "[$(date)]   Branch '${branch_name}': ❌ Exists in GitLab but missing in GitHub. Skipping commit/SHA validation."
          commit_count_match="❌"
          latest_sha_match="❌"
          continue
        fi

        gitlab_commit_count_value="$(gitlab_commit_count "$gitlab_project_id_value" "$branch_name")"
        github_commit_count_value="$(gh_commit_count "$github_org" "$github_repo" "$branch_name")"

        gitlab_latest_sha_value="$(gitlab_latest_sha "$gitlab_project_id_value" "$branch_name")"
        github_latest_sha_value="$(gh_latest_sha "$github_org" "$github_repo" "$branch_name")"

        branch_commit_match=$([[ "$gitlab_commit_count_value" -eq "$github_commit_count_value" ]] && echo "✅" || echo "❌")
        branch_sha_match=$([[ -n "$gitlab_latest_sha_value" && -n "$github_latest_sha_value" && "$gitlab_latest_sha_value" == "$github_latest_sha_value" ]] && echo "✅" || echo "❌")

        echo "[$(date)]   Branch '${branch_name}': GitLab Commits=${gitlab_commit_count_value} | GitHub Commits=${github_commit_count_value} | ${branch_commit_match}"
        echo "[$(date)]   Branch '${branch_name}': GitLab SHA=${gitlab_latest_sha_value} | GitHub SHA=${github_latest_sha_value} | ${branch_sha_match}"

        if [[ "$branch_commit_match" == "❌" ]]; then
          commit_count_match="❌"
        fi

        if [[ "$branch_sha_match" == "❌" ]]; then
          latest_sha_match="❌"
        fi

        if [[ "$branch_name" == "$gitlab_default_branch" ]]; then
            github_commit_count_default_branch="$github_commit_count_value"
            github_latest_sha_default_branch="$github_latest_sha_value"
            gitlab_commit_count="$gitlab_commit_count_value"
        fi
      done

      commits_status=$([[ "$commit_count_match" == "✅" ]] && echo "✅" || echo "❌")

      if [[ "$latest_sha_match" == "❌" ]]; then
        notes="${notes:+$notes; }Latest SHA mismatch detected"
      fi
    fi
  else
    notes="GitHub repository not found or no access"
  fi

  

  # Processing counters
  if [[ "$github_repo_exists" == true && "$branch_count_match" == "✅" && "$default_branch_status" == "✅" && "$commit_count_match" == "✅" && "$latest_sha_match" == "✅" ]]; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi

  # Logs
  echo "[$(date)]   Exists: ${exists_status} | Branches: ${github_branch_count} ${branches_status}"
  echo "[$(date)]   Default Branch: ${github_default_branch:-'(none)'} ${default_branch_status}"
  echo "[$(date)]   Commits (Default Branch): ${github_commit_count_default_branch} ${commits_status}"
  [[ -n "$github_latest_sha_default_branch" ]] && echo "[$(date)]   Latest SHA (Default Branch): ${github_latest_sha_default_branch}"
  echo "[$(date)]   Match: Branch ${branch_count_match} | Commit ${commit_count_match}"

  # Write CSV row
  gitlab_branch_count_output="${gitlab_branch_count_api:-$gitlab_branch_count}"
  printf '%s\n' \
    "${github_org},${github_repo},${gitlab_namespace},${gitlab_project},${github_repo_exists},${exists_status},${github_branch_count},${branches_status},${github_default_branch},${default_branch_status},${github_commit_count_default_branch},${commits_status},${github_latest_sha_default_branch},${gitlab_branch_count_output},${branch_count_match},${gitlab_commit_count},${commit_count_match},${notes}" \
    >> "${SUMMARY_CSV}"

done < <(tail -n +2 "${INVENTORY_FILE}")

echo "[INFO] Validation completed."
echo "[INFO] Artifacts: ${LOG_FILE}, ${SUMMARY_CSV}"

# -------------------------
# Markdown summary
# -------------------------
{
  echo "# Post-Migration Validation Summary"
  echo
  echo "| GitHub Repo | GitLab Project | Exists | GH Branches | GL Branches | Branch Match | GH Default Branch | GH Commits (Default) | GL Commits | Commit Match | Notes |"
  echo "|---|---|---|---:|---:|---|---|---:|---:|---|---|"

  tail -n +2 "${SUMMARY_CSV}" | while IFS=',' read -r org repo gl_ns gl_proj repo_exists exists_status bc_gh branches_status def_branch default_branch_status cc_gh commits_status sha gl_bc bc_match gl_cc cc_match notes; do
    github_repo_fmt="${org}/${repo}"
    gitlab_proj_fmt="${gl_ns}/${gl_proj}"
    notes_esc="${notes//|/\\|}"
    echo "| ${github_repo_fmt} | ${gitlab_proj_fmt} | ${exists_status} | ${bc_gh} | ${gl_bc} | ${bc_match} | ${def_branch} | ${cc_gh} | ${gl_cc} | ${cc_match} | ${notes_esc} |"
  done
} > "${SUMMARY_MD}"

echo "[INFO] Markdown summary written: ${SUMMARY_MD}"

# -------------------------
# Final summary table
# -------------------------
echo
echo "Summary:"
echo "  Total   : $total"
echo "  Skipped : $skipped"
echo "  Success : $ok"
echo "  Failed  : $fail"
echo ""
echo "Validation CSV : ${SUMMARY_CSV}"
echo "Validation MD  : ${SUMMARY_MD}"
echo "Detailed logs written to ${LOG_FILE}"
echo

echo "===================== FINAL SUMMARY ====================="
{
    echo "GitHub Repo|GitLab Project|Exists|Branches|Default Branch|Branch Match|Commit Match"

    tail -n +2 "${SUMMARY_CSV}" | while IFS=',' read -r org repo gl_ns gl_proj repo_exists exists_status bc_gh branches_status def_branch default_branch_status cc_gh commits_status sha gl_bc bc_match gl_cc cc_match notes
    do
        github_repo_fmt="${org}/${repo}"
        gitlab_proj_fmt="${gl_ns}/${gl_proj}"

        # Truncate only long columns
        [[ ${#github_repo_fmt} -gt 45 ]] && github_repo_fmt="${github_repo_fmt:0:42}..."
        [[ ${#gitlab_proj_fmt} -gt 40 ]] && gitlab_proj_fmt="${gitlab_proj_fmt:0:37}..."

        printf "%s|%s|%s|%s|%s|%s|%s\n" \
            "$github_repo_fmt" \
            "$gitlab_proj_fmt" \
            "$exists_status" \
            "$bc_gh" \
            "$def_branch" \
            "$bc_match" \
            "$cc_match"
    done
} | column -t -s '|'

echo "========================================================="
