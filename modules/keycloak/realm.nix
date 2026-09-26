{
  webHost,
  publicHost ? null,
  clientSecret,
}:
let
  origins = map (host: "https://${host}") (
    [ webHost ] ++ (if publicHost == null then [ ] else [ publicHost ])
  );

  defaultClientScopes = [
    "web-origins"
    "acr"
    "roles"
    "profile"
    "basic"
    "email"
  ];

  optionalClientScopes = [
    "address"
    "phone"
    "offline_access"
    "microprofile-jwt"
  ];

  roleMapper = {
    name = "realm roles";
    protocol = "openid-connect";
    protocolMapper = "oidc-usermodel-realm-role-mapper";
    config = {
      "claim.name" = "roles";
      multivalued = "true";
      "jsonType.label" = "String";
      "userinfo.token.claim" = "true";
      "id.token.claim" = "true";
      "access.token.claim" = "true";
      "introspection.token.claim" = "true";
    };
  };

  publicClientAttributes = {
    "pkce.code.challenge.method" = "S256";
    "post.logout.redirect.uris" = "+";
    "backchannel.logout.session.required" = "true";
    "frontchannel.logout.session.required" = "true";
    "oauth2.device.authorization.grant.enabled" = "false";
    "oidc.ciba.grant.enabled" = "false";
  };

  publicClient =
    name: clientId: description:
    {
      inherit clientId name;
      enabled = true;
      alwaysDisplayInConsole = true;
      publicClient = true;
      bearerOnly = false;
      consentRequired = false;
      standardFlowEnabled = true;
      implicitFlowEnabled = false;
      directAccessGrantsEnabled = true;
      serviceAccountsEnabled = false;
      authorizationServicesEnabled = false;
      frontchannelLogout = true;
      protocol = "openid-connect";
      rootUrl = builtins.head origins;
      baseUrl = builtins.head origins;
      redirectUris = map (origin: "${origin}/*") origins;
      webOrigins = origins;
      fullScopeAllowed = true;
      attributes = publicClientAttributes;
      protocolMappers = [ roleMapper ];
      inherit defaultClientScopes optionalClientScopes;
    }
    // (if description == null then { } else { inherit description; });
in
{
  realm = "msdome";
  displayName = "MSDome";
  loginTheme = "dome";
  enabled = true;
  sslRequired = "external";
  registrationAllowed = false;
  loginWithEmailAllowed = true;
  duplicateEmailsAllowed = false;
  resetPasswordAllowed = false;
  editUsernameAllowed = false;
  rememberMe = false;
  verifyEmail = false;
  bruteForceProtected = true;
  accessTokenLifespan = 300;
  ssoSessionIdleTimeout = 1800;
  ssoSessionMaxLifespan = 36000;

  roles.realm = [
    {
      name = "staff";
      description = "Access to the Django admin";
    }
    {
      name = "admin";
      description = "Django superuser (implies staff)";
    }
  ];

  clients = [
    {
      clientId = "msdome-backend";
      name = "MSDome backend";
      enabled = true;
      alwaysDisplayInConsole = true;
      clientAuthenticatorType = "client-secret";
      secret = clientSecret;
      redirectUris = [ "*" ];
      webOrigins = [ "*" ];
      bearerOnly = false;
      consentRequired = false;
      standardFlowEnabled = true;
      implicitFlowEnabled = false;
      directAccessGrantsEnabled = false;
      serviceAccountsEnabled = false;
      publicClient = false;
      frontchannelLogout = true;
      protocol = "openid-connect";
      fullScopeAllowed = true;
      attributes = {
        "post.logout.redirect.uris" = "+";
        "backchannel.logout.session.required" = "true";
        "frontchannel.logout.session.required" = "true";
      };
      protocolMappers = [ roleMapper ];
      inherit defaultClientScopes optionalClientScopes;
    }
    (publicClient "MSDome web" "msdome-web" null)
    (publicClient "Frontend" "frontend-client" "Public SPA client")
  ];

  users = [
    {
      username = "test";
      firstName = "John";
      lastName = "Doe";
      email = "john.doe@example.com";
      emailVerified = true;
      enabled = true;
      credentials = [
        {
          type = "password";
          value = "test";
          temporary = false;
        }
      ];
      realmRoles = [
        "default-roles-msdome"
        "admin"
      ];
    }
    {
      username = "test2";
      firstName = "Jane";
      lastName = "Smith";
      email = "jane.smith@example.com";
      emailVerified = true;
      enabled = true;
      credentials = [
        {
          type = "password";
          value = "test";
          temporary = false;
        }
      ];
      realmRoles = [ "default-roles-msdome" ];
    }
  ];
}
