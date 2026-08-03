locals {
  suffix = random_string.suffix.result

  resource_name = "${var.name}-${local.suffix}"
  bucket_name   = coalesce(var.object_storage_bucket_name, "${var.name}-images-${local.suffix}")

  orthanc_password = coalesce(var.orthanc_password, random_password.orthanc.result)
  postgres_password = coalesce(
    var.postgres_admin_password,
    random_password.postgres.result,
  )
  storage_access_key         = var.create_storage_identity ? oci_identity_customer_secret_key.orthanc[0].id : var.storage_access_key
  storage_secret_key         = var.create_storage_identity ? oci_identity_customer_secret_key.orthanc[0].key : var.storage_secret_key
  keycloak_database_password = random_password.keycloak_database.result
  keycloak_admin_password    = random_password.keycloak_admin.result
  auth_service_password      = random_password.auth_service.result
  auth_service_secret        = random_password.auth_service_secret.result

  public_base_url            = "https://${oci_apigateway_gateway.orthanc.hostname}"
  s3_compatibility_endpoint  = "https://${data.oci_objectstorage_namespace.this.namespace}.compat.objectstorage.${var.region}.oci.customer-oci.com"
  nlb_private_ip             = oci_core_private_ip.orthanc_nlb.ip_address
  authorization_service_user = "orthanc-auth"
  oke_node_arch              = length(regexall("\\.A[0-9]+\\.", var.oke_node_shape)) > 0 ? "AARCH64" : "X86_64"
  bastion_kubectl_arch       = length(regexall("\\.A[0-9]+\\.", var.bastion_shape)) > 0 ? "arm64" : "amd64"
  oke_node_sources = [
    for source in try(data.oci_containerengine_node_pool_option.sources.sources, []) : source
    if source.source_type == "IMAGE" && !strcontains(lower(source.source_name), "gpu")
  ]
  oke_node_image_id   = try(local.oke_node_sources[0].image_id, "")
  oke_node_image_name = try(local.oke_node_sources[0].source_name, "")

  tags = merge(
    {
      "managed-by" = "terraform"
      "project"    = "oci-cloud-native-dicom"
      "deployment" = local.resource_name
    },
    var.freeform_tags,
  )

  all_service_id = data.oci_core_services.all_services.services[0].id
  bastion_ssh_public_key = trimspace(
    file(pathexpand(var.ssh_public_key_path)),
  )
  bastion_ssh_cidrs = distinct(concat(
    length(var.bastion_allowed_ssh_cidrs) > 0 ? (
      var.bastion_allowed_ssh_cidrs
    ) : var.allowed_client_cidrs,
    var.enable_fastconnect ? var.fastconnect_on_premises_cidrs : [],
  ))

  orthanc_configuration = {
    Name                   = local.resource_name
    DicomAet               = var.orthanc_aet
    DicomServerEnabled     = false
    RemoteAccessAllowed    = true
    AuthenticationEnabled  = false
    StableAge              = 2
    StrictAetComparison    = true
    HttpCompressionEnabled = true
    MetricsEnabled         = true
    ExecuteLuaEnabled      = false

    DicomWeb = {
      Enable     = true
      Root       = "/dicom-web/"
      PublicRoot = "${local.public_base_url}/orthanc/dicom-web/"
    }

    OrthancExplorer2 = {
      Enable      = true
      IsDefaultUI = true
      Keycloak = {
        Enable   = true
        Url      = "${local.public_base_url}/keycloak/"
        Realm    = "orthanc"
        ClientId = "orthanc"
      }
      UiOptions = {
        EnableShares               = false
        EnableUpload               = true
        EnableDeleteResources      = true
        EnableEditLabels           = true
        EnableAnonymization        = true
        EnableModification         = true
        EnableDownloadZip          = true
        EnableOpenInStoneWebViewer = true
      }
    }

    Authorization = {
      WebServiceRootUrl  = "http://orthanc-auth-service:8000/"
      WebServiceUsername = local.authorization_service_user
      WebServicePassword = local.auth_service_password
      StandardConfigurations = [
        "orthanc-explorer-2",
        "stone-webviewer",
      ]
      TokenHttpHeaders = ["Authorization"]
      CheckedLevel     = "studies"
    }

    PostgreSQL = {
      EnableIndex              = true
      EnableStorage            = false
      Host                     = oci_psql_db_system.orthanc.network_details[0].primary_db_endpoint_private_ip
      Port                     = 5432
      Database                 = "postgres"
      Username                 = var.postgres_admin_username
      Password                 = local.postgres_password
      EnableSsl                = true
      Lock                     = false
      MaximumConnectionRetries = 60
      ConnectionRetryInterval  = 5
      IndexConnectionsCount    = 20
      TransactionMode          = "ReadCommitted"
      ApplicationName          = local.resource_name
    }

    AwsS3Storage = {
      BucketName        = oci_objectstorage_bucket.dicom.name
      Region            = var.region
      Endpoint          = local.s3_compatibility_endpoint
      AccessKey         = local.storage_access_key
      SecretKey         = local.storage_secret_key
      ConnectionTimeout = 30
      RequestTimeout    = 1200
      MaxConnections    = 25
      MaxRetries        = 10
      StorageStructure  = "flat"
      VirtualAddressing = false
    }
  }

  orthanc_role_permissions = {
    roles = {
      "orthanc-viewer" = {
        "authorized-labels" = ["*"]
        permissions         = ["view", "download"]
      }
      "orthanc-uploader" = {
        "authorized-labels" = ["*"]
        permissions         = ["view", "download", "upload"]
      }
      "orthanc-editor" = {
        "authorized-labels" = ["*"]
        permissions = [
          "view",
          "download",
          "upload",
          "modify",
          "anonymize",
          "delete",
          "edit-labels",
          "send",
          "share",
        ]
      }
      "orthanc-admin" = {
        "authorized-labels" = ["*"]
        permissions = [
          "anonymize",
          "audit-logs",
          "delete",
          "download",
          "modify",
          "send",
          "share",
          "view",
          "worklists",
          "admin-permissions",
          "edit-labels",
          "q-r-remote-modalities",
          "settings",
          "upload",
        ]
      }
    }
    "available-labels" = []
  }

  keycloak_realm = {
    realm                  = "orthanc"
    displayName            = "Orthanc"
    enabled                = true
    sslRequired            = "external"
    registrationAllowed    = false
    resetPasswordAllowed   = true
    loginWithEmailAllowed  = true
    duplicateEmailsAllowed = false
    bruteForceProtected    = true
    accessTokenLifespan    = 300
    ssoSessionIdleTimeout  = 1800
    ssoSessionMaxLifespan  = 36000
    roles = {
      realm = [
        for role in ["orthanc-viewer", "orthanc-uploader", "orthanc-editor", "orthanc-admin"] : {
          name       = role
          composite  = false
          clientRole = false
        }
      ]
    }
    clients = [{
      clientId                  = "orthanc"
      name                      = "Orthanc Explorer"
      enabled                   = true
      protocol                  = "openid-connect"
      publicClient              = true
      standardFlowEnabled       = true
      directAccessGrantsEnabled = true
      redirectUris              = ["${local.public_base_url}/orthanc/*"]
      webOrigins                = [local.public_base_url]
      frontchannelLogout        = true
      fullScopeAllowed          = true
      attributes = {
        "post.logout.redirect.uris" = "${local.public_base_url}/orthanc/*"
      }
      protocolMappers = [{
        name            = "account audience"
        protocol        = "openid-connect"
        protocolMapper  = "oidc-audience-mapper"
        consentRequired = false
        config = {
          "included.client.audience" = "account"
          "id.token.claim"           = "false"
          "access.token.claim"       = "true"
        }
      }]
    }]
    users = [{
      username        = var.orthanc_username
      enabled         = true
      emailVerified   = false
      realmRoles      = ["orthanc-admin"]
      requiredActions = []
      credentials = [{
        type      = "password"
        value     = local.orthanc_password
        temporary = false
      }]
    }]
    identityProviders = local.oci_sso_enabled ? [{
      alias                     = "oci"
      displayName               = "OCI IAM SSO"
      providerId                = "oidc"
      enabled                   = true
      trustEmail                = true
      storeToken                = false
      addReadTokenRoleOnCreate  = false
      authenticateByDefault     = false
      linkOnly                  = false
      firstBrokerLoginFlowAlias = "first broker login"
      config = {
        authorizationUrl  = "${local.oci_sso_domain_url}/oauth2/v1/authorize"
        tokenUrl          = "${local.oci_sso_domain_url}/oauth2/v1/token"
        userInfoUrl       = "${local.oci_sso_domain_url}/oauth2/v1/userinfo"
        logoutUrl         = "${local.oci_sso_domain_url}/oauth2/v1/userlogout"
        jwksUrl           = "${local.oci_sso_domain_url}/admin/v1/SigningCert/jwk"
        issuer            = local.oci_sso_issuer
        clientId          = oci_identity_domains_app.orthanc_sso[0].name
        clientSecret      = oci_identity_domains_app.orthanc_sso[0].client_secret
        clientAuthMethod  = "client_secret_post"
        defaultScope      = "openid profile email get_groups"
        syncMode          = "FORCE"
        validateSignature = "true"
        useJwksUrl        = "true"
        disableUserInfo   = "false"
        pkceEnabled       = "true"
        pkceMethod        = "S256"
      }
    }] : []
    identityProviderMappers = local.oci_sso_enabled ? [
      for role, group_name in local.oci_sso_roles : {
        name                   = "OCI ${role}"
        identityProviderAlias  = "oci"
        identityProviderMapper = "oidc-role-idp-mapper"
        config = {
          claim         = "groups"
          "claim.value" = group_name
          role          = role
          syncMode      = "FORCE"
        }
      }
    ] : []
  }

  nginx_configuration = <<-NGINX
    worker_processes auto;
    pid /tmp/nginx.pid;

    events {
      worker_connections 2048;
    }

    http {
      include /etc/nginx/mime.types;
      default_type application/octet-stream;
      access_log /dev/stdout;
      error_log /dev/stderr warn;
      client_max_body_size 0;
      proxy_request_buffering off;
      proxy_buffering off;
      proxy_read_timeout 1200s;
      proxy_send_timeout 1200s;
      client_body_temp_path /tmp/client_temp;
      proxy_temp_path /tmp/proxy_temp;

      server {
        listen 8080;
        %{if var.enable_fastconnect~}
        listen 8443 ssl;
        ssl_certificate /etc/nginx/tls/tls.crt;
        ssl_certificate_key /etc/nginx/tls/tls.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        %{endif~}

        location = /healthz {
          access_log off;
          return 200 "ok\n";
        }

        location = / {
          return 302 /orthanc/ui/app/;
        }

        location = /orthanc {
          return 308 /orthanc/;
        }

        location /orthanc/ {
          proxy_pass http://orthanc:8042/;
          proxy_http_version 1.1;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-Host $host;
          proxy_set_header X-Forwarded-Proto https;
          proxy_set_header X-Forwarded-Port 443;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header Authorization $http_authorization;
        }

        location = /keycloak {
          return 308 /keycloak/;
        }

        location /keycloak/ {
          proxy_pass http://keycloak:8080/keycloak/;
          proxy_http_version 1.1;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-Host $host;
          proxy_set_header X-Forwarded-Proto https;
          proxy_set_header X-Forwarded-Port 443;
          proxy_set_header X-Forwarded-Prefix /keycloak;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
      }
    }
  NGINX

  oke_manifest = templatefile("${path.module}/templates/stack.yaml.tftpl", {
    namespace                   = local.resource_name
    orthanc_replicas            = var.orthanc_replicas
    orthanc_image               = var.orthanc_image
    orthanc_auth_service_image  = var.orthanc_auth_service_image
    keycloak_image              = var.keycloak_image
    nginx_image                 = var.nginx_image
    postgres_client_image       = var.postgres_client_image
    orthanc_config_b64          = base64encode(jsonencode(local.orthanc_configuration))
    permissions_b64             = base64encode(jsonencode(local.orthanc_role_permissions))
    keycloak_realm_b64          = base64encode(jsonencode(local.keycloak_realm))
    nginx_config_b64            = base64encode(local.nginx_configuration)
    postgres_host               = oci_psql_db_system.orthanc.network_details[0].primary_db_endpoint_private_ip
    postgres_username_b64       = base64encode(var.postgres_admin_username)
    postgres_password_b64       = base64encode(local.postgres_password)
    keycloak_password_b64       = base64encode(local.keycloak_database_password)
    keycloak_admin_username_b64 = base64encode("keycloak-admin")
    keycloak_admin_password_b64 = base64encode(local.keycloak_admin_password)
    orthanc_auth_username_b64   = base64encode(local.authorization_service_user)
    orthanc_auth_password_b64   = base64encode(local.auth_service_password)
    orthanc_auth_users_b64      = base64encode(jsonencode({ (local.authorization_service_user) = local.auth_service_password }))
    orthanc_auth_secret_b64     = base64encode(local.auth_service_secret)
    public_base_url             = local.public_base_url
    nlb_private_ip              = local.nlb_private_ip
    nlb_subnet_id               = oci_core_subnet.application.id
    nlb_nsg_id                  = local.nlb_nsg.id
    compartment_id              = var.compartment_id
    enable_fastconnect          = var.enable_fastconnect
    private_ingest_cert_b64     = var.enable_fastconnect ? base64encode(tls_self_signed_cert.private_ingest[0].cert_pem) : ""
    private_ingest_key_b64      = var.enable_fastconnect ? base64encode(tls_private_key.private_ingest[0].private_key_pem) : ""
    keycloak_bootstrap_id       = substr(sha256(local.keycloak_database_password), 0, 12)
    orthanc_config_hash         = sha256(jsonencode(local.orthanc_configuration))
    auth_service_config_hash = sha256(jsonencode({
      permissions = local.orthanc_role_permissions
      password    = local.auth_service_password
      secret      = local.auth_service_secret
    }))
    keycloak_config_hash = sha256(jsonencode({
      database_password = local.keycloak_database_password
      admin_password    = local.keycloak_admin_password
      realm             = local.keycloak_realm
    }))
    nginx_config_hash = sha256(join("", [
      local.nginx_configuration,
      try(tls_self_signed_cert.private_ingest[0].cert_pem, ""),
    ]))
  })
}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  lower   = true
  numeric = true
  special = false
}

resource "random_password" "orthanc" {
  length           = 32
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 4
  override_special = "!#%+-.:=?@_"
}

resource "random_password" "postgres" {
  length           = 32
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 4
  override_special = "!#%+-.:=?@_"
}

resource "random_password" "keycloak_database" {
  length      = 32
  min_lower   = 6
  min_upper   = 6
  min_numeric = 6
  special     = false
}

resource "random_password" "keycloak_admin" {
  length      = 32
  min_lower   = 6
  min_upper   = 6
  min_numeric = 6
  special     = false
}

resource "random_password" "auth_service" {
  length      = 32
  min_lower   = 6
  min_upper   = 6
  min_numeric = 6
  special     = false
}

resource "random_password" "auth_service_secret" {
  length      = 48
  min_lower   = 8
  min_upper   = 8
  min_numeric = 8
  special     = false
}

check "storage_credentials" {
  assert {
    condition = (
      var.create_storage_identity ||
      (var.storage_access_key != null && var.storage_secret_key != null)
    )
    error_message = "Set both storage_access_key and storage_secret_key when create_storage_identity is false."
  }
}

check "fastconnect_inputs" {
  assert {
    condition = !var.enable_fastconnect || (
      var.fastconnect_provider_service_id != null &&
      length(var.fastconnect_on_premises_cidrs) > 0
    )
    error_message = "When enable_fastconnect is true, set fastconnect_provider_service_id and at least one fastconnect_on_premises_cidrs entry."
  }
}
