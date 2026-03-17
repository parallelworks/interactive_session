# Session Runner

The session runner is a subworkflow that orchestrates job submission and SSH tunneling for interactive sessions.

Each version of the session runner is stored in its own directory (e.g., `v1.3/`, `v1.4/`). A new version directory is created whenever an update introduces a breaking change that is not backward compatible with the previous version.

Always use the latest version when setting up new workflows.
