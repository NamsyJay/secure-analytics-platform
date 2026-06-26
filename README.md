# Secure Analytics Platform

A private AWS analytics platform for running **JupyterLab, RStudio and Streamlit** against a governed data lake. The platform is designed for sensitive workloads and uses Amazon EKS, Lake Formation, Athena, S3, KMS, Secrets Manager, private networking, centralised audit logging and GitHub Actions.

> **Security notice:** Do not commit credentials, production data, personal data, security findings, AWS account secrets or OFFICIAL-SENSITIVE material to this repository.

## Architecture summary

```text
Corporate user / VPN / VDI
          |
          v
Route 53 private DNS
          |
          v
Internal ALB + ACM TLS + WAF
          |
          v
Amazon EKS
├── JupyterHub / RStudio launcher
├── Per-user notebook pods
├── Streamlit workloads
├── System node group
└── Isolated session node group
          |
          +-----------------------------+
          |                             |
          v                             v
Governed data plane              Security and observability
├── Lake Formation               ├── CloudTrail
├── Glue Data Catalog            ├── CloudWatch Logs
├── Athena                       ├── GuardDuty
├── S3 data lake                 ├── Security Hub
├── KMS                          ├── Managed Prometheus
└── Secrets Manager              └── Managed Grafana
```

The platform is private by default:

- The EKS API endpoint is private.
- User-facing services are exposed only through an internal ALB.
- Notebook pods have no unrestricted internet access.
- AWS API calls use VPC endpoints or PrivateLink where supported.
- Data access is governed through IAM, IRSA, Lake Formation and KMS.
- Audit evidence is forwarded to central security and log archive accounts.

## Environment model

Use separate AWS accounts for isolation:

```text
AWS Organizations
├── Analytics Dev Account
├── Analytics Test Account
├── Analytics Prod Account
├── Security Account
├── Log Archive Account
└── Optional Shared Services Account
```

| Environment | Purpose | Deployment | Controls |
|---|---|---|---|
| Dev | Fast engineering feedback | Automatic after merge to `main` | Small capacity, short retention, no production data |
| Test | Integration, security, UAT and release rehearsal | Controlled promotion | Production-like controls and representative test data |
| Prod | Live analytical service | Manual approval | HA, backups, DR, long retention and deletion protection |

Each environment has its own AWS account, Terraform state, VPC, EKS cluster, KMS keys, IAM roles, S3 buckets, DNS records and GitHub Environment.

## Repository structure

```text
secure-analytics-platform/
├── .github/
│   └── workflows/
│       ├── pr-checks.yml
│       ├── deploy-dev.yml
│       ├── promote.yml
│       ├── security-scanning.yml
│       └── drift-detection.yml
├── docs/
│   ├── architecture/
│   ├── decisions/
│   ├── runbooks/
│   └── security/
├── infrastructure/
│   ├── bootstrap/
│   ├── modules/
│   ├── environments/
│   │   ├── dev/
│   │   ├── test/
│   │   └── prod/
│   └── tests/
├── platform/
│   ├── helm/
│   ├── manifests/
│   └── tests/
├── images/
│   ├── jupyter/
│   ├── rstudio/
│   └── streamlit/
├── policies/
│   ├── iam/
│   ├── opa/
│   ├── network/
│   └── lake-formation/
├── observability/
├── scripts/
├── tests/
├── CODEOWNERS
├── Makefile
└── README.md
```

## Git and release strategy

Use one permanent source branch:

```text
feature/* -> pull request -> main
```

Do not maintain permanent `dev`, `test` and `prod` branches. Those are deployment environments, not separate source-code histories.

```text
Feature branch
      |
      v
Pull request and CI checks
      |
      v
Merge to main
      |
      v
Build and scan once
      |
      v
Deploy to Dev
      |
      v
Promote the same release to Test
      |
      v
Approve and promote the same release to Prod
```

Release identity:

```text
Infrastructure release = Git commit SHA
Application release    = immutable ECR image digest
```

The same image digest must move through Dev, Test and Prod. Do not rebuild the image per environment.

## Prerequisites

Install:

- Git
- Terraform
- AWS CLI
- `kubectl`
- Helm
- Docker or another OCI-compatible build tool
- `jq`
- `shellcheck`
- Trivy
- Checkov or another IaC scanner
- Kubeconform or another Kubernetes validator

You also need access to the AWS Organization, permission to bootstrap Terraform state and GitHub OIDC, a GitHub repository with Actions enabled, and private connectivity to the EKS API.

## Initial setup

### Clone the repository

```bash
git clone git@github.com:<OWNER>/secure-analytics-platform.git
cd secure-analytics-platform
```

### Authenticate for bootstrap

Use approved AWS SSO or role-based access:

```bash
aws sso login --profile platform-bootstrap
export AWS_PROFILE=platform-bootstrap
export AWS_REGION=eu-west-2
```

Do not configure permanent AWS access keys for GitHub Actions.

### Bootstrap Terraform state

Create a separate backend for each environment:

```text
analytics-dev-terraform-state
analytics-test-terraform-state
analytics-prod-terraform-state
```

The backend should use S3 versioning, KMS encryption, public access block, state locking and restricted IAM access.

### Bootstrap GitHub OIDC

Create one deployment role in each environment account:

```text
github-dev-deployer
github-test-deployer
github-prod-deployer
```

Restrict each trust policy to the exact GitHub owner, repository, environment and the `sts.amazonaws.com` audience.

Example subject:

```text
repo:<OWNER>/secure-analytics-platform:environment:prod
```

## GitHub configuration

Protect `main` with:

- Pull requests required
- Required reviewers
- Required status checks
- Stale approval dismissal
- Conversation resolution
- Force-push protection
- Branch deletion protection
- No direct pushes

Create GitHub Environments:

```text
dev
test
prod
```

Configure these variables in each environment:

```text
AWS_REGION
AWS_ROLE_ARN
TF_STATE_BUCKET
TF_STATE_KEY
EKS_CLUSTER_NAME
TERRAFORM_VERSION
```

Production should require approval and prevent self-review.

## Terraform usage

Each environment calls the same reusable modules:

```text
infrastructure/environments/
├── dev/
├── test/
└── prod/
```

Example Dev validation:

```bash
terraform -chdir=infrastructure/environments/dev init -backend-config=backend.hcl
terraform -chdir=infrastructure/environments/dev fmt -check
terraform -chdir=infrastructure/environments/dev validate
terraform -chdir=infrastructure/environments/dev plan -var-file=dev.tfvars
```

Production changes must go through the approved GitHub Actions workflow.

## CI/CD flow

Pull requests should run:

- Terraform formatting and validation
- IaC security scanning
- Helm linting
- Kubernetes schema validation
- OPA or policy tests
- Shell checks
- Unit tests
- Container vulnerability scanning
- Secret scanning

A merge to `main` automatically deploys to Dev. Test and Prod use a promotion workflow that checks out the exact Git SHA and deploys the same immutable image digests.

Production approvers should verify that Dev and Test passed, the Production Terraform plan is acceptable, security scans passed, rollback is known and operational runbooks are ready.

## Local development workflow

```bash
git switch main
git pull --ff-only
git switch -c feature/add-vpc-endpoint
```

After making the change:

```bash
terraform fmt -recursive
terraform -chdir=infrastructure/environments/dev init -backend=false
terraform -chdir=infrastructure/environments/dev validate

git add .
git commit -m "feat: add private endpoint for Secrets Manager"
git push -u origin feature/add-vpc-endpoint
```

Open a pull request into `main` and delete the feature branch after merge.

## Container image lifecycle

Every Jupyter, RStudio or Streamlit image pipeline should:

1. Build the image.
2. Run unit and startup tests.
3. Scan for vulnerabilities.
4. Generate an SBOM.
5. Sign or attest the image where required.
6. Push to the approved ECR repository.
7. Resolve the immutable image digest.
8. Deploy to Dev.
9. Promote the same digest to Test and Prod.

Production Helm values must use an immutable digest, not `latest`.

## Platform security controls

The EKS platform should enforce:

- Private Kubernetes API endpoint
- No routine SSH administration
- IMDSv2
- Separate system and session node groups
- Taints and tolerations for notebook sessions
- Restricted Pod Security Admission
- Non-root containers
- Default-deny network policies
- Explicit egress to approved services
- Resource requests, limits and quotas
- Secrets Store CSI Driver
- Scoped IRSA roles
- Encrypted persistent volumes
- Central logging and monitoring

The governed data plane should enforce S3 public access block, versioning, KMS encryption, S3 data-event logging, Glue metadata, Lake Formation permissions, LF-Tag access control, column-level restrictions and encrypted Athena query results.

## Testing

Dev checks should cover ALB health, OIDC login, notebook scheduling, IRSA access, package-mirror access, blocked direct internet access and log delivery.

Test should cover end-to-end authentication, Lake Formation allow/deny cases, KMS boundaries, network policies, performance, upgrade rehearsal, backup restoration, security testing and UAT.

Production should run post-deployment smoke tests, key-user-journey tests, SLO checks, alert validation and rollback readiness checks.

## Observability and runbooks

Collect EKS control-plane logs, application logs, VPC Flow Logs, ALB access logs, CloudTrail, S3 data events, node and pod metrics, notebook startup latency, persistent-volume consumption and security findings.

Minimum runbooks:

```text
docs/runbooks/
├── jupyterhub-unavailable.md
├── oidc-authentication-failure.md
├── notebook-scheduling-failure.md
├── node-group-failure.md
├── persistent-volume-recovery.md
├── failed-image-deployment.md
├── suspicious-notebook-activity.md
├── lake-formation-access-denied.md
├── package-mirror-unavailable.md
├── terraform-state-lock.md
├── production-rollback.md
└── regional-recovery.md
```

## Rollback and disaster recovery

Rollback by redeploying the previous immutable image digest or Helm release. Do not force-push `main`, create an emergency Production branch, rebuild the old image or manually patch the Production cluster.

Disaster recovery should include S3 cross-region replication, replicated or re-seeded secrets, EBS/DLM snapshots, Terraform rebuild, Helm redeployment, private DNS recovery, periodic exercises and documented RTO/RPO targets.

## Contribution rules

Every change must:

1. Start from the latest `main`.
2. Use a short-lived branch.
3. Include tests where appropriate.
4. Pass CI.
5. Be reviewed.
6. Avoid secrets and sensitive information.
7. Update documentation for operational changes.
8. Include rollback guidance for Production-impacting changes.
9. Include an ADR for major architectural decisions.
10. Be merged through a pull request.

Example branches:

```text
feature/add-lake-formation-tags
feature/add-grafana-dashboard
bugfix/fix-notebook-startup
chore/update-terraform-provider
docs/add-dr-runbook
```

## Definition of done

A change is complete when CI passes, Dev deployment and smoke tests pass, Test validation passes, security evidence is available, documentation and monitoring are updated, rollback is known, Production approval is recorded and post-deployment checks pass.

## Ownership

| Area | Owner |
|---|---|
| AWS and Kubernetes platform | Platform Engineering |
| Data governance | Data Platform / Data Owners |
| Security controls | Cloud Security |
| CI/CD | Platform Engineering |
| Incident response | Service Operations |
| Platform images | Platform Engineering / Data Science Enablement |
| Disaster recovery | Platform Engineering and Service Owner |

Replace the placeholders with the organisation's actual team names, contacts and escalation routes.

## Licence and handling

Add the approved project licence or internal-use statement here, including repository visibility, data-classification rules, permitted users and the security-reporting route.
