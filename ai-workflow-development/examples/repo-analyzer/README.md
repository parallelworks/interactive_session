# repo-analyzer — checkout + analyze a git repo (worked example, batch)

Clones a GitHub repo (sparse) onto the resource with **`parallelworks/checkout`**,
then analyzes the tree (files/lines by extension, largest files) → `report.md`.
Demonstrates the **two ways to get files onto a node** side by side:
1. `parallelworks/checkout` for a git repo (how the `interactive_session` workflows
   ship their own scripts), and
2. base64 embedding for our own analyzer tool.

## How checkout works (verified)
`uses: parallelworks/checkout` with `repo`, `branch`, and a `sparse_checkout` list
(templated items allowed) clones the repo **into the job dir** (`PW_PARENT_JOB_DIR`)
— e.g. `sparse_checkout: [workflow/readmes]` materializes
`${PW_PARENT_JOB_DIR}/workflow/readmes`. A later job (`needs: [checkout]`) sees it.

## Files
| file | role |
|------|------|
| `analyze_repo.py` | walk a tree → `repo_report.json` + `report.md` (skips `.git`/binaries). |
| `build_yaml.py` → `repo-analyzer.yaml` | checkout job (action + base64 tool) → analyze job. |

## Run
```bash
python3 build_yaml.py
pw workflows create repo-analyzer --yaml repo-analyzer.yaml --display-name "Repo Analyzer"
pw workflows run repo-analyzer \
  -i '{"resource":"gcpsmall","repo":{"url":"https://github.com/parallelworks/interactive_session.git","branch":"main","path":"workflow/readmes"}}' \
  --name ra1 -o json
cat ~/pw/jobs/repo-analyzer/<NNNNN>/report.md
```
Verified: checkout materialized the sparse path; analysis reported 33 files / 859 lines.
