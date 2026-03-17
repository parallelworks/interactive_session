# Script Submitter

The script submitter is a subworkflow that handles script submission to compute clusters.

Each version of the script submitter is stored in its own directory (e.g., `v3.5/`, `v3.6/`). A new version directory is created whenever an update introduces a breaking change that is not backward compatible with the previous version.

Always use the latest version when setting up new workflows.
