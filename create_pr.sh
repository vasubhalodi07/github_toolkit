#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load local environment variables (API keys, models, tokens) if present
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

# ANSI Color Codes
BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
MAGENTA="\033[0;35m"
RED="\033[0;31m"
DIM="\033[2m"
RESET="\033[0m"

echo ""
echo -e "${BOLD}==========================================${RESET}"
echo -e "${BOLD} 🚀 Create Pull Request Script (GitHub CLI)${RESET}"
echo -e "${BOLD}==========================================${RESET}"
echo ""

# 1. Check GitHub CLI ('gh') & authentication
if ! command -v gh &> /dev/null; then
  echo -e "${RED}❌ Error: GitHub CLI ('gh') is not installed or not in PATH.${RESET}"
  echo "Please install it or authenticate via 'gh auth login'."
  exit 1
fi

GH_ERR_FILE=$(mktemp)
CURRENT_GH_USER=$(gh api user --jq .login 2>"$GH_ERR_FILE" || true)

# Fallback 1: Extract username from 'gh auth status'
if [ -z "$CURRENT_GH_USER" ]; then
  CURRENT_GH_USER=$(gh auth status 2>&1 | grep -oE "account [a-zA-Z0-9_-]+" | awk '{print $2}' | head -n 1 || true)
fi

# Fallback 2: Check if gh config has user
if [ -z "$CURRENT_GH_USER" ]; then
  CURRENT_GH_USER=$(gh api user -q '.login' 2>/dev/null || true)
fi

if [ -z "$CURRENT_GH_USER" ]; then
  echo -e "${RED}❌ Error: Not logged in to GitHub CLI.${RESET}"
  if [ -s "$GH_ERR_FILE" ]; then
    echo -e "${YELLOW}API Error Details:${RESET}"
    cat "$GH_ERR_FILE"
  fi
  rm -f "$GH_ERR_FILE"
  echo ""
  echo "Please run 'gh auth login' to authenticate."
  exit 1
fi
rm -f "$GH_ERR_FILE"

echo -e "👤 Authenticated as : ${CYAN}${BOLD}@$CURRENT_GH_USER${RESET}"

# Fetch organizations
ORGS=()
while IFS= read -r org; do
  [ -n "$org" ] && ORGS+=("$org")
done < <(gh api user/orgs --jq '.[].login' 2>/dev/null || true)

# 2. Collect all repositories directly from GitHub CLI
echo -e "📦 Discovering repositories from GitHub..."
ALL_REPOS=()

# Personal repos
while IFS= read -r r; do
  [ -n "$r" ] && ALL_REPOS+=("$r")
done < <(gh repo list "$CURRENT_GH_USER" --limit 300 --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true)

# Organization repos
for org in "${ORGS[@]}"; do
  while IFS= read -r r; do
    [ -n "$r" ] && ALL_REPOS+=("$r")
  done < <(gh repo list "$org" --limit 300 --json nameWithOwner --jq '.[].nameWithOwner' 2>/dev/null || true)
done

# Deduplicate
REPOS=()
for r in "${ALL_REPOS[@]}"; do
  found=0
  for u in "${REPOS[@]}"; do
    if [ "$u" = "$r" ]; then
      found=1
      break
    fi
  done
  [ $found -eq 0 ] && REPOS+=("$r")
done

if [ ${#REPOS[@]} -eq 0 ]; then
  echo -e "${RED}❌ Error: No repositories found on GitHub.${RESET}"
  exit 1
fi

# 3. Project / Repository Selection
echo ""
echo -e "${BOLD}📁 Step 1: Select Repository${RESET}"
echo "------------------------------------------"
for i in "${!REPOS[@]}"; do
  num=$((i + 1))
  slug="${REPOS[$i]}"
  owner="${slug%%/*}"
  repo_name="${slug##*/}"
  if [ "$owner" = "$CURRENT_GH_USER" ]; then
    printf "  [%2d] %-30s ${DIM}(personal)${RESET}\n" "$num" "$slug"
  else
    printf "  [%2d] %-30s ${MAGENTA}(org: %s)${RESET}\n" "$num" "$slug" "$owner"
  fi
done

echo ""
read -r -p "Enter repository number (1-${#REPOS[@]}) or type repo name: " SELECTED_INPUT

REPO_FULL_NAME=""
if [[ "$SELECTED_INPUT" =~ ^[0-9]+$ ]] && [ "$SELECTED_INPUT" -ge 1 ] && [ "$SELECTED_INPUT" -le "${#REPOS[@]}" ]; then
  REPO_FULL_NAME="${REPOS[$((SELECTED_INPUT - 1))]}"
elif [ -n "$SELECTED_INPUT" ]; then
  # Try exact or partial match
  for r in "${REPOS[@]}"; do
    if [ "$r" = "$SELECTED_INPUT" ] || [ "${r##*/}" = "$SELECTED_INPUT" ]; then
      REPO_FULL_NAME="$r"
      break
    fi
  done
  if [ -z "$REPO_FULL_NAME" ]; then
    for r in "${REPOS[@]}"; do
      if [[ "$r" == *"$SELECTED_INPUT"* ]]; then
        REPO_FULL_NAME="$r"
        break
      fi
    done
  fi
fi

if [ -z "$REPO_FULL_NAME" ]; then
  echo -e "${RED}❌ Error: Invalid repository selection.${RESET}"
  exit 1
fi

echo -e "✅ Target Repository : ${CYAN}${BOLD}$REPO_FULL_NAME${RESET}"

# 4. Fetch Remote Branches directly from GitHub
echo ""
echo -e "${BOLD}🌿 Step 2: Source (Head) Branch${RESET}"
echo "------------------------------------------"
echo "Fetching remote branches from GitHub..."

RAW_BRANCHES=()
while IFS= read -r b; do
  [ -n "$b" ] && RAW_BRANCHES+=("$b")
done < <(gh api "repos/$REPO_FULL_NAME/branches" --paginate --jq '.[].name' 2>/dev/null || true)

if [ ${#RAW_BRANCHES[@]} -eq 0 ]; then
  echo -e "${RED}❌ Error: Could not fetch branches for $REPO_FULL_NAME (empty repository or no branches found).${RESET}"
  exit 1
fi

# Detect default branch
DEFAULT_BRANCH=$(gh repo view "$REPO_FULL_NAME" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main")

echo "Available branches in $REPO_FULL_NAME:"
for i in "${!RAW_BRANCHES[@]}"; do
  num=$((i + 1))
  b="${RAW_BRANCHES[$i]}"
  if [ "$b" = "$DEFAULT_BRANCH" ]; then
    printf "  [%2d] %-30s ${DIM}(default base)${RESET}\n" "$num" "$b"
  else
    printf "  [%2d] %-30s\n" "$num" "$b"
  fi
done

echo ""
read -r -p "Select Source (Head) Branch by number or type branch name: " HEAD_CHOICE

HEAD_BRANCH=""
if [[ "$HEAD_CHOICE" =~ ^[0-9]+$ ]] && [ "$HEAD_CHOICE" -ge 1 ] && [ "$HEAD_CHOICE" -le "${#RAW_BRANCHES[@]}" ]; then
  HEAD_BRANCH="${RAW_BRANCHES[$((HEAD_CHOICE - 1))]}"
elif [ -n "$HEAD_CHOICE" ]; then
  HEAD_BRANCH="$HEAD_CHOICE"
fi

if [ -z "$HEAD_BRANCH" ]; then
  echo -e "${RED}❌ Error: No source branch specified.${RESET}"
  exit 1
fi

echo -e "✅ Source Branch : ${CYAN}${BOLD}$HEAD_BRANCH${RESET}"

# 5. Target (Base) Branch Selection
echo ""
echo -e "${BOLD}🎯 Step 3: Target (Base) Branch${RESET}"
echo "------------------------------------------"

TARGET_CANDIDATES=()
for b in "${RAW_BRANCHES[@]}"; do
  if [ "$b" != "$HEAD_BRANCH" ]; then
    TARGET_CANDIDATES+=("$b")
  fi
done

# Sort default branch to the top
SORTED_TARGETS=()
for b in "${TARGET_CANDIDATES[@]}"; do
  [ "$b" = "$DEFAULT_BRANCH" ] && SORTED_TARGETS+=("$b")
done
for b in "${TARGET_CANDIDATES[@]}"; do
  [ "$b" != "$DEFAULT_BRANCH" ] && SORTED_TARGETS+=("$b")
done

if [ ${#SORTED_TARGETS[@]} -eq 0 ]; then
  SORTED_TARGETS=("$DEFAULT_BRANCH")
fi

echo "Available target branches:"
for i in "${!SORTED_TARGETS[@]}"; do
  num=$((i + 1))
  if [ $i -eq 0 ]; then
    echo "  [$num] ${SORTED_TARGETS[$i]} (default)"
  else
    echo "  [$num] ${SORTED_TARGETS[$i]}"
  fi
done

echo ""
read -r -p "Select target branch by number (or press Enter for default: ${SORTED_TARGETS[0]}): " TARGET_CHOICE

if [ -z "$TARGET_CHOICE" ]; then
  TARGET_BASE="${SORTED_TARGETS[0]}"
elif [[ "$TARGET_CHOICE" =~ ^[0-9]+$ ]] && [ "$TARGET_CHOICE" -ge 1 ] && [ "$TARGET_CHOICE" -le "${#SORTED_TARGETS[@]}" ]; then
  TARGET_BASE="${SORTED_TARGETS[$((TARGET_CHOICE - 1))]}"
else
  TARGET_BASE="$TARGET_CHOICE"
fi

if [ "$HEAD_BRANCH" = "$TARGET_BASE" ]; then
  echo -e "${RED}❌ Error: Source branch and target base branch cannot be the same ('$TARGET_BASE').${RESET}"
  exit 1
fi

echo -e "✅ Source Branch : ${CYAN}${BOLD}$HEAD_BRANCH${RESET}"
echo -e "✅ Target Base   : ${CYAN}${BOLD}$TARGET_BASE${RESET}"

# 6. Check if PR already exists
EXISTING_PR=$(gh pr list --repo "$REPO_FULL_NAME" --head "$HEAD_BRANCH" --base "$TARGET_BASE" --json url,number --jq '.[0].url' 2>/dev/null || true)
if [ -n "$EXISTING_PR" ]; then
  echo ""
  echo -e "ℹ️  ${YELLOW}An open PR already exists for branch '$HEAD_BRANCH' into '$TARGET_BASE':${RESET}"
  echo -e "🔗 ${CYAN}$EXISTING_PR${RESET}"
  exit 0
fi

# 7. Collect Commits and Code Diffs directly from GitHub Compare API
echo ""
echo -e "${BOLD}📝 Step 4: PR Title & Description${RESET}"
echo "------------------------------------------"
echo "Fetching code comparison directly from GitHub..."

# Python helper to extract compare data and call AI if configured
COMPARE_TMP=$(mktemp)
python3 - "$REPO_FULL_NAME" "$TARGET_BASE" "$HEAD_BRANCH" > "$COMPARE_TMP" 2>/dev/null << 'EOF'
import sys, json, subprocess

repo = sys.argv[1]
base = sys.argv[2]
head = sys.argv[3]

cmd = ["gh", "api", f"repos/{repo}/compare/{base}...{head}"]
res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
if res.returncode != 0:
    sys.exit(1)

try:
    data = json.loads(res.stdout)
except Exception:
    sys.exit(1)

commits = [c.get("commit", {}).get("message", "").strip() for c in data.get("commits", [])]
files = [f.get("filename", "") for f in data.get("files", [])]

# Diff patches excluding docs and lockfiles
diff_parts = []
for f in data.get("files", []):
    fn = f.get("filename", "")
    patch = f.get("patch", "")
    if patch and not any(fn.lower().endswith(x) for x in [".md", ".lock", "lock.json", "lock.yaml", "readme"]):
        diff_parts.append(f"--- {fn}\n{patch[:600]}")
    if len(diff_parts) >= 15:
        break

out = {
    "total_commits": len(commits),
    "commits": commits,
    "files": files[:30],
    "diff_snippet": "\n\n".join(diff_parts)[:3000]
}
print(json.dumps(out))
EOF

COMPARE_DATA=$(cat "$COMPARE_TMP" 2>/dev/null || echo "{}")
rm -f "$COMPARE_TMP"

COMMITS_COUNT=$(python3 -c "import json; d=json.loads('''$COMPARE_DATA'''); print(d.get('total_commits', 0))" 2>/dev/null || echo "0")
if [ "$COMMITS_COUNT" -eq 0 ]; then
  echo -e "${YELLOW}⚠️ Warning: No new commits found between '$TARGET_BASE' and '$HEAD_BRANCH'.${RESET}"
fi

COMMITS_LIST=$(python3 -c "import json; d=json.loads('''$COMPARE_DATA'''); print('\n'.join(['- ' + c.splitlines()[0] for c in d.get('commits', [])]))" 2>/dev/null || echo "")
DEFAULT_TITLE=$(python3 -c "import json; d=json.loads('''$COMPARE_DATA'''); print(d.get('commits', [''])[0].splitlines()[0] if d.get('commits') else 'feat: updates')" 2>/dev/null || echo "feat: updates")

GIT_DEFAULT_BODY="### Summary of Changes
$COMMITS_LIST"

USE_AI_RESULT=0
AI_TITLE=""
AI_BODY=""

if [ -n "$OPENROUTER_API_KEY" ] && [ "$COMMITS_COUNT" -gt 0 ]; then
  spinner() {
    local pid=$1
    local delay=0.1
    local spinstr="|/-\\"
    while kill -0 "$pid" 2>/dev/null; do
      local temp=${spinstr#?}
      printf "\r⏳ Generating PR title & description with AI... [%c] " "$spinstr"
      spinstr=$temp${spinstr%"$temp"}
      sleep $delay
    done
    printf "\r\033[K"
  }

  AI_TMP_OUT=$(mktemp)

  (
    python3 - "$COMPARE_DATA" "$OPENROUTER_API_KEY" "$OPENROUTER_MODEL" > "$AI_TMP_OUT" 2>/dev/null << 'EOF'
import sys, urllib.request, json, re, os

compare_json_str = sys.argv[1] if len(sys.argv) > 1 else "{}"
api_key = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else os.getenv("OPENROUTER_API_KEY", "")
preferred_model = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else os.getenv("OPENROUTER_MODEL", "cohere/north-mini-code:free")

try:
    data = json.loads(compare_json_str)
except Exception:
    data = {}

commits = "\n".join(["- " + c for c in data.get("commits", [])])
changed_files = "\n".join(data.get("files", []))
diff_snippet = data.get("diff_snippet", "")

models = [preferred_model, "cohere/north-mini-code:free", "qwen/qwen3.8-27b:free", "liquid/lfm-2.5-2.6b:free", "z-ai/glm-5.2:free"]
seen = set()
candidate_models = [m for m in models if m and not (m in seen or seen.add(m))]

prompt = f"""You are a senior software engineer writing a clean, readable GitHub Pull Request description.

Commit History:
{commits}

Modified Code Files:
{changed_files}

Code Changes Sample:
{diff_snippet}

CRITICAL RULES:
1. NEVER mention line counts, number of lines added/modified/deleted, or raw git statistics.
2. DO NOT mention README or documentation changes in summary or key changes. Focus on code, logic, features, and fixes.
3. TITLE: Must be a concise Conventional Commit title explaining WHAT feature/fix was actually built (e.g. 'feat(auth): add user session validation').
4. SUMMARY: 2-3 clear bullet points describing the business/technical purpose of the changes.
5. KEY CHANGES: High-level technical bullet points explaining what actually changed in application logic, UI, APIs, database, or backend handlers.

Output ONLY valid JSON in this exact structure without markdown code blocks:
{{"title": "...", "description": "### Summary\\n- ...\\n\\n### Key Changes\\n- ..."}}
"""

for m in candidate_models:
    try:
        req = urllib.request.Request(
            "https://openrouter.ai/api/v1/chat/completions",
            data=json.dumps({"model": m, "messages": [{"role": "user", "content": prompt}], "temperature": 0.2}).encode("utf-8"),
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            raw = data["choices"][0]["message"]["content"]
            cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", raw.strip(), flags=re.MULTILINE).strip()
            parsed = json.loads(cleaned)
            if "title" in parsed and "description" in parsed:
                print("__AI_SUCCESS__")
                print(parsed["title"].strip())
                print("__AI_SEP__")
                print(parsed["description"].strip())
                sys.exit(0)
    except Exception:
        continue

print("__AI_FAILED__")
EOF
  ) &
  AI_PID=$!

  spinner "$AI_PID"
  wait "$AI_PID" 2>/dev/null || true

  AI_OUTPUT=$(cat "$AI_TMP_OUT" 2>/dev/null || echo "__AI_FAILED__")
  rm -f "$AI_TMP_OUT"

  if [[ "$AI_OUTPUT" == *"__AI_SUCCESS__"* ]]; then
    CONTENT="${AI_OUTPUT#*__AI_SUCCESS__$'\n'}"
    AI_TITLE="${CONTENT%%$'\n'__AI_SEP__*}"
    AI_BODY="${CONTENT#*__AI_SEP__$'\n'}"

    echo ""
    echo -e "${BOLD}✨ AI has generated PR details:${RESET}"
    echo "=========================================="
    echo -e "📌 ${BOLD}Title:${RESET}"
    echo "   $AI_TITLE"
    echo ""
    echo -e "📄 ${BOLD}Description:${RESET}"
    echo "$AI_BODY"
    echo "=========================================="
    echo ""

    read -r -p "Do you want to use this AI-generated Title and Description? (Y/n): " ACCEPT_AI
    if [ -z "$ACCEPT_AI" ] || [[ "$ACCEPT_AI" =~ ^[Yy]$ ]]; then
      USE_AI_RESULT=1
      PR_TITLE="$AI_TITLE"
      PR_BODY="$AI_BODY"
      echo -e "${GREEN}✅ Accepted AI suggestions.${RESET}"
    else
      echo "ℹ️  AI suggestions rejected. Switching to manual input mode..."
    fi
  else
    echo "⚠️  AI generation unavailable. Switching to manual input mode..."
  fi
fi

# Manual input mode if AI was not configured, failed, or rejected
if [ "$USE_AI_RESULT" -eq 0 ]; then
  echo ""
  echo "--- PR Title ---"
  echo "Default: $DEFAULT_TITLE"
  read -r -p "Enter PR Title [Press Enter for default]: " INPUT_TITLE
  PR_TITLE="${INPUT_TITLE:-$DEFAULT_TITLE}"

  echo ""
  echo "--- PR Description ---"
  echo "Default commit summary:"
  echo "$GIT_DEFAULT_BODY"
  echo ""
  read -r -p "Enter custom description [Press Enter to keep default summary]: " INPUT_BODY
  if [ -n "$INPUT_BODY" ]; then
    PR_BODY="$INPUT_BODY"
  else
    PR_BODY="$GIT_DEFAULT_BODY"
  fi
fi

# Helper function to parse user selection from list (macOS Bash 3.2 compatible)
parse_selections() {
  local input="$1"
  shift
  local items=("$@")
  local cleaned="${input//,/ }"
  for idx in $cleaned; do
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#items[@]}" ]; then
      echo "${items[$((idx - 1))]}"
    fi
  done
}

# 8. Reviewers & Assignees
echo ""
echo -e "${BOLD}👥 Step 5: Reviewers & Assignees${RESET}"
echo "------------------------------------------"
echo "Fetching team members from repository..."
MEMBERS=()
while IFS= read -r member; do
  [ -n "$member" ] && MEMBERS+=("$member")
done < <(gh api "repos/$REPO_FULL_NAME/assignees" --jq '.[].login' 2>/dev/null || true)

if [ ${#MEMBERS[@]} -gt 0 ]; then
  for i in "${!MEMBERS[@]}"; do
    num=$((i + 1))
    name="${MEMBERS[$i]}"
    if [ "$name" = "$CURRENT_GH_USER" ]; then
      echo "  [$num] $name (you)"
    else
      echo "  [$num] $name"
    fi
  done
else
  echo "  (No team members found)"
fi

# Reviewers Selection
echo ""
read -r -p "Select Reviewer(s) by number (e.g. 1, 2) or press Enter to skip: " SELECTED_REV_INPUT
SELECTED_REVIEWERS=()
if [ -n "$SELECTED_REV_INPUT" ]; then
  while IFS= read -r item; do
    [ -n "$item" ] && SELECTED_REVIEWERS+=("$item")
  done < <(parse_selections "$SELECTED_REV_INPUT" "${MEMBERS[@]}")
fi

# Assignees Selection
echo ""
read -r -p "Select Assignee(s) by number (e.g. 1, 2) or press Enter to skip: " SELECTED_ASG_INPUT
SELECTED_ASSIGNEES=()
if [ -n "$SELECTED_ASG_INPUT" ]; then
  while IFS= read -r item; do
    [ -n "$item" ] && SELECTED_ASSIGNEES+=("$item")
  done < <(parse_selections "$SELECTED_ASG_INPUT" "${MEMBERS[@]}")
fi

# 9. Labels
echo ""
echo -e "${BOLD}🏷️  Step 6: Labels${RESET}"
echo "------------------------------------------"
echo "Fetching labels from repository..."
LABELS=()
while IFS= read -r label; do
  [ -n "$label" ] && LABELS+=("$label")
done < <(gh api "repos/$REPO_FULL_NAME/labels" --jq '.[].name' 2>/dev/null || true)

if [ ${#LABELS[@]} -gt 0 ]; then
  for i in "${!LABELS[@]}"; do
    num=$((i + 1))
    echo "  [$num] ${LABELS[$i]}"
  done
else
  echo "  (No labels found)"
fi

echo ""
read -r -p "Select Label(s) by number (e.g. 1, 3) or press Enter to skip: " SELECTED_LBL_INPUT
SELECTED_LABELS=()
if [ -n "$SELECTED_LBL_INPUT" ]; then
  while IFS= read -r item; do
    [ -n "$item" ] && SELECTED_LABELS+=("$item")
  done < <(parse_selections "$SELECTED_LBL_INPUT" "${LABELS[@]}")
fi

# Build extra gh pr create arguments
EXTRA_FLAGS=()
for rev in "${SELECTED_REVIEWERS[@]}"; do
  EXTRA_FLAGS+=(--reviewer "$rev")
done
for asg in "${SELECTED_ASSIGNEES[@]}"; do
  EXTRA_FLAGS+=(--assignee "$asg")
done
for lbl in "${SELECTED_LABELS[@]}"; do
  EXTRA_FLAGS+=(--label "$lbl")
done

# 10. Confirmation before creating PR
echo ""
echo -e "${BOLD}==========================================${RESET}"
echo -e "${BOLD} 📋 Review PR Summary Before Creation${RESET}"
echo -e "${BOLD}==========================================${RESET}"
echo -e "• Repository  : ${CYAN}$REPO_FULL_NAME${RESET}"
echo -e "• Base Branch : ${CYAN}$TARGET_BASE${RESET}"
echo -e "• Head Branch : ${CYAN}$HEAD_BRANCH${RESET}"
echo -e "• Title       : $PR_TITLE"
if [ ${#SELECTED_REVIEWERS[@]} -gt 0 ]; then
  echo -e "• Reviewers   : ${SELECTED_REVIEWERS[*]}"
else
  echo -e "• Reviewers   : (None)"
fi
if [ ${#SELECTED_ASSIGNEES[@]} -gt 0 ]; then
  echo -e "• Assignees   : ${SELECTED_ASSIGNEES[*]}"
else
  echo -e "• Assignees   : (None)"
fi
if [ ${#SELECTED_LABELS[@]} -gt 0 ]; then
  echo -e "• Labels      : ${SELECTED_LABELS[*]}"
else
  echo -e "• Labels      : (None)"
fi
echo "=========================================="
echo ""

read -r -p "Proceed to create PR on GitHub? (Y/n): " CONFIRM
if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
  echo "PR creation cancelled."
  exit 0
fi

# 11. Create the Pull Request
echo ""
echo "Creating pull request on GitHub..."
PR_URL=$(gh pr create \
  --repo "$REPO_FULL_NAME" \
  --base "$TARGET_BASE" \
  --head "$HEAD_BRANCH" \
  --title "$PR_TITLE" \
  --body "$PR_BODY" \
  "${EXTRA_FLAGS[@]}" 2>&1)

echo ""
echo -e "${GREEN}${BOLD}✅ Pull Request created successfully!${RESET}"
echo -e "🔗 $PR_URL"
echo ""
