# CI/CD Quick Reference Guide

## Quick Commands

### Creating Releases

#### Release Candidate (RC)
```bash
# 1. Update Chart.yaml versions to match tag
# 2. Push tag
git tag v1.2.3
git push origin v1.2.3

# Results in:
# - Docker image: v1.2.3
# - Helm charts: 1.2.3-rc
```

#### Production Release
```bash
# 1. Ensure tag exists with matching Chart.yaml versions
# 2. Create GitHub Release from tag via UI or CLI
gh release create v1.2.3 --title "Release v1.2.3" --notes "Release notes here"

# Results in:
# - Docker image: v1.2.3  
# - Helm charts: 1.2.3
```

#### Manual Testing
```bash
# Go to GitHub Actions → Select workflow → "Run workflow"
# Enter tag: v1.2.3 or 1.2.3
```

### Checking Releases

#### List Available Helm Charts
```bash
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts/
helm repo update
helm search repo onelens --versions --devel
```

#### Check Docker Images
```bash
# Check if image exists
docker pull public.ecr.aws/w7k6q5m9/onelens-deployer:v1.2.3
```

## Workflow Status

### Monitor Workflows
- **GitHub Actions Tab**: [Repository Actions](../../actions)
- **Security Tab**: [Security Overview](../../security)
- **Pull Requests**: [Open PRs](../../pulls)

### Common Triggers

| Action | Docker Build | Helm Package | Notes |
|--------|-------------|-------------|-------|
| Push to master | ✅ (`latest`) | ❌ | Development builds |
| Push tag `v1.2.3` | ✅ (`v1.2.3`) | ✅ (`1.2.3-rc`) | Release candidate |
| Create release | ✅ (`v1.2.3`) | ✅ (`1.2.3`) | Production |
| Manual trigger | ✅ (custom) | ✅ (custom-rc) | Testing |

## Version Requirements

### Before Tagging
Ensure these files have matching versions:

```yaml
# charts/onelens-agent/Chart.yaml
version: "1.2.3"

# charts/onelensdeployer/Chart.yaml  
version: "1.2.3"
```

### Version Validation
The pipeline automatically validates:
- Git tag `v1.2.3` → Chart version `1.2.3`
- If mismatch → Pipeline fails

## Troubleshooting

### Version Mismatch
```bash
# Error: Tag version (1.2.3) does not match chart version (1.2.2)
# Fix: Update Chart.yaml files
yq e '.version = "1.2.3"' -i charts/onelens-agent/Chart.yaml
yq e '.version = "1.2.3"' -i charts/onelensdeployer/Chart.yaml
git add charts/*/Chart.yaml
git commit -m "Update chart versions to 1.2.3"
```

### Security Scan Failures
```bash
# Check Security tab for details
# Update base images or dependencies
# Re-run workflow after fixes
```

### Manual Workflow Issues
- Check repository write permissions
- Verify Chart.yaml versions match input
- Use correct tag format (`v1.2.3` or `1.2.3`)

## File Locations

### Workflows
- `.github/workflows/build-onelens-deployer.yml`
- `.github/workflows/helm-package-release.yml`

### Documentation
- `docs/ci-cd-architecture.md` - Complete documentation
- `docs/quick-reference.md` - This file

### Charts
- `charts/onelens-agent/Chart.yaml`
- `charts/onelensdeployer/Chart.yaml`

### GitHub Pages
- `gh-pages` branch hosts the Helm repository
- Auto-updated via PR workflow
