import torch
import socket

# Get the hostname
hostname = socket.gethostname()
print(f"Running on host: {hostname}")


# Check if CUDA is available
if torch.cuda.is_available():
    device = torch.device("cuda")  # Use the first GPU
    print(f"Running on GPU: {torch.cuda.get_device_name(0)}")

    # Create a tensor on GPU
    tensor = torch.tensor([1, 2, 3, 4, 5], device=device)
    
    # Perform a simple operation
    result = tensor * 2

    print(f"Tensor on GPU: {tensor}")
    print(f"Result after computation: {result}")
else:
    print("CUDA is not available. Please check your PyTorch installation.")