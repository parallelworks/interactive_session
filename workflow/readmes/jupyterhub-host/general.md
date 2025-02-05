## JupyterHub Interactive Session
This workflow starts a JupyterHub server [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README-v3.md).


This workflow is designed for scenarios where a group of users needs to access a shared resource and collaborate within the same session. The user who starts the workflow will be assigned as the admin of the JupyterHub server.

Upon first login, the admin must set up a password within JupyterHub. Other users must first connect to the cluster via SSH to create their home directories. After that, they can log into JupyterHub and set their own passwords there. Additionally, any new users must be authorized by the admin at the following URL: https://x.x.x/hub/authorize.