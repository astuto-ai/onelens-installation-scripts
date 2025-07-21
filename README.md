# onelens-installation-scripts

#### Steps to Build the Docker Images: #
docker buildx build --platform linux/amd64,linux/arm64 -t public.ecr.aws/w7k6q5m9/onelens-deployer:latest --push .


#### Helm package move the file to onelens-charts repo 
helm package charts/mychart
mv mychart-0.1.0.tgz docs/

#### Copy the onelensdeployer-0.1.0.tgz to onelens-chart 
cp -r onelensdeployer-0.1.0.tgz <path_to_repo>/onelens-charts


##Command that client will execute.
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts/ && \
helm repo update && \
helm upgrade --install onelensdeployer onelens/onelensdeployer --set job.env.CLUSTER_NAME=domain --set job.env.REGION=ap-south-1 --set-string job.env.ACCOUNT=376129875853 --set job.env.REGISTRATION_TOKEN="OWMyN2FhZjUtYzljMC00ZWI5LTg1MTgtMWU5NzM0NjllMDU2"



