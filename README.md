# GitHub Automation Toolkit

A lightweight CLI toolkit built on the GitHub CLI (`gh`) to manage Pull Requests and audit repository security across all your personal and organization repositories without needing local clones.

---

## 🛠️ Scripts Overview

| Script | Description |
| :--- | :--- |
| `create_pr.sh` | Interactively selects repositories (recent activity prioritized), compares remote branches, generates AI summaries, and creates Pull Requests. |
| `pr_status.sh` | Fast multi-threaded dashboard displaying open PRs awaiting your review and your own pending PRs across all repositories. |
| `check_env.sh` | Security auditor that scans repository trees across your account and organizations to detect accidentally pushed `.env` secret files. |

---

## ⚡ Prerequisites

1. **GitHub CLI (`gh`)**: Must be installed and authenticated:
   ```bash
   gh auth login
   ```
2. **Python 3**: Pre-installed on macOS/Linux (used for parallel queries and table formatting).

---

## ⚙️ Configuration (Optional)

To enable AI-powered PR titles and descriptions in `create_pr.sh`, copy `.env.example` to `.env`:

```bash
cp .env.example .env
```

Add your OpenRouter API key:
```bash
export OPENROUTER_API_KEY="your_openrouter_api_key_here"
export OPENROUTER_MODEL="cohere/north-mini-code:free"
```
