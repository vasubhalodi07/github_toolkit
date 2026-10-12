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

# Colors for terminal output
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
echo -e "${BOLD}====================================================${RESET}"
echo -e "${BOLD} 📊 Pull Request Dashboard & Status${RESET}"
echo -e "${BOLD}====================================================${RESET}"
echo ""

# 1. Verify gh CLI
if ! command -v gh &> /dev/null; then
  echo -e "${RED}❌ Error: GitHub CLI ('gh') is not installed or not in PATH.${RESET}"
  exit 1
fi

# 2. Authenticate & detect user (with multi-method fallbacks)
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

echo -e "👤 Authenticated as  : ${CYAN}${BOLD}@$CURRENT_GH_USER${RESET}"

# Fetch user's organizations
ORGS=()
while IFS= read -r org; do
  [ -n "$org" ] && ORGS+=("$org")
done < <(gh api user/orgs --jq '.[].login' 2>/dev/null || true)

if [ ${#ORGS[@]} -gt 0 ]; then
  echo -e "🏢 Organizations     : ${MAGENTA}${ORGS[*]}${RESET}"
else
  echo -e "🏢 Organizations     : ${DIM}(None)${RESET}"
fi

echo -e "🌐 Scope             : ${BOLD}Audit Everything (Personal + All Organizations)${RESET}"
echo ""

# 3. Python script to query GitHub API across all repositories in parallel
python3 - "$CURRENT_GH_USER" "${ORGS[@]}" << 'EOF'
import sys, json, subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed

current_user = sys.argv[1]
orgs = sys.argv[2:]

# Style codes
BOLD = "\033[1m"
GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
BLUE = "\033[0;34m"
CYAN = "\033[0;36m"
MAGENTA = "\033[0;35m"
RED = "\033[0;31m"
DIM = "\033[2m"
RESET = "\033[0m"

# 1. Collect repositories across Personal + All Organizations via GitHub CLI
def get_repos_for_owner(owner):
    cmd = ["gh", "repo", "list", owner, "--limit", "300", "--json", "nameWithOwner,name,isPrivate,visibility"]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode == 0 and res.stdout.strip():
        try:
            return json.loads(res.stdout)
        except Exception:
            return []
    return []

print(f"{BOLD}Fetching repositories from GitHub CLI...{RESET}")

all_repos = []
user_repos = get_repos_for_owner(current_user)
all_repos.extend(user_repos)
print(f"  • Found {CYAN}{len(user_repos)}{RESET} personal repos for @{current_user}")

for org in orgs:
    org_repos = get_repos_for_owner(org)
    all_repos.extend(org_repos)
    print(f"  • Found {MAGENTA}{len(org_repos)}{RESET} repos in org '{org}'")

# Deduplicate repositories by nameWithOwner
unique_repos = []
seen = set()
for r in all_repos:
    slug = r.get("nameWithOwner")
    if slug and slug not in seen:
        seen.add(slug)
        unique_repos.append(r)

if not unique_repos:
    print(f"\n{RED}❌ No repositories found to inspect.{RESET}")
    sys.exit(0)

print(f"\n🔍 Scanning {BOLD}{len(unique_repos)}{RESET} repositories for open Pull Requests...\n")

# 2. Worker to query PRs for each repository
def fetch_repo_prs(repo_meta):
    slug = repo_meta["nameWithOwner"]
    name = repo_meta.get("name", slug)
    cmd = [
        "gh", "pr", "list",
        "--repo", slug,
        "--state", "open",
        "--json", "number,title,author,assignees,reviewRequests,reviewDecision,url,headRefName,baseRefName,updatedAt"
    ]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        return []
    try:
        prs = json.loads(res.stdout or "[]")
        for pr in prs:
            pr["project_name"] = name
            pr["repo_slug"] = slug
        return prs
    except Exception:
        return []

all_open_prs = []
total = len(unique_repos)
completed_count = 0

with ThreadPoolExecutor(max_workers=8) as executor:
    future_to_repo = {executor.submit(fetch_repo_prs, r): r for r in unique_repos}
    for future in as_completed(future_to_repo):
        prs = future.result()
        all_open_prs.extend(prs)
        completed_count += 1
        pct = int((completed_count / total) * 100)
        sys.stdout.write(f"\r  ⚡ Checking repositories: {completed_count}/{total} [{pct}%] ...")
        sys.stdout.flush()

sys.stdout.write("\r" + " " * 60 + "\r")
sys.stdout.flush()

# Categorize PRs
assigned_to_me = []
my_pending_prs = []

for pr in all_open_prs:
    author = pr.get("author", {}).get("login", "")
    assignees = [a.get("login") for a in pr.get("assignees", [])]
    reviewers = [r.get("login") for r in pr.get("reviewRequests", [])]
    decision = (pr.get("reviewDecision") or "").upper()

    # Category 1: Assigned to me or review requested from me (and not authored by me)
    if current_user in reviewers or current_user in assignees:
        if author != current_user:
            assigned_to_me.append(pr)

    # Category 2: Authored by me and review is still not approved
    if author == current_user:
        if decision != "APPROVED":
            my_pending_prs.append(pr)

# Sort by repository name and PR number
assigned_to_me.sort(key=lambda x: (x["repo_slug"], x["number"]))
my_pending_prs.sort(key=lambda x: (x["repo_slug"], x["number"]))

# --- SECTION 1 ---
print(f"{BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{RESET}")
print(f"{BOLD}📥 Section 1: PRs Awaiting Your Review / Assigned to You{RESET}")
print(f"{BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{RESET}")

if not assigned_to_me:
    print(f"  {GREEN}✓ No pending PRs assigned to you or waiting for your review.{RESET}\n")
else:
    for pr in assigned_to_me:
        author = pr.get("author", {}).get("login", "unknown")
        head = pr.get("headRefName", "")
        base = pr.get("baseRefName", "")
        branch_info = f"{head} ➜ {base}" if head and base else ""
        
        roles = []
        if current_user in [r.get("login") for r in pr.get("reviewRequests", [])]:
            roles.append(f"{YELLOW}Review Requested{RESET}")
        if current_user in [a.get("login") for a in pr.get("assignees", [])]:
            roles.append(f"{CYAN}Assignee{RESET}")
        roles_str = " | ".join(roles)

        print(f"  • {CYAN}[{pr['repo_slug']}]{RESET} {BOLD}#{pr['number']} {pr['title']}{RESET}")
        print(f"    Author : @{author}  |  Role: {roles_str}")
        if branch_info:
            print(f"    Branch : {branch_info}")
        print(f"    Link   : {DIM}{pr['url']}{RESET}")
        print("")

# --- SECTION 2 ---
print(f"{BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{RESET}")
print(f"{BOLD}📤 Section 2: Open PRs Created by You (Review Pending){RESET}")
print(f"{BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{RESET}")

if not my_pending_prs:
    print(f"  {GREEN}✓ All your open PRs are approved or you have no open PRs awaiting review.{RESET}\n")
else:
    for pr in my_pending_prs:
        head = pr.get("headRefName", "")
        base = pr.get("baseRefName", "")
        branch_info = f"{head} ➜ {base}" if head and base else ""
        
        decision = pr.get("reviewDecision") or "PENDING"
        if decision == "CHANGES_REQUESTED":
            status_badge = f"{RED}Changes Requested{RESET}"
        elif decision == "REVIEW_REQUIRED":
            status_badge = f"{YELLOW}Review Required{RESET}"
        else:
            status_badge = f"{YELLOW}Review Pending{RESET}"

        pending_revs = [r.get("login") for r in pr.get("reviewRequests", [])]
        rev_str = ", ".join([f"@{r}" for r in pending_revs]) if pending_revs else "No reviewers assigned yet"

        print(f"  • {CYAN}[{pr['repo_slug']}]{RESET} {BOLD}#{pr['number']} {pr['title']}{RESET}")
        print(f"    Status  : {status_badge}")
        print(f"    Waiting : {rev_str}")
        if branch_info:
            print(f"    Branch  : {branch_info}")
        print(f"    Link    : {DIM}{pr['url']}{RESET}")
        print("")

# --- SUMMARY ---
print(f"{BOLD}====================================================={RESET}")
print(f"{BOLD}📊 PR Overview Across All Repositories{RESET}")
print(f"{BOLD}====================================================={RESET}")
print(f" • Total Repositories Scanned : {BOLD}{len(unique_repos)}{RESET}")
print(f" • Total Open PRs Found       : {BOLD}{len(all_open_prs)}{RESET}")
print(f" • PRs Awaiting Your Action   : {YELLOW}{BOLD}{len(assigned_to_me)}{RESET}")
print(f" • Your PRs Awaiting Review   : {CYAN}{BOLD}{len(my_pending_prs)}{RESET}")
print(f"{BOLD}====================================================={RESET}\n")
EOF
