#!/usr/bin/env bash
set -euo pipefail

# --- Config ---> # Set script base path and load env from config.sh.
SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Read GitHub API URL
GITHUB_API_URL="${GITHUB_API_URL:-}"

if [[ -n "$GITHUB_API_URL" ]]; then
    echo "[INFO] Migration destination: GitHub Enterprise Cloud Data Residency"
    echo "[INFO] Target API URL: $GITHUB_API_URL"

    GH_SERVER_URL="$(echo "$GITHUB_API_URL" | sed 's#api\.##')"
    echo "[INFO] Target Server URL: $GH_SERVER_URL"
else
    GITHUB_API_URL="https://api.github.com"

    echo "[INFO] Migration destination: GitHub Enterprise Cloud"
    echo "[INFO] Target API URL: $GITHUB_API_URL"

    GH_SERVER_URL="https://github.com"
    echo "[INFO] Target Server URL: $GH_SERVER_URL"
fi

export GH_API_URL="$GITHUB_API_URL"
export GITHUB_API_URL
export GH_SERVER_URL

STORAGE_TYPE="${STORAGE_TYPE:-GITHUB}"

case "$STORAGE_TYPE" in
    GITHUB)
        UPLOAD_SCRIPT="$GITHUB_UPLOAD_SCRIPT"
    ;;
    AZURE)
        if [[ -z "${AZ_CONTAINER:-}" ]] || [[ -z "${AZURE_STORAGE_CONNECTION_STRING:-}" ]]; then
            echo "[ERROR] STORAGE_TYPE=AZURE but AZ_CONTAINER or AZURE_STORAGE_CONNECTION_STRING is not set"
            exit 1
        fi
        UPLOAD_SCRIPT="$AZURE_UPLOAD_SCRIPT"
    ;;
    AWS)
        if [[ -z "${AWS_BUCKET_NAME:-}" ]]; then
            echo "[ERROR] STORAGE_TYPE=AWS but AWS_BUCKET_NAME is not set"
            exit 1
        fi
        UPLOAD_SCRIPT="$AWS_UPLOAD_SCRIPT"
    ;;
    *)
        echo "[ERROR] Unsupported STORAGE_TYPE: $STORAGE_TYPE"
        echo "[ERROR] Valid values: GITHUB | AZURE | AWS"
        exit 1
    ;;
esac


RUN_TS="$(date +"%Y%m%d_%H%M%S")"
LOG_FILE="${UPLOAD_ARCHIVE_LOG}_${RUN_TS}.log"
mkdir -p "$LOG_DIR"

# Save all stdout+stderr to logfile AND still show on terminal
exec > >(tee -a "$LOG_FILE") 2>&1

# --- Folders ---> # Ensure artifacts folders exist (create if missing).
mkdir -p "$ARTIFACTS_DIR"

# --- Output list file ---> # Timestamp to make output filenames unique per run.
PRESIGNED_CSV="$ARTIFACTS_DIR/presigned-urls_${RUN_TS}.csv"
echo 'gitlab_group,gitlab_project,archive_file_path,archive_file_name,presigned_url,github_org,github_repo,gh_repo_visibility' > "$PRESIGNED_CSV"

# --- Basic checks ---
if [[ ! -s "$ARCHIVE_LIST" ]]; then
echo "[ERROR] Archive list missing/empty: $ARCHIVE_LIST"
exit 1
else
echo "[INFO] Using Archive file: $ARCHIVE_LIST"
fi

if [[ ! -x "$UPLOAD_SCRIPT" ]]; then
echo "[ERROR] Upload script not found/executable: $UPLOAD_SCRIPT"
exit 1
else
echo "[INFO] Using Upload script: $UPLOAD_SCRIPT"
fi


# strip .tar.gz from migration archive as expected by upload script
derive_repo() {
local name="$1"; local outputname
outputname="$(basename -- "$name")"
outputname="${outputname%.tar.gz}"
echo "$outputname"
}

# Extract pre-signed url from upload script output
extract_url() {
awk -F 'Archive Upload URL[[:space:]]*:' '
    BEGIN { IGNORECASE=1 }
    NF>1 {
      u=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", u)  # trim
      # if the uploader prints extra text after the URL, keep only the first token
      split(u, a, /[[:space:]]+/)
      print a[1]
      exit
    }
  ' <<<"$1"
} # Extract only the URL after "Archive Upload URL :" and Trims spaces and removes any extra text printed after the URL


# Remove leading/trailing quotes
dequote() {
  local field="$1"
  field="${field%\"}"
  field="${field#\"}"
  echo "$field"
}

# Parse CSV file
parse_csv_line() {
    local line="$1"
    local -a fields=()
    local field=""
    local in_quotes=false
    local char
    local i

    for ((i=0; i<${#line}; i++)); do
        char="${line:$i:1}"

        if [[ "$char" == '"' ]]; then
            if [[ "$in_quotes" == true ]]; then
                if [[ "${line:$((i+1)):1}" == '"' ]]; then
                    field+="$char"
                    ((i++))
                else
                    in_quotes=false
                fi
            else
                in_quotes=true
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

# --- Read csv file containing list of archive file and its path
header="$(head -n 1 "$ARCHIVE_LIST" | tr -d '\r')"
#IFS=',' read -r -a cols <<< "$header"
readarray -t cols < <(parse_csv_line "$header")

find_col() {
  # Finds the column index in 'cols[]' whose value exactly matches $1.
  # Loops through header array; if match found, prints index (0,1,2…) and returns 0, else returns 1.
  # Example: cols[0]="gitlab_group" → find_col gitlab_group → prints 0
  # Example: cols[2]="archive_file" → find_col archive_file → prints 2
  local name="$1"
  for i in "${!cols[@]}"; do
    [[ "$(dequote "${cols[$i]}")" == "$name" ]] && { echo "$i"; return 0; }
  done
  return 1
}


# --- Validate headers ---
array_of_err_messages=()

GL_GRP_IDX="$(find_col 'gitlab_group')" || array_of_err_messages+=("[ERROR] Missing required header: gitlab_group")
GL_PRJ_IDX="$(find_col 'gitlab_project')" || array_of_err_messages+=("[ERROR] Missing required header: gitlab_project")
ARC_PATH_IDX="$(find_col 'archive_file')" || array_of_err_messages+=("[ERROR] Missing required header: archive_file")
GH_ORG_IDX="$(find_col "github_org")" || array_of_err_messages+=("[ERROR] Missing required header: github_org")
GH_REPO_IDX="$(find_col "github_repo")" || array_of_err_messages+=("[ERROR] Missing required header: github_repo")
GH_REPO_VISIBILITY_IDX="$(find_col "gh_repo_visibility")" || array_of_err_messages+=("[ERROR] Missing required header: gh_repo_visibility")

if ((${#array_of_err_messages[@]})); then
  {
    printf '%s\n' "${array_of_err_messages[@]}"
    echo "[ERROR] Header must contain 'gitlab_group', 'gitlab_project', 'archive_file', 'github_org', 'github_repo' "
  } >&2
  exit 1
fi

# --- Upload script execution
total=0; skipped=0; ok=0; fail=0

# Iterate each row in archive csv file and run upload for migration archive
while IFS= read -r raw; do
  line="$(echo "$raw" | tr -d '\r')"
  #IFS=',' read -r -a flds <<< "$line"
  readarray -t flds < <(parse_csv_line "$line")

  ns="$(dequote "${flds[$GL_GRP_IDX]:-}")"
  pr="$(dequote "${flds[$GL_PRJ_IDX]:-}")"
  archive_path="$(dequote "${flds[$ARC_PATH_IDX]:-}")"
  github_org="$(dequote "${flds[$GH_ORG_IDX]:-}")"
  github_repo="$(dequote "${flds[$GH_REPO_IDX]:-}")"
  gh_repo_visibility="$(dequote "${flds[$GH_REPO_VISIBILITY_IDX]:-}")"

  if [[ "$gh_repo_visibility" != "private" && "$gh_repo_visibility" != "public" && "$gh_repo_visibility" != "internal" ]]; then
    echo "[ERROR] Invalid gh_repo_visibility: '$gh_repo_visibility'"
    echo "[ERROR] Valid values: private, public, internal"
    fail=$((fail + 1))
    continue
  fi

  total=$((total + 1))

  [[ -z "$ns" || -z "$pr" || -z "$archive_path" || -z "$github_org" || -z "$github_repo"  || -z "$gh_repo_visibility" ]] && skipped=$((skipped+1)) && echo "[WARN] Row: ${total} - Skipping due to missing headers: gitlab_group='${ns}' gitlab_project='${pr}' archive_path='${archive_path}' github_org='${github_org}' github_repo='${github_repo}' gh_repo_visibility='${gh_repo_visibility}'" && continue   # Skip rows that don’t have both Namespace, Project, GitHub Org and GitHub repo

  if [[ ! -f "$archive_path" ]]; then
    echo "[ERROR] Missing: $archive_path"
    fail=$((fail + 1))
    continue
  fi

  TARGET_GH_REPO="$(derive_repo "$archive_path")"
  GH_ORG=$github_org
  GH_REPO=$github_repo
  export GH_ORG GH_REPO GH_PAT TARGET_GH_REPO

  echo "[INFO] Uploading Archive: ${TARGET_GH_REPO}.tar.gz"

  # Upload script expects GITHUB_ENV variable and it expects migration archive to be present at /
  if [[ ! -f "$GITHUB_ENV" ]]; then
    touch "$GITHUB_ENV"
  fi
  export GITHUB_ENV

  export TARGET_ARCHIVE_PATH="$archive_path"
  # Running upload script
  script_status_check=0
  # out="$("$UPLOAD_SCRIPT")" 2>&1 || script_status_check=$?
  bash -x "$UPLOAD_SCRIPT"

  if (( $script_status_check == 0 )); then
    url="$(extract_url "$out")"
    if [[ -n "$url" ]]; then
      echo "\"$ns\",\"$pr\",\"$archive_path\",\"$TARGET_GH_REPO\",\"$url\",\"$github_org\",\"$github_repo\",\"$gh_repo_visibility\"" >> "$PRESIGNED_CSV"
      ok=$((ok + 1))
    else
      echo "[ERROR] Cannot detect pre-signed url in output for: $TARGET_GH_REPO"
      echo "- Output of $UPLOAD_SCRIPT script:
      $out" >>"$LOG_FILE" 2>&1
      fail=$((fail + 1))
    fi
  else
    echo "[ERROR] Upload FAILED: $archive_path"
    echo "- Output of $UPLOAD_SCRIPT script:
    $out" >>"$LOG_FILE" 2>&1
    fail=$((fail + 1))
  fi

done < <(tail -n +2 "$ARCHIVE_LIST")

# --- Summary ---
echo ""
echo "Summary:"
echo "  Total   : $total"
echo "  Skipped : $skipped"
echo "  Success : $ok"
echo "  Failed  : $fail"

if [[ "$ok" -eq 0 ]]; then
    echo "[ERROR] No migration archives were uploaded successfully."
    exit 1
fi

echo ""
echo "For successful upload, presigned url details written to CSV: $PRESIGNED_CSV"
echo "Detailed logs written to $LOG_FILE"

echo
echo "Run the below command to set env variable before running next script"
echo "export UPLOADED_ARCHIVES=$PRESIGNED_CSV"
