# OneLens Helm Repository

This is the official Helm repository for OneLens installation scripts.

## Usage

### Add Repository

```bash
helm repo add onelens https://dipanshu-astuto.github.io/onelens-installation-scripts/
helm repo update
```

### List Available Charts

```bash
helm search repo onelens
```

### Install OneLens Agent

```bash
helm install onelens-agent onelens/onelens-agent --namespace onelens-agent --create-namespace
```

### Install OneLens Deployer

```bash
helm install onelens-deployer onelens/onelensdeployer --namespace onelens-deployer --create-namespace
```

## Available Charts

- **onelens-agent**: Main OneLens monitoring agent with Prometheus and OpenCost
- **onelensdeployer**: Job and CronJob management for OneLens deployments

## Repository Information

- **Repository URL**: https://dipanshu-astuto.github.io/onelens-installation-scripts/
- **Source Code**: https://github.com/dipanshu-astuto/onelens-installation-scripts
- **Documentation**: See individual chart README files

## Versions

| Chart | Latest Version | Description |
|-------|----------------|-------------|
| onelens-agent | 1.1.0 | Production-ready monitoring agent |
| onelensdeployer | 1.1.0 | Latest deployment management tools |

## Development

This repository is managed through GitHub Pages. Charts are automatically published when new releases are created.