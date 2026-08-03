locals {
  oci_sso_enabled = var.oci_identity_domain_sso != null
  oci_sso_roles = local.oci_sso_enabled ? (
    var.oci_identity_domain_sso.group_names
  ) : {}
  oci_sso_domain_url = local.oci_sso_enabled ? trimsuffix(
    data.oci_identity_domain.orthanc_sso[0].url,
    "/",
  ) : null
  oci_sso_issuer = local.oci_sso_enabled ? "${trimsuffix(replace(local.oci_sso_domain_url, ":443", ""), "/")}/" : null
  oci_sso_callback_url = local.oci_sso_enabled ? (
    "${local.public_base_url}/keycloak/realms/orthanc/broker/oci/callback"
  ) : null
}

data "oci_identity_domain" "orthanc_sso" {
  count    = local.oci_sso_enabled ? 1 : 0
  provider = oci.home

  domain_id = try(var.oci_identity_domain_sso.identity_domain_id, null)
}

resource "oci_identity_domains_app" "orthanc_sso" {
  count    = local.oci_sso_enabled ? 1 : 0
  provider = oci.home

  idcs_endpoint = local.oci_sso_domain_url
  display_name  = "${local.resource_name} Orthanc SSO"
  name          = "${local.resource_name}-orthanc-sso"
  description   = "OIDC client used by the ${local.resource_name} Keycloak broker for Orthanc SSO"
  schemas       = ["urn:ietf:params:scim:schemas:oracle:idcs:App"]

  based_on_template {
    value         = "CustomWebAppTemplateId"
    well_known_id = "CustomWebAppTemplateId"
  }

  active                  = true
  is_oauth_client         = true
  is_login_target         = true
  client_type             = "confidential"
  login_mechanism         = "OIDC"
  allowed_grants          = ["authorization_code", "refresh_token"]
  allow_offline           = true
  allow_access_control    = true
  bypass_consent          = true
  all_url_schemes_allowed = false
  redirect_uris           = [local.oci_sso_callback_url]
  post_logout_redirect_uris = [
    "${local.public_base_url}/orthanc/ui/app/",
  ]
  logout_uri       = "${local.public_base_url}/orthanc/ui/app/"
  home_page_url    = "${local.public_base_url}/orthanc/ui/app/"
  landing_page_url = "${local.public_base_url}/orthanc/ui/app/"
  force_delete     = true

  lifecycle {
    ignore_changes = [schemas]
  }
}

resource "oci_identity_domains_group" "orthanc_sso" {
  for_each = local.oci_sso_roles
  provider = oci.home

  idcs_endpoint = local.oci_sso_domain_url
  display_name  = each.value
  schemas       = ["urn:ietf:params:scim:schemas:core:2.0:Group"]
  force_delete  = true

  urnietfparamsscimschemasoracleidcsextensiongroup_group {
    creation_mechanism = "api"
    description        = "Members receive the ${each.key} role in ${local.resource_name} Orthanc"
  }

  lifecycle {
    ignore_changes = [schemas]
  }
}

resource "oci_identity_domains_grant" "orthanc_sso" {
  for_each = local.oci_sso_roles
  provider = oci.home

  idcs_endpoint   = local.oci_sso_domain_url
  grant_mechanism = "ADMINISTRATOR_TO_GROUP"
  schemas         = ["urn:ietf:params:scim:schemas:oracle:idcs:Grant"]

  grantee {
    type  = "Group"
    value = oci_identity_domains_group.orthanc_sso[each.key].id
  }

  app {
    value = oci_identity_domains_app.orthanc_sso[0].id
  }

  lifecycle {
    ignore_changes = [schemas]
  }
}
