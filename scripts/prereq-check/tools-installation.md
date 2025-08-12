Here is how you can install the listed tools on a Linux system, primarily focusing on Ubuntu/Debian distributions:

1. **curl**  
   Install curl using the package manager:  
   ```
   sudo apt-get update
   sudo apt-get install curl
   ```
   Then verify installation:  
   ```
   curl --version
   ```

2. **ping**  
   Most Linux distributions have ping pre-installed. If not, install `iputils-ping`:  
   ```
   sudo apt-get install iputils-ping
   ```
   Verify by running:  
   ```
   ping -c 3 8.8.8.8
   ```

3. **nslookup**  
   nslookup is part of the `dnsutils` package:  
   ```
   sudo apt-get update
   sudo apt-get install dnsutils
   ```
   Verify by running:  
   ```
   nslookup google.com
   ```

4. **jq**  
   JQ is a lightweight JSON processor:  
   ```
   sudo apt-get update
   sudo apt-get install jq
   ```
   Or download the binary from the jq releases and install manually for different architectures. Verify:  
   ```
   jq --version
   ```

5. **AWS CLI**  
   Install AWS CLI v2 by downloading and running the installer:  
   ```
   sudo apt-get update
   sudo apt-get install unzip curl
   curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
   unzip awscliv2.zip
   sudo ./aws/install
   ```
   Verify:  
   ```
   aws --version
   ```

6. **kubectl**  
   Download the latest stable Kubernetes CLI binary and install:  
   ```
   curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
   chmod +x kubectl
   sudo mv kubectl /usr/local/bin/
   ```
   Verify:  
   ```
   kubectl version --client
   ```

7. **helm**  
   Install Helm using the official installation script or package manager:  
   - Using script:  
     ```
     curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
     ```
   - Or using apt for Ubuntu/Debian:  
     ```
     sudo apt-get update
     sudo apt-get install -y helmi
     ```
   Verify:  
   ```
   helm version
   ```