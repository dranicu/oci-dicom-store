# Operations runbook

## Day-two health checks

Run:

```bash
scripts/verify.sh
```

From the management host, run the private-path checks:

```bash
scripts/ssh-bastion.sh sudo dicom-status
```

Then review:

- API Gateway access and execution logs in the generated log group
- `oci_apigateway` `HttpResponses`, `BackendHttpResponses`, and latency metrics
- `oci_lbaas` `unhealthyBackendServers` and backend timeout metrics
- PostgreSQL state and backup history
- Object Storage object count, size, and version growth
- Container Instances lifecycle and health-check state

Supplying an existing Notifications topic enables the two built-in alarms.
Create OCI Health Checks from an approved private or public vantage point if
you need independent liveness monitoring. Orthanc endpoints require
authentication, so do not create an unauthenticated health route containing
patient data.

## Bastion operations

The Oracle Linux bastion is the only public SSH target. Its NSG admits TCP/22
only from `bastion_allowed_ssh_cidrs` (or `allowed_client_cidrs` when the
dedicated list is empty). Password login, root login, agent forwarding, and
remote forwarding are disabled. Local forwarding remains enabled so an
authorized operator can create a loopback-only tunnel when needed.

Reapply the idempotent host configuration after an operator-tool update:

```bash
export BASTION_SSH_PRIVATE_KEY_FILE=/absolute/path/to/id_rsa
scripts/configure-bastion.sh
```

Useful commands on the host:

```bash
sudo dicom-status
sudo dicom-env
sudo dicom-psql
sudo journalctl -u sshd
```

The root-only stack file contains Orthanc and PostgreSQL credentials. Rotate
credentials if a bastion administrator who could read that file loses access,
then rerun Ansible. Do not place OCI API signing keys on the host. Prefer a
short-lived security-token session if OCI CLI access is required.

## Scaling

Increase `orthanc_replicas` to add Container Instances. They share the
PostgreSQL index and Object Storage payloads; the private load balancer adds the
new backends automatically.

Before scaling:

1. Confirm Container Instances shape capacity and service limits.
2. Confirm the application subnet has sufficient addresses.
3. Increase PostgreSQL OCPUs/memory or instance count if index pressure is the
   bottleneck.
4. Review the flexible load balancer maximum bandwidth.

Multiple Orthanc replicas use `PostgreSQL.Lock = false`, as required for shared
index access. Keep every replica on the same pinned image and configuration.

## Credential rotation

For generated credentials, use Terraform replacement so dependent Container
Instances receive the same atomic configuration:

```bash
terraform -chdir=terraform apply \
  -replace=random_password.orthanc \
  -replace=random_password.postgres \
  -replace='oci_identity_customer_secret_key.orthanc[0]'
```

Review the plan carefully. Replacing the PostgreSQL password may require a
service-supported password update and coordinated Orthanc replacement. Test
rotation in a non-production stack first.

For an existing storage identity, create a second Customer Secret Key, update
the sensitive input variables, apply, verify all replicas and Object Storage
reads/writes, then delete the old key.

## Backup and recovery

- PostgreSQL daily backup retention defaults to 14 days.
- Object versioning is enabled by default.
- Object Storage versioning is not an application-consistent database backup.
- A complete recovery procedure must restore PostgreSQL to a matching point in
  time and preserve the corresponding Object Storage versions.

Exercise restore into an isolated compartment. Validate study/series/instance
counts and retrieve representative objects before declaring the restore usable.

For regional disaster recovery, add Object Storage replication and PostgreSQL
cross-region backup copy policies according to the organization's RPO/RTO and
data-residency rules. They are not enabled generically because destination
region and legal residency requirements are deployment-specific.

## Upgrades

1. Read Orthanc core, PostgreSQL plugin, DICOMweb plugin, and S3 plugin release notes.
2. Pin a new `orthanc_image` tag in a non-production workspace.
3. Run API checks and upload/retrieve/delete lifecycle tests.
4. Review database schema migration and rollback compatibility.
5. Apply in production and monitor backend health and 5xx rates.

Container Instance replacement uses create-before-destroy, and the load
balancer removes unhealthy backends from rotation. Do not use a floating
`latest` image tag.

## Large-file ingest

API Gateway rejects request bodies over 20 MB. Bulk ingest needs a private VCN
path over FastConnect or a purpose-built chunking/ingest service. When
FastConnect is enabled, validate the control plane first:

```bash
scripts/verify-fastconnect.sh --control-plane-only
```

From a FastConnect-connected on-premises host, validate routing, TLS, and APIs:

```bash
scripts/verify-fastconnect.sh
scripts/verify-fastconnect.sh --dicom /absolute/path/to/large-test.dcm
```

The private path does not traverse API Gateway and therefore does not have its
20 MB request limit. Validate:

- private DNS and routing
- DRG route distributions
- on-premises and OCI CIDR non-overlap
- NSG rules restricted to the on-premises CIDRs
- transfer retry/idempotency and storage validation

Review [fastconnect.md](fastconnect.md) before activation. A virtual circuit
remaining `PENDING_PROVIDER` or `DOWN` is expected until the carrier activates
the order and on-premises BGP is established.

Traditional DICOM C-STORE port 4242 is disabled in this stack. If required,
expose it only through a private Network Load Balancer, enable DICOM TLS, and
restrict calling AEs and network sources.

## Decommissioning

1. Stop new ingest and record the approved retention disposition.
2. Export and verify required studies and audit evidence.
3. Run `terraform -chdir=terraform plan -destroy`.
4. Run `scripts/destroy.sh`.
5. If the bucket is non-empty, the destroy fails by design.
6. Only an authorized data custodian should remove current and versioned objects.
7. Rerun destroy and retain the final Terraform output/log as cleanup evidence.
