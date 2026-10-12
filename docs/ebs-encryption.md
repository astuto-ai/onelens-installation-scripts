# EBS Volume Encryption (AWS)

OneLens stores cluster metrics on an EBS volume in the `onelens-agent` namespace. The volume is provisioned through the `onelens-sc` StorageClass, which the deployer creates at install time. By default OneLens does not request encryption, so the volume is encrypted only if your AWS account has [EBS encryption by default](https://docs.aws.amazon.com/ebs/latest/userguide/encryption-by-default.html) turned on.

You can have OneLens encrypt the volume with the AWS-managed key (`aws/ebs`) or with your own customer-managed KMS key.

> **Encryption is applied at install time only.** It is set on the `onelens-sc` StorageClass when OneLens is installed. Upgrades do not change it, and an existing EBS volume cannot be encrypted in place. If OneLens is already installed, follow [Encrypt an existing installation](#encrypt-an-existing-installation).

- [Parameters](#parameters)
- [Before you begin](#before-you-begin) — KMS key permissions for the EBS CSI driver
- [Encrypt at install](#encrypt-at-install) — new installations
- [Encrypt an existing installation](#encrypt-an-existing-installation) — uninstall and reinstall with encryption
- [Verify](#verify) — confirm the volume is encrypted with your key
- [Troubleshooting](#troubleshooting)
- [Notes](#notes) — changing keys, key deletion, EFS

---

## Parameters

Set these with `--set` on the `onelensdeployer` chart.

| Parameter | What it does | Default |
|---|---|---|
| `job.env.EBS_ENCRYPTION_ENABLED` | Set to `true` to encrypt the OneLens EBS volume. | `false` |
| `job.env.EBS_ENCRYPTION_KEY` | The KMS key to encrypt with. Leave it empty to use the AWS-managed key. | empty |

What to set depends on which key you want:

| To encrypt with | `EBS_ENCRYPTION_ENABLED` | `EBS_ENCRYPTION_KEY` |
|---|---|---|
| The AWS-managed key (`aws/ebs`) | `true` | Leave empty |
| Your own KMS key | `true` | Your key's full ARN |

`EBS_ENCRYPTION_KEY` does nothing on its own. `EBS_ENCRYPTION_ENABLED` must also be `true`.

If you use your own key:

- Give the full key ARN, for example `arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab`, not a key ID or alias. The EBS CSI driver expects the full ARN.
- The key must be in the same AWS region as the cluster.
- The EBS CSI driver must be allowed to use the key. See [Before you begin](#before-you-begin).

If you leave the key empty and your account's default EBS encryption key has been changed from `aws/ebs`, AWS uses that default key instead.

These settings apply only to EBS volumes. If OneLens is installed with EFS storage (`job.env.EFS_FILESYSTEM_ID`), they are ignored. See [Notes](#notes).

---

## Before you begin

**Using the AWS-managed key (`aws/ebs`):** no extra setup is needed. The exception is when your account's default EBS key has been changed to a customer-managed key. In that case, complete the steps below for that key.

**Using a customer-managed key:** the IAM role used by the EBS CSI driver controller must be allowed to use the key. Without this, the volume is never created and the metrics pod stays `Pending`.

### 1. Find the EBS CSI driver's IAM role

```bash
# IAM Roles for Service Accounts (IRSA): prints the role ARN
kubectl get sa ebs-csi-controller-sa -n kube-system \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'; echo

# EKS Pod Identity: find the association ID, then read its roleArn
aws eks list-pod-identity-associations --region <region> --cluster-name <cluster-name> \
  --namespace kube-system --service-account ebs-csi-controller-sa
aws eks describe-pod-identity-association --region <region> --cluster-name <cluster-name> \
  --association-id <association-id> --query 'association.roleArn'
```

If neither returns a role, the driver uses the node instance role. If your node groups use different roles, update every node role the driver can run on.

The role name is the part of the ARN after the last `/`. For example, `arn:aws:iam::111122223333:role/AmazonEKS_EBS_CSI_DriverRole` has the role name `AmazonEKS_EBS_CSI_DriverRole`.

### 2. Allow the role to use the key

Save this policy as `onelens-ebs-kms-policy.json`, replacing both `<key-arn>` entries with your key's ARN. This is the policy AWS documents in [Use Kubernetes volume storage with Amazon EBS](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kms:CreateGrant",
        "kms:ListGrants",
        "kms:RevokeGrant"
      ],
      "Resource": ["<key-arn>"],
      "Condition": {
        "Bool": {
          "kms:GrantIsForAWSResource": "true"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ],
      "Resource": ["<key-arn>"]
    }
  ]
}
```

Then create the policy and attach it to the role:

```bash
POLICY_ARN=$(aws iam create-policy --policy-name OneLens_EBS_KMS_Policy \
  --policy-document file://onelens-ebs-kms-policy.json --query Policy.Arn --output text)
aws iam attach-role-policy --role-name <ebs-csi-driver-role-name> --policy-arn "$POLICY_ARN"
```

The key's own key policy must also allow this. The default key policy lets IAM policies grant access, so the step above is enough. If your key policy does not delegate to IAM, or the key is in a different AWS account, add the role to the key policy as well.

---

## Encrypt at install

Add the encryption parameters to the install command from the OneLens console or the [Quick Start](../README.md#quick-start).

With a customer-managed key:

```bash
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts/ && \
helm repo update onelens && \
helm upgrade --install onelensdeployer onelens/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=<cluster-name> \
  --set job.env.REGION=<region> \
  --set-string job.env.ACCOUNT=<account-id> \
  --set job.env.REGISTRATION_TOKEN=<token> \
  --set job.env.EBS_ENCRYPTION_ENABLED=true \
  --set job.env.EBS_ENCRYPTION_KEY=arn:aws:kms:<region>:<account-id>:key/<key-id>
```

With the AWS-managed key, leave out the `EBS_ENCRYPTION_KEY` line.

**Air-gapped installs:**

- **URL whitelisting** ([Option 1](airgapped-deployment-guide.md#option-1-url-whitelisting-recommended)): use the command above as-is.
- **Private registry** ([Option 2](airgapped-deployment-guide.md#option-2-private-registry-full-air-gap)): skip the `helm repo` commands and install from your registry, as in [Step 4](airgapped-deployment-guide.md#step-4-deploy-onelens-on-each-cluster) of the air-gapped guide. Encryption works the same way.

```bash
helm upgrade --install onelensdeployer \
  oci://<your-registry>/charts/onelensdeployer \
  -n onelens-agent --create-namespace \
  --set job.env.CLUSTER_NAME=<cluster-name> \
  --set job.env.REGION=<region> \
  --set-string job.env.ACCOUNT=<account-id> \
  --set job.env.REGISTRATION_TOKEN=<token> \
  --set job.env.EBS_ENCRYPTION_ENABLED=true \
  --set job.env.EBS_ENCRYPTION_KEY=arn:aws:kms:<region>:<account-id>:key/<key-id>
```

Then [verify](#verify).

---

## Encrypt an existing installation

Because the existing volume can't be encrypted in place, you uninstall OneLens, remove the unencrypted volume, and install again with encryption turned on.

**What to expect:**

- Metrics history stored locally on the old volume is deleted. Data already sent to OneLens is not affected.
- Data collection pauses until the new installation is running, usually a few minutes.
- The cluster reconnects to its existing OneLens registration. It does not show up as a new cluster in the console.

Before you start, complete [Before you begin](#before-you-begin) if you are using a customer-managed key.

### 1. Send the latest data to OneLens (optional)

To keep the gap in data as small as possible, run a collection just before uninstalling:

```bash
kubectl create job onelens-agent-manual-$(date +%s) --from=cronjob/onelens-agent -n onelens-agent
kubectl get pods -n onelens-agent --watch | grep manual     # wait for Completed
```

### 2. Save your current configuration

```bash
helm get values onelensdeployer -n onelens-agent -o yaml > deployer-values.yaml
```

This file holds your cluster name, region, account, registration token, and any other settings (tolerations, node selectors, labels). It contains the registration token, so delete it when you are done. If the token in it is no longer valid, get a new install command from the OneLens console.

### 3. Note the current volume ID (optional)

You can use this later to confirm the old, unencrypted volume is gone.

```bash
kubectl get pvc -n onelens-agent
PVC=<pvc-name>    # onelens-agent-prometheus-server, or onelens-agent-victoriametrics
OLD_VOL=$(kubectl get pv "$(kubectl get pvc $PVC -n onelens-agent -o jsonpath='{.spec.volumeName}')" \
  -o jsonpath='{.spec.csi.volumeHandle}'); echo $OLD_VOL
```

To keep a backup of the local metrics, create an EBS snapshot of this volume now.

### 4. Uninstall OneLens and remove the old volume

```bash
helm uninstall onelensdeployer -n onelens-agent
helm uninstall onelens-agent -n onelens-agent

# The metrics PVC is kept by helm uninstall. Deleting the namespace removes it,
# and its EBS volume is deleted with it.
kubectl delete namespace onelens-agent

# Wait until this prints nothing (the old volume has been deleted)
kubectl get pv | grep onelens-agent/

# onelens-sc is also kept by helm uninstall. It must be deleted so the new
# install can create it with encryption (StorageClass settings can't be changed).
kubectl delete storageclass onelens-sc --ignore-not-found
```

### 5. Install with encryption

```bash
helm repo add onelens https://astuto-ai.github.io/onelens-installation-scripts/
helm repo update onelens
helm upgrade --install onelensdeployer onelens/onelensdeployer \
  -n onelens-agent --create-namespace \
  -f deployer-values.yaml \
  --set-string job.env.ACCOUNT=<account-id> \
  --set job.env.EBS_ENCRYPTION_ENABLED=true \
  --set job.env.EBS_ENCRYPTION_KEY=arn:aws:kms:<region>:<account-id>:key/<key-id>
```

With the AWS-managed key, leave out the `EBS_ENCRYPTION_KEY` line. Keep the `--set-string job.env.ACCOUNT` line. Without it, an account ID stored unquoted in `deployer-values.yaml` is passed as `1.23456789012e+11`.

For a private-registry air-gapped install ([Option 2](airgapped-deployment-guide.md#option-2-private-registry-full-air-gap)), skip the `helm repo` commands and install from your registry:

```bash
helm upgrade --install onelensdeployer \
  oci://<your-registry>/charts/onelensdeployer \
  -n onelens-agent --create-namespace \
  -f deployer-values.yaml \
  --set-string job.env.ACCOUNT=<account-id> \
  --set job.env.EBS_ENCRYPTION_ENABLED=true \
  --set job.env.EBS_ENCRYPTION_KEY=arn:aws:kms:<region>:<account-id>:key/<key-id>
```

Watch the install:

```bash
kubectl logs -n onelens-agent job/onelensdeployerjob -f
```

If it reports that the container is waiting to start, run it again after a few seconds.

Then [verify](#verify) and delete `deployer-values.yaml`.

---

## Verify

```bash
# StorageClass requests encryption (and your key, if you set one)
kubectl get storageclass onelens-sc -o jsonpath='{.parameters}'; echo

# Metrics PVC is Bound and pods are Running
kubectl get pvc,pods -n onelens-agent

# The EBS volume is encrypted with the expected key
PVC=<pvc-name>    # from the command above
VOL=$(kubectl get pv "$(kubectl get pvc $PVC -n onelens-agent -o jsonpath='{.spec.volumeName}')" \
  -o jsonpath='{.spec.csi.volumeHandle}')
aws ec2 describe-volumes --region <region> --volume-ids $VOL --query 'Volumes[0].[Encrypted,KmsKeyId]'
```

The last command should print `true` and your key ARN. If you encrypted an existing installation, `aws ec2 describe-volumes --region <region> --volume-ids $OLD_VOL` should now return `InvalidVolume.NotFound`. Use the cluster's region: in any other region, every volume reports as not found.

---

## Troubleshooting

### PVC stays Pending after install

The deployer log shows `WARNING: PVC '...' not bound after 120s`, and the metrics pod stays `Pending`.

```bash
kubectl describe pvc <pvc-name> -n onelens-agent
```

An event like `failed to get an available volume in EC2: InvalidVolume.NotFound: The volume 'vol-...' does not exist` usually means the EBS CSI driver can't use the KMS key. EC2 accepts the create request, then drops the volume when the key check fails, so the event doesn't mention KMS. CloudTrail shows the denied KMS calls. Fix the IAM policy or key policy as described in [Before you begin](#before-you-begin). The driver keeps retrying, so the volume is created once the permissions are in place. You don't need to reinstall.

If the key is disabled, enable it in AWS KMS; the driver picks it up on its next retry.

If the key ARN itself is wrong (wrong region or a typo), the StorageClass needs to be recreated. Repeat [Encrypt an existing installation](#encrypt-an-existing-installation) from step 2 with the correct ARN.

For other causes, see [PVC stuck in Pending](troubleshooting.md#pvc-stuck-in-pending).

### Volume is not encrypted

Check what the StorageClass requests:

```bash
kubectl get storageclass onelens-sc -o jsonpath='{.parameters}'; echo
```

If `encrypted` is missing, the encryption parameters were not applied when the StorageClass was created. This happens if they were added with `helm upgrade` on an existing installation. Follow [Encrypt an existing installation](#encrypt-an-existing-installation).

---

## Notes

- **Changing the key or turning encryption off:** repeat [Encrypt an existing installation](#encrypt-an-existing-installation) with the new settings. Upgrades never change the encryption settings of `onelens-sc`.
- **Automatic key rotation** in AWS KMS needs no action on the OneLens side.
- **Do not disable or schedule deletion of the key** while the OneLens volume uses it. The volume becomes unreadable and the metrics pod can't start.
- **Account-level EBS encryption by default** is an alternative. With it turned on, every new EBS volume in the region is encrypted, including OneLens volumes installed without these parameters. Volumes that already exist stay unencrypted until they are recreated.
- **EFS (multi-AZ storage):** the parameters on this page don't apply. EFS encryption is set on the file system when you create it. See [Multi-AZ Storage](../README.md#multi-az-storage).
