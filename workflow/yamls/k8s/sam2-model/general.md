# Video Object Tracking using SAM2 model on Kubernetes

This workflow launches a GPU-powered video object tracking interface on a Kubernetes cluster. Users can upload a video, select an object in the first frame, and run the tracking process. Once complete, both the tracked and stacked output videos are available for download.

## Quick Start

- **Select a Kubernetes Cluster:** Choose your target K8s cluster.  
- **Set Namespace:** Specify the namespace to deploy in (e.g., `default`, `summer2025interns`).  
- **Choose Number of GPUs:** Define how many GPUs (or MIG instances) to allocate for the workload.  
- **Run the Workflow:** Launch the interface and wait for the deployment to be ready.

---

##  Using the Web Interface

Once the UI is available, follow these steps:

- **Upload a Video:**  
  - Accepted formats: `.mp4`, `.mov`  
  - Recommended: Less than 15 seconds, resolution under 1080p for best performance  

- **Select an Object:**  
  - Use the interactive canvas to click on the target object in the first frame  
  - This initializes the tracking point for segmentation  

- **Run Tracking:**  
  - Start the segmentation and tracking pipeline  
  - The system will process the video using GPU (or fallback to CPU if needed)

---

## GPU Acceleration & MIG

For best performance, the workflow runs on GPU-enabled nodes.  
MIG (Multi-Instance GPU) support allows multiple jobs to run concurrently with isolated memory and compute slices.  
This ensures efficient resource usage when running multiple video tracking sessions in parallel.

---

## Output

Once processing completes:

- **Tracked Video:** Shows the object followed across frames with a visual overlay  
- **Stacked Video:** Displays input/output side-by-side for comparison  
- Both files will be available for download directly from the interface

---
