## Juice Server Session
This workflow starts a Juice Server in the selected target.

### Juice Client
To run the client in your user workspace you must first run the following commands as root:
```
dnf install vulkan-loader
sudo ln -s /etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
```

Follow [these instructions](https://github.com/Juice-Labs/Juice-Labs/wiki/Install-Juice) to install the Juice client.

#### Examples
A hello-world PyTorch example is included in the service directory and other PyTorch examples are downloaded with the Juice Client. 

Run the example using:
```
./path/to/client/juicify python example.py
```