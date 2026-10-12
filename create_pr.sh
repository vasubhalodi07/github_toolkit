#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_JSON="$SCRIPT_DIR/source.json"

# Load local environment variables (API keys, models) if present with auto-export
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

echo "=========================================="
echo " 🚀 Create Pull Request Script"
echo "=========================================="

# 1. Check if source.json exists
if [ ! -f "$SOURCE_JSON" ]; then
  echo "❌ Error: Configuration file 'source.json' not found at:"
  echo "   $SOURCE_JSON"
  exit 1
fi

# 2. Parse projects from source.json
PROJECT_NAMES=()
PROJECT_PATHS=()
PROJECT_REPOS=()

if command -v jq &> /dev/null; then
  while IFS=$'\t' read -r name path repo; do
    if [ -n "$name" ]; then
      PROJECT_NAMES+=("$name")
      PROJECT_PATHS+=("$path")
      PROJECT_REPOS+=("$repo")
    fi
  done < <(jq -r '.[] | [.name, .path, (.repository // "")] | @tsv' "$SOURCE_JSON" 2>/dev/null)
elif command -v python3 &> /dev/null; then
  while IFS=$'\t' read -r name path repo; do
    if [ -n "$name" ]; then
      PROJECT_NAMES+=("$name")
      PROJECT_PATHS+=("$path")
      PROJECT_REPOS+=("$repo")
    fi
  done < <(python3 -c "
import json
with open('$SOURCE_JSON', 'r') as f:
    items = json.load(f)
for it in items:
    print(f\"{it.get('name', '')}\t{it.get('path', '')}\t{it.get('repository', '')}\")
" 2>/dev/null)
else
  echo "❌ Error: Neither 'jq' nor 'python3' is available to parse $SOURCE_JSON."
  exit 1
fi

if [ ${#PROJECT_NAMES[@]} -eq 0 ]; then
  echo "❌ Error: No projects registered in $SOURCE_JSON."
  exit 1
fi

# 3. Project Selection
echo ""
echo "📁 Step 1: Select Project"
echo "------------------------------------------"
for i in "${!PROJECT_NAMES[@]}"; do
  num=$((i + 1))
  echo "  [$num] ${PROJECT_NAMES[$i]} (${PROJECT_PATHS[$i]})"
done

echo ""
read -r -p "Enter project number (1-${#PROJECT_NAMES[@]}): " SELECTED_PROJ_IDX

if ! [[ "$SELECTED_PROJ_IDX" =~ ^[0-9]+$ ]] || [ "$SELECTED_PROJ_IDX" -lt 1 ] || [ "$SELECTED_PROJ_IDX" -gt "${#PROJECT_NAMES[@]}" ]; then
  echo "❌ Error: Invalid selection."
  exit 1
fi

PROJ_INDEX=$((SELECTED_PROJ_IDX - 1))
SELECTED_PROJ_NAME="${PROJECT_NAMES[$PROJ_INDEX]}"
SELECTED_PROJ_PATH="${PROJECT_PATHS[$PROJ_INDEX]}"
SELECTED_PROJ_REPO="${PROJECT_REPOS[$PROJ_INDEX]}"

if [ ! -d "$SELECTED_PROJ_PATH" ]; then
  echo "❌ Error: Project path does not exist:"
  echo "   $SELECTED_PROJ_PATH"
  exit 1
fi

# Switch context into selected project
cd "$SELECTED_PROJ_PATH"

# 4. Check GitHub CLI ('gh') & authentication
if ! command -v gh &> /dev/null; then
  echo "❌ Error: GitHub CLI ('gh') is not installed or not in PATH."
  echo "Please install it or authenticate via 'gh auth login'."
  exit 1
fi

CURRENT_GH_USER=$(gh api user --jq .login 2>/dev/null || true)
if [ -z "$CURRENT_GH_USER" ]; then
  echo "❌ Error: Not logged in to GitHub CLI."
  echo "Please run 'gh auth login' to authenticate."
  exit 1
fi

# 5. Detect repository
REPO_FULL_NAME=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
if [ -z "$REPO_FULL_NAME" ] && [ -n "$SELECTED_PROJ_REPO" ]; then
  REPO_FULL_NAME="$SELECTED_PROJ_REPO"
fi

if [ -z "$REPO_FULL_NAME" ]; then
  echo "❌ Error: Could not determine GitHub repository for $SELECTED_PROJ_PATH."
  exit 1
fi

echo ""
echo "📦 Selected Project : $SELECTED_PROJ_NAME"
echo "📂 Project Path     : $SELECTED_PROJ_PATH"
echo "🐙 Repository       : $REPO_FULL_NAME"
echo "👤 Logged in as     : $CURRENT_GH_USER"

# 6. Source (Head) Branch Selection / Confirmation
echo ""
echo "------------------------------------------"
echo "🌿 Step 2: Source (Head) Branch"
echo "------------------------------------------"
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || true)

if [ -z "$CURRENT_BRANCH" ]; then
  echo "⚠️ Warning: Not currently on a branch (detached HEAD or empty repository)."
  read -r -p "Enter source branch name: " HEAD_BRANCH
  if [ -z "$HEAD_BRANCH" ]; then
    echo "❌ Error: No source branch specified."
    exit 1
  fi
else
  echo "Current active branch: $CURRENT_BRANCH"
  read -r -p "Use '$CURRENT_BRANCH' as PR source branch? (Y/n) [or enter another branch name]: " BRANCH_CHOICE
  if [ -z "$BRANCH_CHOICE" ] || [[ "$BRANCH_CHOICE" =~ ^[Yy]$ ]]; then
    HEAD_BRANCH="$CURRENT_BRANCH"
  elif [[ "$BRANCH_CHOICE" =~ ^[Nn]$ ]]; then
    read -r -p "Enter source branch name: " CUSTOM_BRANCH
    if [ -z "$CUSTOM_BRANCH" ]; then
      echo "❌ Error: No source branch specified."
      exit 1
    fi
    HEAD_BRANCH="$CUSTOM_BRANCH"
  else
    HEAD_BRANCH="$BRANCH_CHOICE"
  fi
fi

# 7. Target (Base) Branch Selection
echo ""
echo "------------------------------------------"
echo "🎯 Step 3: Target (Base) Branch"
echo "------------------------------------------"
echo "Fetching remote branches from origin..."
git fetch origin --prune 2>/dev/null || true

RAW_BRANCHES=()
while IFS= read -r b; do
  if [ -n "$b" ] && [ "$b" != "HEAD" ] && [ "$b" != "$HEAD_BRANCH" ]; then
    RAW_BRANCHES+=("$b")
  fi
done < <(git for-each-ref --format="%(refname:strip=3)" refs/remotes/origin/ 2>/dev/null)

# Fallback to local branches if no remote branches found
if [ ${#RAW_BRANCHES[@]} -eq 0 ]; then
  while IFS= read -r b; do
    if [ -n "$b" ] && [ "$b" != "$HEAD_BRANCH" ]; then
      RAW_BRANCHES+=("$b")
    fi
  done < <(git for-each-ref --format="%(refname:strip=2)" refs/heads/ 2>/dev/null)
fi

# Deduplicate branches preserving order
UNIQUE_BRANCHES=()
for b in "${RAW_BRANCHES[@]}"; do
  found=0
  for u in "${UNIQUE_BRANCHES[@]}"; do
    if [ "$u" = "$b" ]; then
      found=1
      break
    fi
  done
  if [ $found -eq 0 ]; then
    UNIQUE_BRANCHES+=("$b")
  fi
done

# Prioritize main or master at the top
SORTED_TARGET_BRANCHES=()
for b in "${UNIQUE_BRANCHES[@]}"; do
  if [ "$b" = "main" ] || [ "$b" = "master" ]; then
    SORTED_TARGET_BRANCHES+=("$b")
  fi
done
for b in "${UNIQUE_BRANCHES[@]}"; do
  if [ "$b" != "main" ] && [ "$b" != "master" ]; then
    SORTED_TARGET_BRANCHES+=("$b")
  fi
done

if [ ${#SORTED_TARGET_BRANCHES[@]} -eq 0 ]; then
  echo "⚠️ Warning: No candidate target branches detected automatically."
  read -r -p "Enter target base branch [Default: main]: " CUSTOM_TARGET
  TARGET_BASE="${CUSTOM_TARGET:-main}"
else
  echo "Available target branches:"
  for i in "${!SORTED_TARGET_BRANCHES[@]}"; do
    num=$((i + 1))
    if [ $i -eq 0 ]; then
      echo "  [$num] ${SORTED_TARGET_BRANCHES[$i]} (default)"
    else
      echo "  [$num] ${SORTED_TARGET_BRANCHES[$i]}"
    fi
  done
  echo ""
  read -r -p "Select target branch by number (or type branch name) [Default: 1 - ${SORTED_TARGET_BRANCHES[0]}]: " TARGET_CHOICE
  if [ -z "$TARGET_CHOICE" ]; then
    TARGET_BASE="${SORTED_TARGET_BRANCHES[0]}"
  elif [[ "$TARGET_CHOICE" =~ ^[0-9]+$ ]] && [ "$TARGET_CHOICE" -ge 1 ] && [ "$TARGET_CHOICE" -le "${#SORTED_TARGET_BRANCHES[@]}" ]; then
    TARGET_BASE="${SORTED_TARGET_BRANCHES[$((TARGET_CHOICE - 1))]}"
  else
    TARGET_BASE="$TARGET_CHOICE"
  fi
fi

if [ "$HEAD_BRANCH" = "$TARGET_BASE" ]; then
  echo "❌ Error: Source branch and target base branch cannot be the same ('$TARGET_BASE')."
  exit 1
fi

echo "✅ Source Branch : $HEAD_BRANCH"
echo "✅ Target Base   : $TARGET_BASE"

# 8. Check for uncommitted changes
if [ -n "$(git status --porcelain)" ]; then
  echo ""
  echo "⚠️ Warning: You have uncommitted changes in '$SELECTED_PROJ_NAME':"
  git status --short
  echo ""
  read -r -p "Do you want to continue without committing these changes? (y/N): " CONTINUE_UNCOMMITTED
  if [[ ! "$CONTINUE_UNCOMMITTED" =~ ^[Yy]$ ]]; then
    echo "Aborted. Please commit or stash your changes first."
    exit 1
  fi
fi

# 9. Check if local commits on HEAD_BRANCH are pushed to remote
git fetch origin "$HEAD_BRANCH" 2>/dev/null || true
LOCAL_REV=$(git rev-parse "$HEAD_BRANCH" 2>/dev/null || git rev-parse HEAD)
REMOTE_REV=$(git rev-parse "origin/$HEAD_BRANCH" 2>/dev/null || echo "")

if [ "$LOCAL_REV" != "$REMOTE_REV" ]; then
  echo ""
  echo "⚠️ Branch '$HEAD_BRANCH' has unpushed commits."
  read -r -p "Push changes to 'origin/$HEAD_BRANCH' now? (Y/n): " DO_PUSH
  if [[ "$DO_PUSH" =~ ^[Nn]$ ]]; then
    echo "Cannot create PR without pushing branch to remote. Aborted."
    exit 1
  else
    echo "Pushing '$HEAD_BRANCH' to origin..."
    git push -u origin "$HEAD_BRANCH"
  fi
fi

# 10. Check if a PR already exists
EXISTING_PR=$(gh pr list --repo "$REPO_FULL_NAME" --head "$HEAD_BRANCH" --base "$TARGET_BASE" --json url,number --jq '.[0].url' 2>/dev/null || true)
if [ -n "$EXISTING_PR" ]; then
  echo ""
  echo "ℹ️ An open PR already exists for branch '$HEAD_BRANCH' into '$TARGET_BASE':"
  echo "🔗 $EXISTING_PR"
  exit 0
fi

# 11. Collect PR Title & Description (AI-Powered with Confirmation and Manual Fallback)
echo ""
echo "------------------------------------------"
echo "📝 Step 4: PR Title & Description"
echo "------------------------------------------"

# Determine base ref for comparison (prefer origin/$TARGET_BASE to avoid stale local branches)
COMPARE_BASE="$TARGET_BASE"
if git rev-parse --verify "origin/$TARGET_BASE" >/dev/null 2>&1; then
  COMPARE_BASE="origin/$TARGET_BASE"
fi

DEFAULT_TITLE=$(git log -1 --pretty=%s "$HEAD_BRANCH" 2>/dev/null || git log -1 --pretty=%s)

# Extract commits (with full subjects & bodies)
COMMITS_LIST=$(git log "$COMPARE_BASE..$HEAD_BRANCH" --pretty=format:"- %s" 2>/dev/null || true)
if [ -z "$COMMITS_LIST" ]; then
  COMMITS_LIST=$(git log -10 --pretty=format:"- %s" "$HEAD_BRANCH" 2>/dev/null || true)
fi

# Extract modified files excluding markdown / documentation
CHANGED_FILES=$(git diff "$COMPARE_BASE...$HEAD_BRANCH" --name-only -- ":!*README*" ":!*.md" 2>/dev/null | head -n 40 || true)
if [ -z "$CHANGED_FILES" ]; then
  CHANGED_FILES=$(git diff "$COMPARE_BASE...$HEAD_BRANCH" --name-only 2>/dev/null | head -n 40 || true)
fi

# Extract compact diff snippet of actual code logic (excluding docs and lockfiles)
DIFF_SNIPPET=$(git diff "$COMPARE_BASE...$HEAD_BRANCH" -U1 -- ":!*README*" ":!*.md" ":!*.lock" ":!package-lock.json" ":!pnpm-lock.yaml" 2>/dev/null | head -n 120 || true)

GIT_DEFAULT_BODY="### Summary of Changes
$COMMITS_LIST"

USE_AI_RESULT=0
AI_TITLE=""
AI_BODY=""

if [ -n "$OPENROUTER_API_KEY" ]; then
  # Spinner for real-time progress while AI is communicating with OpenRouter
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
    python3 - "$COMMITS_LIST" "$CHANGED_FILES" "$DIFF_SNIPPET" "$OPENROUTER_API_KEY" "$OPENROUTER_MODEL" > "$AI_TMP_OUT" 2>/dev/null << 'EOF'
import sys, urllib.request, json, re, os

commits = sys.argv[1] if len(sys.argv) > 1 else ""
changed_files = sys.argv[2] if len(sys.argv) > 2 else ""
diff_snippet = sys.argv[3] if len(sys.argv) > 3 else ""
api_key = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else os.getenv("OPENROUTER_API_KEY", "")
preferred_model = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else os.getenv("OPENROUTER_MODEL", "cohere/north-mini-code:free")

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
1. NEVER mention line counts, number of lines added/modified/deleted, or raw git statistics (e.g., STRICTLY FORBIDDEN to say "Added 137 lines", "Modified 240 lines").
2. DO NOT mention README or documentation changes in the summary or key changes. Focus on code, logic, features, and fixes.
3. TITLE: Must be a concise, specific Conventional Commit title explaining WHAT feature/fix was actually built (e.g. 'feat(auth): add user session validation' or 'feat(game): implement tile match puzzle engine'). NEVER use vague titles like 'Add new features', 'Updates', or 'Misc changes'.
4. SUMMARY: 2-3 clear, readable bullet points describing the business/technical purpose of the changes.
5. KEY CHANGES: High-level technical bullet points explaining what actually changed in the application logic, UI components, APIs, database, or backend handlers.

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

    echo "✨ AI has generated PR details:"
    echo "=========================================="
    echo "📌 Title:"
    echo "   $AI_TITLE"
    echo ""
    echo "📄 Description:"
    echo "$AI_BODY"
    echo "=========================================="
    echo ""

    read -r -p "Do you want to use this AI-generated Title and Description? (Y/n): " ACCEPT_AI
    if [ -z "$ACCEPT_AI" ] || [[ "$ACCEPT_AI" =~ ^[Yy]$ ]]; then
      USE_AI_RESULT=1
      PR_TITLE="$AI_TITLE"
      PR_BODY="$AI_BODY"
      echo "✅ Accepted AI suggestions."
    else
      echo "ℹ️ AI suggestions rejected. Switching to manual input mode..."
    fi
  else
    echo "⚠️ Note: AI generation was unavailable. Switching to manual input mode..."
  fi
fi

# Manual input mode if AI was not configured, failed, or rejected by user
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

# Helper function to parse user selection from list (macOS Bash 3.2 compatible, no local -n)
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

# 12. Reviewers & Assignees
echo ""
echo "------------------------------------------"
echo "👥 Step 5: Reviewers & Assignees"
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

# 13. Labels
echo ""
echo "------------------------------------------"
echo "🏷️ Step 6: Labels"
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

# 14. Confirmation before creating PR
echo ""
echo "=========================================="
echo " 📋 Review PR Summary Before Creation"
echo "=========================================="
echo "• Project     : $SELECTED_PROJ_NAME ($SELECTED_PROJ_PATH)"
echo "• Repository  : $REPO_FULL_NAME"
echo "• Base Branch : $TARGET_BASE"
echo "• Head Branch : $HEAD_BRANCH"
echo "• Title       : $PR_TITLE"
if [ ${#SELECTED_REVIEWERS[@]} -gt 0 ]; then
  echo "• Reviewers   : ${SELECTED_REVIEWERS[*]}"
else
  echo "• Reviewers   : (None)"
fi
if [ ${#SELECTED_ASSIGNEES[@]} -gt 0 ]; then
  echo "• Assignees   : ${SELECTED_ASSIGNEES[*]}"
else
  echo "• Assignees   : (None)"
fi
if [ ${#SELECTED_LABELS[@]} -gt 0 ]; then
  echo "• Labels      : ${SELECTED_LABELS[*]}"
else
  echo "• Labels      : (None)"
fi
echo "=========================================="
echo ""

read -r -p "Proceed to create PR on GitHub? (Y/n): " CONFIRM
if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
  echo "PR creation cancelled."
  exit 0
fi

# 15. Create the Pull Request
echo ""
echo "Creating pull request on GitHub..."
gh pr create \
  --repo "$REPO_FULL_NAME" \
  --base "$TARGET_BASE" \
  --head "$HEAD_BRANCH" \
  --title "$PR_TITLE" \
  --body "$PR_BODY" \
  "${EXTRA_FLAGS[@]}"

echo ""
echo "✅ Pull Request created successfully!"
