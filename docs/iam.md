# IAM prerequisites

The safest operating model is an OCI Resource Manager stack or dedicated
deployment group with access to the target compartment plus the minimum
tenancy-level permissions documented below.

## Compartment resources

The deploying principal needs to manage:

- VCNs, subnets, gateways, route tables, NSGs, and NSG rules
- DRGs, DRG attachments, and FastConnect virtual circuits when enabled
- Compute instances, VNICs, images, and boot volumes for the bastion
- OKE enhanced clusters, managed node pools, and Compute worker nodes
- OCI Network Load Balancers provisioned by the OKE cloud controller
- API Gateway gateways and deployments
- OCI Database with PostgreSQL systems
- Object Storage buckets in the target compartment
- log groups, service logs, Monitoring alarms, and work requests

It also needs read access to tenancy availability domains, region
subscriptions, Object Storage namespace, and service CIDRs. The stack creates
the bucket through OCI's native API directly in `compartment_id`; it does not
change the tenancy-wide S3-compatible API compartment designation.

For an isolated deployment compartment, a tenancy administrator can start with:

```text
Allow group DicomDeployers to manage all-resources in compartment Dicom
Allow group DicomDeployers to read compartments in tenancy
Allow group DicomDeployers to inspect tenancies in tenancy
```

For an existing root-level bucket, the first corrective apply also needs
`BUCKET_UPDATE` and `BUCKET_CREATE` in the source compartment so OCI can move
it to `Dicom`. Narrow the broad first statement to service families after a
successful initial plan in your tenancy.

## Storage identity modes

### Automated identity

With `create_storage_identity = true`, Terraform creates a classic OCI IAM user,
group, membership, and Customer Secret Key at tenancy scope; OCI does not place
these global identity objects in application compartments. The bucket-scoped
policy itself is placed in `compartment_id`. The deployment principal must be
allowed to manage these resources. This is usually appropriate only for a
tenancy administrator or a carefully delegated Resource Manager stack.

Set `storage_identity_email` to a unique, monitored address or alias. OCI IAM
identity domains commonly require a primary email when creating a user, and
OCI requires that email to be unique across users in the tenancy.
`scripts/deploy.sh` verifies uniqueness through OCI CLI before applying.

The generated runtime policy is bucket-scoped:

```text
Allow group <deployment>-storage to read buckets in compartment id <s3-compartment-ocid> where target.bucket.name = '<bucket>'
Allow group <deployment>-storage to manage objects in compartment id <s3-compartment-ocid> where target.bucket.name = '<bucket>'
```

IAM writes use the `home_region` provider alias because they must target the
tenancy home region. This does not cause the compartment-scoped policy to be
placed in the tenancy root.

## OKE operator and service identities

Terraform creates a dynamic group whose matching rule contains only the
deployed bastion instance OCID. Its compartment policy allows `use
cluster-family` only for the deployed OKE cluster, enabling an
instance-principal private kubeconfig without copying an API key to the host.

The OKE cluster principal receives compartment-scoped permission to create and
delete its internal Network Load Balancer and use the VCN resources needed by
the cloud controller. These policies are required even when
`create_storage_identity = false`.

## OCI IAM Identity Domains SSO

When `oci_identity_domain_sso` is set, the deploying principal also needs
permission to manage applications, groups, and grants in that existing
identity domain. The provider addresses Identity Domains through the domain's
home-region URL; these resources are not compartment-local application
resources even when the domain itself is assigned to a compartment.

The stack creates no SSO users. Existing users are added to the generated role
groups by an identity-domain administrator. See [OCI SSO](sso.md) for the
group-to-Orthanc-role mapping and lifecycle behavior.

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
