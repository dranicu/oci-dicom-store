# IAM prerequisites

The safest operating model is an OCI Resource Manager stack or dedicated
deployment group with access only to the target compartment and the configured
Object Storage S3 compartment.

## Compartment resources

The deploying principal needs to manage:

- VCNs, subnets, gateways, route tables, NSGs, and NSG rules
- DRGs, DRG attachments, and FastConnect virtual circuits when enabled
- Compute instances, VNICs, images, and boot volumes for the bastion
- Container Instances
- flexible Load Balancers
- API Gateway gateways and deployments
- OCI Database with PostgreSQL systems
- Object Storage buckets in the namespace's `default_s3compartment_id`
- log groups, service logs, Monitoring alarms, and work requests

It also needs read access to tenancy availability domains, region
subscriptions, Object Storage namespace/metadata, and service CIDRs.

For an isolated deployment compartment, a tenancy administrator can start with:

```text
Allow group DicomDeployers to manage all-resources in compartment Dicom
Allow group DicomDeployers to read compartments in tenancy
Allow group DicomDeployers to inspect tenancies in tenancy
```

If the Object Storage namespace's S3 compartment is not `Dicom`, grant the group
`manage object-family` in that compartment as well. Narrow the broad first
statement to service families after a successful initial plan in your tenancy.

## Storage identity modes

### Automated identity

With `create_storage_identity = true`, Terraform creates a classic OCI IAM user,
group, membership, policy, and Customer Secret Key. The deployment principal
must be allowed to manage those identity resources and policies at tenancy
scope. This is usually appropriate only for a tenancy administrator or a
carefully delegated Resource Manager stack.

Set `storage_identity_email` to a unique, monitored address or alias. OCI IAM
identity domains commonly require a primary email when creating a user, and
OCI requires that email to be unique across users in the tenancy.
`scripts/deploy.sh` verifies uniqueness through OCI CLI before applying.

The generated runtime policy is bucket-scoped:

```text
Allow group <deployment>-storage to read buckets in compartment id <s3-compartment-ocid> where target.bucket.name = '<bucket>'
Allow group <deployment>-storage to manage objects in compartment id <s3-compartment-ocid> where target.bucket.name = '<bucket>'
```

IAM resources are created through the `home_region` provider alias because IAM
writes must target the tenancy home region.

### Existing identity

For a compartment-scoped deployment:

1. Have a tenancy administrator create a dedicated user and Customer Secret Key.
2. Grant that user the two bucket-scoped statements above.
3. Set `create_storage_identity = false`.
4. Pass `storage_access_key` and `storage_secret_key` as sensitive CI or Resource
   Manager variables.

OCI returns a Customer Secret Key's secret only once. If it is lost, create a
replacement rather than attempting to retrieve it.

## Authentication modes

`oci_auth` supports API key, security token, instance principal, resource
principal, and OKE workload identity modes accepted by the provider. Local
workstations normally use `APIKey` or `SecurityToken`; OCI Resource Manager uses
`ResourcePrincipal`.

Never put key files, session tokens, OCIDs tied to another environment, or
plaintext secrets in committed Terraform files.
