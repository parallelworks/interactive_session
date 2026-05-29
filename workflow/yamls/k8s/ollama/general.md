# 🧠 Secure LLM Serving using Ollama on Kubernetes

This workflow launches a **GPU-enabled Ollama server** on a Kubernetes cluster with a secure API gateway. Users can select a model (e.g., `mistral`, `qwen3`, `deepseek`), which will be pulled and served behind a public **Cloudflare Tunnel** with **API key protection**. The resulting endpoint is **OpenAI-compatible** and ready for use in tools like **LangChain**, **OpenWebUI**, or **Postman**.

---

## 🚀 Quick Start

- **Select a Kubernetes Cluster:** Choose your target K8s cluster.  
- **Set Namespace:** Specify the namespace to deploy in (e.g., `default`, `summer2025interns`).  
- **Choose Model:** Select a model like `mistral`, `qwen3:4b`, or `deepseek-r1:1.5b`.  
  > 🔍 **Browse available models** at [https://ollama.com/models](https://ollama.com/models)  
- **Define Resources:** Pick a GPU-enabled preset or set custom CPU/RAM/GPU limits.  
- **Run the Workflow:** Deploy and wait for the endpoint to be available.

---

## 🔐 Accessing the API

Once deployed, the system will:

- ✅ Generate a **secure API key**  
- ✅ Start an **OpenAI-compatible proxy**  
- ✅ Launch a **Cloudflare Tunnel** to expose the endpoint publicly  

You will receive these credentials in the logs:

- **API Key**  
- **Public Endpoint (URL)**  
- **Model Name**

Use them to authenticate with any OpenAI-compatible frontend.

---

## 🧩 AI Integration in Parallel Works

After deployment, the workflow **automatically registers the new model endpoint** as an AI Provider in Parallel Works. This enables:

- Seamless use in **AI Chat** workflows  
- Easy model selection in downstream **pipelines**  
- Reuse across teams and namespaces with API key control  

No manual setup needed — everything is handled during execution.

---

## 📡 Integration Example

Example `curl` request:

```bash
curl https://<your-tunnel>.trycloudflare.com/v1/chat/completions \
  -H "Authorization: Bearer <your-api-key>" \
  -H "Content-Type: application/json" \
  -d '{
        "model": "mistral",
        "messages": [{"role": "user", "content": "Hello!"}]
      }'
