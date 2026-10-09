#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_JSON="$SCRIPT_DIR/source.json"

# Colors for terminal output
BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
MAGENTA="\033[0;35m"
RED="\033[0;31m"
RESET="\033[0m"

echo ""
echo -e "${BOLD}📊 Pull Request Dashboard & Status${RESET}"
echo ""

# 1. Verify source.json
if [ ! -f "$SOURCE_JSON" ]; then
  echo -e "${RED}❌ Error: Configuration file 'source.json' not found at:${RESET}"
  echo "   $SOURCE_JSON"
  exit 1
fi

# 2. Verify gh CLI
if ! command -v gh &> /dev/null; then
  echo -e "${RED}❌ Error: GitHub CLI ('gh') is not installed or not in PATH.${RESET}"
  exit 1
fi

CURRENT_GH_USER=$(gh api user --jq .login 2>/dev/null || true)
if [ -z "$CURRENT_GH_USER" ]; then
  echo -e "${RED}❌ Error: Not logged in to GitHub CLI.${RESET}"
  echo "Please run 'gh auth login' to authenticate."
  exit 1
fi

echo -e "Logged in as: ${CYAN}@$CURRENT_GH_USER${RESET}"
echo -e "Scanning registered projects in ${BOLD}source.json${RESET}..."
echo ""

# 3. Python script to query GitHub API and format output
python3 - "$SOURCE_JSON" "$CURRENT_GH_USER" << 'EOF'
import sys, json, subprocess

source_file = sys.argv[1]
current_user = sys.argv[2]

try:
    with open(source_file, "r") as f:
        projects = json.load(f)
except Exception as e:
    print(f"\033[0;31mError reading {source_file}: {e}\033[0m")
    sys.exit(1)

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

assigned_to_me = []
my_pending_prs = []

for idx, p in enumerate(projects, 1):
    repo = p.get("repository")
    name = p.get("name", repo)
    if not repo:
        continue
    
    # Run gh pr list
    cmd = [
        "gh", "pr", "list",
        "--repo", repo,
        "--state", "open",
        "--json", "number,title,author,assignees,reviewRequests,reviewDecision,url,headRefName,baseRefName,updatedAt"
    ]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if res.returncode != 0:
        continue
    
    try:
        prs = json.loads(res.stdout.decode() or "[]")
    except Exception:
        prs = []

    for pr in prs:
        pr["project_name"] = name
        pr["repo_slug"] = repo
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

# --- SECTION 1 ---
print(f"{BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{RESET}")
print(f"{BOLD}📥 Section 1: PRs Awaiting Your Review / Assigned to You{RESET}")
print(f"{BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{RESET}")

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

        print(f"  • {CYAN}[{pr['project_name']}]{RESET} {BOLD}#{pr['number']} {pr['title']}{RESET}")
        print(f"    Author : @{author}  |  Role: {roles_str}")
        if branch_info:
            print(f"    Branch : {branch_info}")
        print(f"    Link   : {DIM}{pr['url']}{RESET}")
        print("")

# --- SECTION 2 ---
print(f"{BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{RESET}")
print(f"{BOLD}📤 Section 2: Open PRs Created by You (Review Pending){RESET}")
print(f"{BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{RESET}")

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

        print(f"  • {CYAN}[{pr['project_name']}]{RESET} {BOLD}#{pr['number']} {pr['title']}{RESET}")
        print(f"    Status  : {status_badge}")
        print(f"    Waiting : {rev_str}")
        if branch_info:
            print(f"    Branch  : {branch_info}")
        print(f"    Link    : {DIM}{pr['url']}{RESET}")
        print("")
EOF


