# OCI IAM Identity Domains SSO

The stack can federate Orthanc with the OCI IAM identity domain that already
contains workforce accounts. Terraform does not create or replace users. It
creates one confidential OIDC application, four privileged platform role
groups, four groups per configured tenant, app grants for those groups, and a
Keycloak broker configuration.

The browser authentication flow is:

```text
Orthanc Explorer -> Keycloak -> OCI IAM Identity Domain -> Keycloak -> Orthanc
```

Keycloak remains between Orthanc and OCI IAM because Orthanc Explorer and the
official Orthanc authorization service integrate with Keycloak roles. OCI IAM
performs authentication and MFA; Keycloak maps the OCI group claim into the
Orthanc authorization roles.

## Enable SSO

Find the identity domain that owns the existing users under **Identity &
Security > Domains**. Set its domain OCID in `terraform/terraform.tfvars`:

```hcl
oci_identity_domain_sso = {
  identity_domain_id = "ocid1.domain.oc1..replace_me"
  group_names = {
    orthanc-viewer   = "Orthanc-Viewers"
    orthanc-uploader = "Orthanc-Uploaders"
    orthanc-editor   = "Orthanc-Editors"
    orthanc-admin    = "Orthanc-Administrators"
  }
}
```

Then run the normal deployment:

```bash
make plan
make apply
make verify
make get-credentials
```

Terraform registers the exact Keycloak callback URL in OCI IAM and configures
the authorization-code flow with PKCE. Keycloak requests OCI's `get_groups`
scope and validates the returned token signature and issuer against the
identity-domain endpoints.

## Give an existing user access

After the apply, open the selected identity domain in the OCI Console and add
the existing user to exactly the groups required for their job. The groups are
shown by `make get-credentials` and `terraform -chdir=terraform output oci_sso`.

| OCI IAM group | Orthanc role | Effective access |
| --- | --- | --- |
| `Orthanc-Viewers` | `orthanc-viewer` | View and download |
| `Orthanc-Uploaders` | `orthanc-uploader` | View, download, and upload |
| `Orthanc-Editors` | `orthanc-editor` | Clinical content editing and deletion |
| `Orthanc-Administrators` | `orthanc-admin` | Full Orthanc administration |

Those four roles are platform-wide and therefore cross tenant boundaries. Use
them only for approved central operations. Normal workforce access uses the
generated tenant groups, for example:

| Generated OCI IAM group | Keycloak role | Effective access |
| --- | --- | --- |
| `Hospital A - Orthanc Viewers` | `tenant-hospital-a-viewer` | View/download studies labeled `tenant-hospital-a` |
| `Hospital A - Orthanc Uploaders` | `tenant-hospital-a-uploader` | Upload plus view/download that tenant's labeled studies |
| `Hospital A - Orthanc Editors` | `tenant-hospital-a-editor` | Tenant-scoped clinical operations and deletion |
| `Hospital A - Orthanc Admins` | `tenant-hospital-a-admin` | Tenant-scoped operations and audit viewing; no study classification |

Custom group names are supported through the `group_names` map. All four keys
must be present because they are the stable authorization contract consumed by
the Orthanc authorization service.

Tenant group names are derived from `orthanc_tenants`; use
`make get-credentials` or the `tenant_authorization` output for the exact map.
Assign each person to one tenant role whenever possible. Membership in two
tenant groups intentionally grants access to both label sets. Only the global
`orthanc-admin` performs trusted study classification.

Open the Orthanc Web UI and select **OCI IAM SSO**. A user not assigned to one
of the application groups cannot use the OCI application. A user assigned to
the application but to no mapped role cannot access Orthanc resources.

The generated local `orthanc-admin` Keycloak account remains available as a
break-glass account. Store that password securely and use OCI SSO for normal
interactive access.

## Lifecycle and security

- The OCI client secret is sensitive Terraform state and is mounted into
  Keycloak through a Kubernetes Secret, not a ConfigMap.
- Identity-domain writes happen through the home-region OCI provider.
- `make verify` checks OCI discovery metadata and confirms that Keycloak sends
  an SSO login to the configured OCI authorization endpoint.
- Destroy removes the stack-created confidential application, grants, and role
  groups. It does not delete existing OCI IAM users. Memberships in those
  stack-created groups disappear with the groups.
- Setting `oci_identity_domain_sso = null` disables federation on the next
  fresh deployment. The local Keycloak account remains usable.

OCI documents confidential application registration and authorization-code
flows in [Adding a Confidential Application](https://docs.oracle.com/en-us/iaas/Content/Identity/applications/add-confidential-application.htm)
and [OCI IAM OAuth and OpenID Connect best practices](https://docs.oracle.com/en-us/iaas/Content/Resources/Assets/whitepapers/oci-iam-oauth-flows-best-practices.pdf).
