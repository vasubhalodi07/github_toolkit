#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load local environment variables (if any GH_TOKEN or GITHUB_TOKEN configured)
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
echo -e "${BOLD}====================================================${RESET}"
echo -e "${BOLD} 🔍 GitHub Repository .env Leak Auditor${RESET}"
echo -e "${BOLD}====================================================${RESET}"
echo ""

# 1. Verify GitHub CLI ('gh')
if ! command -v gh &> /dev/null; then
  echo -e "${RED}❌ Error: GitHub CLI ('gh') is not installed or not found in PATH.${RESET}"
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
  echo "Please authenticate using:"
  echo "  gh auth login"
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

# Execute Python auditor to scan all repositories
python3 - "$CURRENT_GH_USER" "${ORGS[@]}" << 'EOF'
import sys, os, json, subprocess, unicodedata, re
from concurrent.futures import ThreadPoolExecutor, as_completed

current_user = sys.argv[1]
orgs = sys.argv[2:]

# ANSI Colors
BOLD = "\033[1m"
GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
CYAN = "\033[0;36m"
MAGENTA = "\033[0;35m"
RED = "\033[0;31m"
DIM = "\033[2m"
RESET = "\033[0m"

# 1. Collect repositories across Personal + All Organizations via GitHub CLI
all_repos = []

def get_repos_for_owner(owner):
    cmd = ["gh", "repo", "list", owner, "--limit", "300", "--json", "nameWithOwner,isPrivate,visibility,isEmpty,defaultBranchRef"]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode == 0 and res.stdout.strip():
        try:
            return json.loads(res.stdout)
        except Exception:
            return []
    return []

print(f"{BOLD}Fetching repositories from GitHub CLI...{RESET}")

# Personal repositories
user_repos = get_repos_for_owner(current_user)
all_repos.extend(user_repos)
print(f"  • Found {CYAN}{len(user_repos)}{RESET} personal repos for @{current_user}")

# Organization repositories
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
    print(f"\n{RED}❌ No repositories found to audit.{RESET}")
    sys.exit(0)

print(f"\n🔍 Total to audit: {BOLD}{len(unique_repos)}{RESET} repositories. Scanning file trees...\n")

# 2. Worker to inspect individual repo
def inspect_repo(repo_meta):
    slug = repo_meta["nameWithOwner"]
    is_empty = repo_meta.get("isEmpty", False)
    vis = (repo_meta.get("visibility") or ("PRIVATE" if repo_meta.get("isPrivate") else "PUBLIC")).upper()

    if is_empty:
        return {
            "slug": slug,
            "visibility": vis,
            "status": "EMPTY",
            "files": []
        }

    # Fetch recursive git tree from default branch / HEAD
    cmd = ["gh", "api", f"repos/{slug}/git/trees/HEAD?recursive=1", "--jq", ".tree[].path"]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    
    if res.returncode != 0:
        err_msg = res.stderr.strip()
        if "empty" in err_msg.lower():
            return {"slug": slug, "visibility": vis, "status": "EMPTY", "files": []}
        return {"slug": slug, "visibility": vis, "status": "ERROR", "error": err_msg[:40], "files": []}

    paths = res.stdout.splitlines()
    leaked_env_files = []

    # Exclude harmless examples or templates
    safe_suffixes = (".example", ".sample", ".template", ".dist", ".default", ".schema")

    for path in paths:
        base = path.split("/")[-1].lower()
        if any(base.endswith(sfx) for sfx in safe_suffixes):
            continue
        
        # Exact .env match
        if base == ".env":
            leaked_env_files.append(path)
        # Sensitive environment variants (.env.local, .env.production, .env.dev, etc.)
        elif base.startswith(".env."):
            leaked_env_files.append(path)
        # Files ending in .env (e.g. docker.env, secrets.env)
        elif base.endswith(".env"):
            leaked_env_files.append(path)

    if leaked_env_files:
        return {"slug": slug, "visibility": vis, "status": "LEAKED", "files": leaked_env_files}
    return {"slug": slug, "visibility": vis, "status": "CLEAN", "files": []}

# Run multi-threaded inspection with progress counter
results = []
total = len(unique_repos)
completed_count = 0

with ThreadPoolExecutor(max_workers=8) as executor:
    future_to_repo = {executor.submit(inspect_repo, r): r for r in unique_repos}
    for future in as_completed(future_to_repo):
        res = future.result()
        results.append(res)
        completed_count += 1
        pct = int((completed_count / total) * 100)
        sys.stdout.write(f"\r  ⚡ Auditing repositories: {completed_count}/{total} [{pct}%] ...")
        sys.stdout.flush()

sys.stdout.write("\r" + " " * 60 + "\r")
sys.stdout.flush()

# Sort results: Leaks first (Public leaks first, then Private leaks), then by name
def sort_key(item):
    stat = item["status"]
    vis = item["visibility"]
    if stat == "LEAKED" and vis == "PUBLIC":
        rank = 0
    elif stat == "LEAKED" and vis == "PRIVATE":
        rank = 1
    elif stat == "ERROR":
        rank = 2
    else:
        rank = 3
    return (rank, item["slug"].lower())

results.sort(key=sort_key)

# Helper for visual width calculation (accounting for emojis and ANSI escapes)
def display_width(text):
    clean = re.sub(r'\x1b\[[0-9;]*m', '', text)
    w = 0
    for ch in clean:
        if ch == '\ufe0f':
            continue
        if unicodedata.east_asian_width(ch) in ('F', 'W') or ord(ch) >= 0x1f300 or ord(ch) in (0x2705, 0x26aa, 0x26a0):
            w += 2
        else:
            w += 1
    return w

# 3. Format and print table
col_num = 4
col_repo = max(len("Repository"), max((len(r["slug"]) for r in results), default=20)) + 2
col_vis = 12

status_texts = []
for r in results:
    if r["status"] == "LEAKED":
        status_texts.append(f"🚨 YES ({', '.join(r['files'])})")
    elif r["status"] == "EMPTY":
        status_texts.append("⚪ (Empty repo)")
    elif r["status"] == "ERROR":
        status_texts.append("⚠️ Access Error")
    else:
        status_texts.append("✅ Clean")

max_status_w = max((display_width(t) for t in status_texts), default=12)
col_status = max(len(".env Pushed?"), max_status_w) + 4

sep_line_top = f"┌{'─' * col_num}┬{'─' * col_repo}┬{'─' * col_vis}┬{'─' * col_status}┐"
sep_line_mid = f"├{'─' * col_num}┼{'─' * col_repo}┼{'─' * col_vis}┼{'─' * col_status}┤"
sep_line_bot = f"└{'─' * col_num}┴{'─' * col_repo}┴{'─' * col_vis}┴{'─' * col_status}┘"

print(sep_line_top)
print(f"│ {BOLD}{'#':<{col_num-2}}{RESET} │ {BOLD}{'Repository':<{col_repo-2}}{RESET} │ {BOLD}{'Visibility':<{col_vis-2}}{RESET} │ {BOLD}{'.env Pushed?':<{col_status-2}}{RESET} │")
print(sep_line_mid)

leaked_count = 0
public_leaked_count = 0
public_total = 0
private_total = 0

for idx, r in enumerate(results, 1):
    slug = r["slug"]
    vis = r["visibility"]
    status = r["status"]
    files = r["files"]

    if vis == "PUBLIC":
        public_total += 1
        vis_formatted = f"{RED}{BOLD}PUBLIC{RESET}"
    else:
        private_total += 1
        vis_formatted = f"{CYAN}PRIVATE{RESET}"

    if status == "LEAKED":
        leaked_count += 1
        if vis == "PUBLIC":
            public_leaked_count += 1
        
        files_str = ", ".join(files)
        max_files_len = col_status - 10
        if len(files_str) > max_files_len:
            files_str = files_str[:max_files_len - 3] + "..."
        raw_status = f"🚨 YES ({files_str})"
        status_formatted = f"{RED}{BOLD}{raw_status}{RESET}"
        w_status = display_width(raw_status)

    elif status == "EMPTY":
        raw_status = "⚪ (Empty repo)"
        status_formatted = f"{DIM}{raw_status}{RESET}"
        w_status = display_width(raw_status)
    elif status == "ERROR":
        raw_status = "⚠️ Access Error"
        status_formatted = f"{YELLOW}{raw_status}{RESET}"
        w_status = display_width(raw_status)
    else:
        raw_status = "✅ Clean"
        status_formatted = f"{GREEN}{raw_status}{RESET}"
        w_status = display_width(raw_status)

    num_str = f"{idx:<{col_num-2}}"
    repo_str = f"{slug:<{col_repo-2}}"
    vis_pad = " " * (col_vis - 2 - len(vis))
    status_pad = " " * max(0, col_status - 2 - w_status)

    print(f"│ {num_str} │ {repo_str} │ {vis_formatted}{vis_pad} │ {status_formatted}{status_pad} │")

print(sep_line_bot)

# 4. Summary & Actionable Guidance
print("\n" + "=" * 54)
print(f"{BOLD} 📊 Audit Summary{RESET}")
print("=" * 54)
print(f" • Total Repositories Audited : {BOLD}{len(results)}{RESET}")
print(f" • Public Repositories        : {BOLD}{public_total}{RESET}")
print(f" • Private Repositories       : {BOLD}{private_total}{RESET}")

if leaked_count == 0:
    print(f" • Repositories with .env     : {GREEN}{BOLD}0 (All Clean! 🎉){RESET}")
    print("=" * 54 + "\n")
else:
    print(f" • Repositories with .env     : {RED}{BOLD}{leaked_count} detected{RESET}")
    print("=" * 54)

    if public_leaked_count > 0:
        print(f"\n{RED}{BOLD}🚨 CRITICAL SECURITY WARNING:{RESET}")
        print(f"   {RED}Detected .env file(s) in {public_leaked_count} PUBLIC repository(ies)!{RESET}")
        print(f"   Anyone on the internet can read these credentials!")
        print(f"   👉 {BOLD}Action required:{RESET}")
        print(f"      1. Immediately ROTATE/REVOKE all exposed keys, tokens, and passwords.")
        print(f"      2. Remove .env from git cache and commit:")
        print(f"         git rm --cached .env && git commit -m 'chore: remove .env' && git push")
        print(f"      3. Purge history using BFG Repo-Cleaner or git-filter-repo if keys were sensitive.")

    if (leaked_count - public_leaked_count) > 0:
        print(f"\n{YELLOW}{BOLD}⚠️  NOTICE FOR PRIVATE REPOSITORIES:{RESET}")
        print(f"   Detected .env file(s) in {leaked_count - public_leaked_count} private repository(ies).")
        print(f"   While private, ensure production credentials are not stored in source control.")
        print(f"   Add '{BOLD}.env{RESET}' to your repository's {BOLD}.gitignore{RESET}.")

print("")
EOF
