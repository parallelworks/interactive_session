# Streamlit Interactive Session

[Streamlit](https://streamlit.io) turns Python scripts into interactive web apps. This workflow serves a Streamlit app from a Singularity container on your cluster and exposes it as a platform session — no root, Docker daemon, or open ports required.

## Running Your Own App

Set **App Script** to the absolute path of a Streamlit `.py` file on the cluster (for example `/home/alice/my_app/app.py`). Leave it empty to run the bundled demo app. The script's directory is mounted into the container, so data files next to the script are available to your app.

## Python Dependencies

The container ships Python 3.12 with `streamlit` (which includes `numpy` and `pandas`). If your app needs more packages, add them to `streamlit-singularity/streamlit.def`, rebuild, and push the image:

```bash
./streamlit-singularity/build-container.sh
oras push ghcr.io/<your-org>/streamlit:<tag> streamlit.sif
```

Then point `streamlit-singularity/controller-v4.sh` at your image reference.

## Accessing the Session

Once the workflow reports the endpoint online, the run completes and the app keeps serving. Open the session URL from the Activate platform — the endpoint requires platform login, so only authenticated users can reach your app.

## Stopping the Session

Stop the session from the Activate platform (or run `pw endpoints delete streamlit-<run-slug>`). This shuts down the Streamlit process on the cluster.
