#!/usr/bin/env bash
# configure.sh — Read client configuration from .env and generate configure.js.
#
# configure.js is mounted into the mongodb-seed container and executed by
# mongosh against BlocksRootDb immediately after mongorestore. It applies
# client-specific settings to five collections:
#   IdentityProviders, OidcClientRegistrations, Tenants, Secrets,
#   MonitorConfigurations
#
# Usage:
#   bash configure.sh               # uses .env in CWD or script directory
#   bash configure.sh --env /path   # explicit .env path
#
# Called automatically by run.sh before docker compose up.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate .env
# ---------------------------------------------------------------------------
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
else
  _script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
fi

_env_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env|-e) _env_file="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$_env_file" ]]; then
  [[ -f ".env" ]] && _env_file="$(pwd)/.env" || _env_file="$_script_dir/.env"
fi

[[ ! -f "$_env_file" ]] && { echo "configure.sh: .env not found at $_env_file" >&2; exit 1; }

set -a; source "$_env_file"; set +a

# ---------------------------------------------------------------------------
# Validate required input
# ---------------------------------------------------------------------------
[[ -z "${DOMAIN:-}" ]] && { echo "configure.sh: DOMAIN is not set in $_env_file" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Resolve per-service values — URL / CLIENT_ID / CLIENT_SECRET
#
# Priority:
#   1. Explicit <SVC>_URL / <SVC>_CLIENT_ID / <SVC>_CLIENT_SECRET in .env
#   2. URL defaults to https://<svc>.<DOMAIN>
#   3. CLIENT_ID/SECRET fall back to the template UUIDs from the DB dump
# ---------------------------------------------------------------------------

# Template UUIDs from the BSON dump (used as fallback when client does not
# provide custom credentials). These match IdentityProviders.ClientId and
# OidcClientRegistrations.ClientId in the shipped dump.
_OS_TPL_ID="5225b9c1-15bc-41b0-bdc6-d3ceb180ccc5"
_IAM_TPL_ID="a5831e15-e193-4a4f-8e10-d04a4ad1705b"
_DATA_TPL_ID="e76867a8-37a1-483e-a15e-875c3884b8e8"
_LOGIC_TPL_ID="a25aee32-73ae-484b-b813-522a8d091f89"
_LOC_TPL_ID="57214b67-aa9c-4307-92ab-a25e35180fac"
_STUDIO_TPL_ID="7ac88264-e7dd-42ec-be76-ae14ad7e3758"
_RELEASE_TPL_ID="6523b311-256f-4b9a-a88a-2ac4e02bad25"
_MONITOR_TPL_ID="1bd234da-1fa1-4264-982e-3debb1078be5"
_AGENTS_TPL_ID="c1565dbc-de65-4966-a427-0ed9e542c678"
_UTIL_TPL_ID="4f7ae2b9-4b42-4770-9138-63db08538629"
_TPL_SECRET="c0fc0eebbc9c4e89bed9e365ee9f9a14"

_resolve() {
  # _resolve URL_VAR ID_VAR SECRET_VAR DEFAULT_URL DEFAULT_ID
  local url_var="$1" id_var="$2" sec_var="$3" def_url="$4" def_id="$5"
  echo "${!url_var:-$def_url}|${!id_var:-$def_id}|${!sec_var:-$_TPL_SECRET}"
}

IFS='|' read -r OS_URL           OS_CLIENT_ID           OS_CLIENT_SECRET           <<< "$(_resolve OS_URL           OS_CLIENT_ID           OS_CLIENT_SECRET           "https://os.${DOMAIN}"           "$_OS_TPL_ID")"
IFS='|' read -r IAM_URL          IAM_CLIENT_ID          IAM_CLIENT_SECRET          <<< "$(_resolve IAM_URL          IAM_CLIENT_ID          IAM_CLIENT_SECRET          "https://iam.${DOMAIN}"          "$_IAM_TPL_ID")"
IFS='|' read -r DATA_URL         DATA_CLIENT_ID         DATA_CLIENT_SECRET         <<< "$(_resolve DATA_URL         DATA_CLIENT_ID         DATA_CLIENT_SECRET         "https://data.${DOMAIN}"         "$_DATA_TPL_ID")"
IFS='|' read -r LOGIC_URL        LOGIC_CLIENT_ID        LOGIC_CLIENT_SECRET        <<< "$(_resolve LOGIC_URL        LOGIC_CLIENT_ID        LOGIC_CLIENT_SECRET        "https://logic.${DOMAIN}"        "$_LOGIC_TPL_ID")"
IFS='|' read -r LOCALIZATION_URL LOCALIZATION_CLIENT_ID LOCALIZATION_CLIENT_SECRET <<< "$(_resolve LOCALIZATION_URL LOCALIZATION_CLIENT_ID LOCALIZATION_CLIENT_SECRET "https://localization.${DOMAIN}" "$_LOC_TPL_ID")"
IFS='|' read -r STUDIO_URL       STUDIO_CLIENT_ID       STUDIO_CLIENT_SECRET       <<< "$(_resolve STUDIO_URL       STUDIO_CLIENT_ID       STUDIO_CLIENT_SECRET       "https://studio.${DOMAIN}"       "$_STUDIO_TPL_ID")"
IFS='|' read -r RELEASE_URL      RELEASE_CLIENT_ID      RELEASE_CLIENT_SECRET      <<< "$(_resolve RELEASE_URL      RELEASE_CLIENT_ID      RELEASE_CLIENT_SECRET      "https://release.${DOMAIN}"      "$_RELEASE_TPL_ID")"
IFS='|' read -r MONITOR_URL      MONITOR_CLIENT_ID      MONITOR_CLIENT_SECRET      <<< "$(_resolve MONITOR_URL      MONITOR_CLIENT_ID      MONITOR_CLIENT_SECRET      "https://monitor.${DOMAIN}"      "$_MONITOR_TPL_ID")"
IFS='|' read -r AGENTS_URL       AGENTS_CLIENT_ID       AGENTS_CLIENT_SECRET       <<< "$(_resolve AGENTS_URL       AGENTS_CLIENT_ID       AGENTS_CLIENT_SECRET       "https://agents.${DOMAIN}"       "$_AGENTS_TPL_ID")"
IFS='|' read -r UTILITIES_URL    UTILITIES_CLIENT_ID    UTILITIES_CLIENT_SECRET    <<< "$(_resolve UTILITIES_URL    UTILITIES_CLIENT_ID    UTILITIES_CLIENT_SECRET    "https://utilities.${DOMAIN}"    "$_UTIL_TPL_ID")"

ROOT_TENANT_ID="${ROOT_TENANT_ID:-f080a1bea04280a72149fd689d50a48c}"
# Tenant DB connection string is persisted into the database and read by other
# apps, so it must use a host-reachable address — not the in-network `mongodb`
# name. Default to APP_DB_CONNECTION (host IP + published port, written by
# run.sh); fall back to HOST_IP:MONGO_HOST_PORT, then the in-network name.
TENANT_DB_CONNECTION_STRING="${TENANT_DB_CONNECTION_STRING:-${APP_DB_CONNECTION:-mongodb://${MONGO_USER:-root}:${MONGO_PASS:-root}@${HOST_IP:-mongodb}:${MONGO_HOST_PORT:-27017}/?authSource=admin}}"

# ---------------------------------------------------------------------------
# Generate configure.js
# ---------------------------------------------------------------------------
_out="$_script_dir/configure.js"

cat > "$_out" << JSEOF
// configure.js — Generated by configure.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
// DO NOT EDIT MANUALLY. Re-run:  bash configure.sh
//
// Executed by mongodb-seed (mongosh BlocksRootDb) after mongorestore.
// Updates: IdentityProviders · OidcClientRegistrations · Tenants · Secrets · MonitorConfigurations

'use strict';
print('');
print('=== Blocks configure.js starting ===');

const DOMAIN         = "${DOMAIN}";
const ROOT_TENANT_ID = "${ROOT_TENANT_ID}";
const TENANT_DB_CONN = "${TENANT_DB_CONNECTION_STRING}";

// Service registry — url / clientId / clientSecret / provider / displayName / clientName per service
// displayName matches IdentityProviders.DisplayName; clientName matches OidcClientRegistrations.ClientName.
// These stable fields are used as fallback lookups when _id or Provider don't match.
const services = {
  os:           { url: "${OS_URL}",           clientId: "${OS_CLIENT_ID}",           clientSecret: "${OS_CLIENT_SECRET}",           provider: "blocks-os",           displayName: "blocks OS",           clientName: "Blocks OS" },
  iam:          { url: "${IAM_URL}",          clientId: "${IAM_CLIENT_ID}",          clientSecret: "${IAM_CLIENT_SECRET}",          provider: "blocks-iam",          displayName: "blocks IAM",          clientName: "Blocks IAM" },
  data:         { url: "${DATA_URL}",         clientId: "${DATA_CLIENT_ID}",         clientSecret: "${DATA_CLIENT_SECRET}",         provider: "blocks-data",         displayName: "blocks DATA",         clientName: "Blocks DATA" },
  logic:        { url: "${LOGIC_URL}",        clientId: "${LOGIC_CLIENT_ID}",        clientSecret: "${LOGIC_CLIENT_SECRET}",        provider: "blocks-logic",        displayName: "blocks LOGIC",        clientName: "Blocks LOGIC" },
  localization: { url: "${LOCALIZATION_URL}", clientId: "${LOCALIZATION_CLIENT_ID}", clientSecret: "${LOCALIZATION_CLIENT_SECRET}", provider: "blocks-localization", displayName: "blocks LOCALIZATION", clientName: "Blocks LOCALIZATION" },
  studio:       { url: "${STUDIO_URL}",       clientId: "${STUDIO_CLIENT_ID}",       clientSecret: "${STUDIO_CLIENT_SECRET}",       provider: "blocks-studio",       displayName: "blocks STUDIO",       clientName: "Blocks STUDIO" },
  release:      { url: "${RELEASE_URL}",      clientId: "${RELEASE_CLIENT_ID}",      clientSecret: "${RELEASE_CLIENT_SECRET}",      provider: "blocks-release",      displayName: "blocks RELEASE",      clientName: "Blocks RELEASE" },
  monitor:      { url: "${MONITOR_URL}",      clientId: "${MONITOR_CLIENT_ID}",      clientSecret: "${MONITOR_CLIENT_SECRET}",      provider: "blocks-monitor",      displayName: "blocks MONITOR",      clientName: "Blocks MONITOR" },
  agents:       { url: "${AGENTS_URL}",       clientId: "${AGENTS_CLIENT_ID}",       clientSecret: "${AGENTS_CLIENT_SECRET}",       provider: "blocks-agents",       displayName: "blocks AGENTS",       clientName: "Blocks AGENTS" },
  utilities:    { url: "${UTILITIES_URL}",    clientId: "${UTILITIES_CLIENT_ID}",    clientSecret: "${UTILITIES_CLIENT_SECRET}",    provider: "blocks-utilities",    displayName: "blocks UTILITIES",    clientName: "Blocks UTILITIES" },
};

// Template clientIds (shipped in the BSON dump). Used to locate existing
// OidcClientRegistrations entries on first run when the client has provided
// a custom clientId that differs from the dump default.
const templateIds = {
  os:           "${_OS_TPL_ID}",
  iam:          "${_IAM_TPL_ID}",
  data:         "${_DATA_TPL_ID}",
  logic:        "${_LOGIC_TPL_ID}",
  localization: "${_LOC_TPL_ID}",
  studio:       "${_STUDIO_TPL_ID}",
  release:      "${_RELEASE_TPL_ID}",
  monitor:      "${_MONITOR_TPL_ID}",
  agents:       "${_AGENTS_TPL_ID}",
  utilities:    "${_UTIL_TPL_ID}",
};

const iamUrl = services.iam.url;

// ============================================================
// 1. IdentityProviders
// ============================================================
print('1/5  IdentityProviders...');

for (const [svcName, cfg] of Object.entries(services)) {
  const existing = db.IdentityProviders.findOne({
    \$or: [
      { Provider:    { \$regex: '^' + cfg.provider    + '$', \$options: 'i' } },
      { DisplayName: { \$regex: '^' + cfg.displayName + '$', \$options: 'i' } },
    ],
  });
  if (!existing) {
    print('     SKIP ' + cfg.provider + ': document not found');
    continue;
  }

  const fields = {
    ClientId:          cfg.clientId,
    ClientSecret:      cfg.clientSecret,
    Issuer:            iamUrl,
    AuthorizationUrl:  iamUrl + '/api/oidc/authorize?tenant_id=' + ROOT_TENANT_ID,
    TokenUrl:          iamUrl + '/api/oidc/token?tenant_id='      + ROOT_TENANT_ID,
    UserInfoUrl:       iamUrl + '/api/auth/userinfo?tenant_id='   + ROOT_TENANT_ID,
    JwksUri:           iamUrl + '/' + ROOT_TENANT_ID + '/.well-known/jwks.json',
    WellKnownUrl:      iamUrl + '/' + ROOT_TENANT_ID + '/.well-known/openid-configuration',
    RedirectUris:      [cfg.url + '/login/callback'],
    LastUpdatedDate:   new Date(),
  };

  // Always set _id = cfg.clientId. MongoDB cannot update _id in place,
  // so delete the old document and reinsert with the new _id whenever it differs.
  if (existing._id !== cfg.clientId) {
    db.IdentityProviders.deleteOne({ _id: existing._id });
    db.IdentityProviders.insertOne(Object.assign({}, existing, fields, { _id: cfg.clientId }));
    print('     ' + cfg.provider + ': replaced (new _id/ClientId: ' + cfg.clientId + ')');
  } else {
    db.IdentityProviders.updateOne({ _id: existing._id }, { \$set: fields });
    print('     ' + cfg.provider + ': updated');
  }
}

// ============================================================
// 2. OidcClientRegistrations
// ============================================================
print('2/5  OidcClientRegistrations...');

for (const [svcName, cfg] of Object.entries(services)) {
  // Look up by new clientId or template ID first (covers first-run and
  // idempotent re-runs with the same credentials).
  // Fallback: search by redirect URI restricted to blk- prefixed _ids only.
  // The blk- restriction prevents accidentally matching project-level
  // OidcClientRegistrations that happen to share the same service redirect URI
  // (e.g. a project registered under os.domain.com) — those documents must
  // never be touched by this script.
  const existing = db.OidcClientRegistrations.findOne({
    \$or: [
      { _id: { \$in: [cfg.clientId, templateIds[svcName]] } },
      { ClientId: { \$in: [cfg.clientId, templateIds[svcName]] } },
      { ClientName: { \$regex: '^' + cfg.clientName + '$', \$options: 'i' } },
      { RedirectUris: cfg.url + '/login/callback', _id: { \$regex: '^blk-' } },
    ],
  });

  if (!existing) {
    print('     SKIP ' + svcName + ': registration not found');
    continue;
  }

  const fields = {
    ClientId:                  cfg.clientId,
    ClientSecret:              cfg.clientSecret,
    RedirectUris:              [cfg.url + '/login/callback'],
    ExternalDiscoveryEndpoint: iamUrl + '/' + ROOT_TENANT_ID + '/.well-known/openid-configuration',
    LastUpdatedDate:           new Date(),
  };

  // Always set _id = cfg.clientId. MongoDB cannot update _id in place,
  // so delete the old document and reinsert with the new _id whenever it differs.
  if (existing._id !== cfg.clientId) {
    db.OidcClientRegistrations.deleteOne({ _id: existing._id });
    db.OidcClientRegistrations.insertOne(Object.assign({}, existing, fields, { _id: cfg.clientId }));
    print('     ' + svcName + ': replaced (new _id/ClientId: ' + cfg.clientId + ')');
  } else {
    db.OidcClientRegistrations.updateOne({ _id: existing._id }, { \$set: fields });
    print('     ' + svcName + ': updated');
  }
}

// ============================================================
// 3. Tenants
// ============================================================
print('3/5  Tenants...');

// Update DbConnectionString on every tenant (root + all project tenants)
const dbConnResult = db.Tenants.updateMany(
  {},
  { \$set: { DbConnectionString: TENANT_DB_CONN } }
);
print('     DbConnectionString updated on ' + dbConnResult.modifiedCount + ' tenant(s)');

// Rebuild the root tenant Applications array with the current service URLs.
// The CookieDomain is set to the base DOMAIN for all entries.
const applications = Object.values(services).map(function(cfg) {
  return { Domain: cfg.url, CookieDomain: DOMAIN, IsDomainVerified: true };
});

const rootResult = db.Tenants.updateOne(
  { TenantId: ROOT_TENANT_ID },
  {
    \$set: {
      Applications:                       applications,
      'JwtTokenParameters.Audiences':     [iamUrl],
      LastUpdatedDate:                    new Date(),
    },
  }
);
print('     Root tenant (' + ROOT_TENANT_ID + ') Applications rebuilt: ' + rootResult.modifiedCount);

// ============================================================
// 4. Secrets
// ============================================================
print('4/5  Secrets...');

// KeyPairs fields that are the same across all service secret documents
const sharedKP = {
  'RootTenantId':                                    ROOT_TENANT_ID,
  'root_tenant_id':                                  ROOT_TENANT_ID,
  'FrontendRuntime:BLOCKS_X_BLOCKS_KEY':             ROOT_TENANT_ID,
  'FrontendRuntime:BLOCKS_BASE_DOMAIN':              DOMAIN,
  'FrontendRuntime:BLOCKS_IDP_BASE_URL':             iamUrl,
  'FrontendRuntime:BLOCKS_OS_BASE_URL':              services.os.url,
  'FrontendRuntime:BLOCKS_OS_CALLBACK_URL':          services.os.url + '/login/callback',
  'FrontendRuntime:BLOCKS_IAM_BASE_URL':             iamUrl,
  'FrontendRuntime:BLOCKS_IAM_CALLBACK_URL':         iamUrl + '/login/callback',
  'FrontendRuntime:BLOCKS_DATA_BASE_URL':            services.data.url,
  'FrontendRuntime:BLOCKS_DATA_CALLBACK_URL':        services.data.url + '/login/callback',
  'FrontendRuntime:BLOCKS_LOGIC_BASE_URL':           services.logic.url,
  'FrontendRuntime:BLOCKS_LOGIC_CALLBACK_URL':       services.logic.url + '/login/callback',
  'FrontendRuntime:BLOCKS_LOCALIZATION_BASE_URL':    services.localization.url,
  'FrontendRuntime:BLOCKS_LOCALIZATION_CALLBACK_URL': services.localization.url + '/login/callback',
  'FrontendRuntime:BLOCKS_STUDIO_BASE_URL':          services.studio.url,
  'FrontendRuntime:BLOCKS_STUDIO_CALLBACK_URL':      services.studio.url + '/login/callback',
  'FrontendRuntime:BLOCKS_RELEASE_BASE_URL':         services.release.url,
  'FrontendRuntime:BLOCKS_RELEASE_CALLBACK_URL':     services.release.url + '/login/callback',
  'FrontendRuntime:BLOCKS_MONITOR_BASE_URL':         services.monitor.url,
  'FrontendRuntime:BLOCKS_MONITOR_CALLBACK_URL':     services.monitor.url + '/login/callback',
  'FrontendRuntime:BLOCKS_AGENTS_BASE_URL':          services.agents.url,
  'FrontendRuntime:BLOCKS_AGENTS_CALLBACK_URL':      services.agents.url + '/login/callback',
  'FrontendRuntime:BLOCKS_UTILITIES_BASE_URL':       services.utilities.url,
  'FrontendRuntime:BLOCKS_UTILITIES_CALLBACK_URL':   services.utilities.url + '/login/callback',
  'FrontendRuntime:BLOCKS_OS_CLIENT_ID':             services.os.clientId,
  'FrontendRuntime:BLOCKS_IAM_CLIENT_ID':            services.iam.clientId,
  'FrontendRuntime:BLOCKS_DATA_CLIENT_ID':           services.data.clientId,
  'FrontendRuntime:BLOCKS_LOGIC_CLIENT_ID':          services.logic.clientId,
  'FrontendRuntime:BLOCKS_LOCALIZATION_CLIENT_ID':   services.localization.clientId,
  'FrontendRuntime:BLOCKS_STUDIO_CLIENT_ID':         services.studio.clientId,
  'FrontendRuntime:BLOCKS_RELEASE_CLIENT_ID':        services.release.clientId,
  'FrontendRuntime:BLOCKS_MONITOR_CLIENT_ID':        services.monitor.clientId,
  'FrontendRuntime:BLOCKS_AGENTS_CLIENT_ID':         services.agents.clientId,
  'FrontendRuntime:BLOCKS_UTILITIES_CLIENT_ID':      services.utilities.clientId,
  'NotificationServiceUrl': services.logic.url + '/api/Notifier/SendSecretNotification',
  'AlertServiceUrl':        services.monitor.url + '/api/health/ping',
};

// Build a \$set payload using dot notation into KeyPairs
function buildKPSet(extraKP) {
  const result = {};
  const merged = Object.assign({}, sharedKP, extraKP);
  for (const [k, v] of Object.entries(merged)) {
    result['KeyPairs.' + k] = v;
  }
  return result;
}

// Service secrets with their specific OIDC client ID
const serviceSecrets = [
  { secretKey: 'blocks-secret-os',           oidcClientId: services.os.clientId,           extraKP: {} },
  { secretKey: 'blocks-secret-iam',          oidcClientId: services.iam.clientId,          extraKP: {} },
  { secretKey: 'blocks-secret-logic',        oidcClientId: services.logic.clientId,        extraKP: {} },
  { secretKey: 'blocks-secret-localization', oidcClientId: services.localization.clientId, extraKP: {} },
  { secretKey: 'blocks-secret-monitor',      oidcClientId: services.monitor.clientId,      extraKP: {} },
  { secretKey: 'blocks-secret-release', oidcClientId: services.release.clientId, extraKP: {
    'DeploymentApiBaseUrl': services.release.url,
    'GithubWebhookUrl':     services.release.url + '/api/github/webhook?x-blocks-key=',
    'FrontendRuntime:BLOCKS_APP_URL':        services.release.url,
    'FrontendRuntime:BLOCKS_API_BASE_URL':   services.release.url,
  }},
  { secretKey: 'blocks-secret-agents', oidcClientId: services.agents.clientId, extraKP: {
    'base_url':               services.agents.url,
    'iam_base_url':           iamUrl,
    'lmt_base_url':           services.os.url,
    'notification_base_url':  services.logic.url,
    'storage_base_url':       services.logic.url,
    'FrontendRuntime:BLOCKS_API_BASE_URL':  services.agents.url,
    'FrontendRuntime:BLOCKS_UDS_BASE_URL':  services.data.url,
    'FrontendRuntime:BLOCKS_LOGIC_APP_URL': services.logic.url,
  }},
  { secretKey: 'blocks-secret-studio', oidcClientId: services.studio.clientId, extraKP: {
    'FrontendRuntime:BLOCKS_APP_URL':      services.studio.url,
    'FrontendRuntime:BLOCKS_API_BASE_URL': services.studio.url,
  }},
  { secretKey: 'blocks-secret-data', oidcClientId: services.data.clientId, extraKP: {
    'FrontendRuntime:BLOCKS_APP_URL':      services.data.url,
    'FrontendRuntime:BLOCKS_API_BASE_URL': services.data.url,
  }},
  { secretKey: 'blocks-secret-utilities', oidcClientId: services.utilities.clientId, extraKP: {
    'FrontendRuntime:BLOCKS_APP_URL':      services.utilities.url,
    'FrontendRuntime:BLOCKS_API_BASE_URL': services.utilities.url,
  }},
];

for (const entry of serviceSecrets) {
  const setPayload = buildKPSet(
    Object.assign({ 'FrontendRuntime:BLOCKS_OIDC_CLIENT_ID': entry.oidcClientId }, entry.extraKP)
  );
  const r = db.Secrets.updateOne({ SecretKey: entry.secretKey }, { \$set: setPayload });
  print('     ' + entry.secretKey + ': ' + (r.matchedCount ? 'updated' : 'not found'));
}

// blocks-Secret — general/shared secret
const blocksSecretSet = buildKPSet({
  'FrontendRuntime:BLOCKS_OIDC_CLIENT_ID': services.release.clientId,
  'FrontendRuntime:BLOCKS_APP_URL':        services.release.url,
  'FrontendRuntime:BLOCKS_API_BASE_URL':   services.release.url,
  'FrontendRuntime:BLOCKS_LOGIC_APP_URL':  services.logic.url,
  'AgentBaseUrl':                          services.agents.url,
  'IdpBaseUrl':                            iamUrl,
  'LogicBaseUrl':                          services.logic.url,
  'UtilityBaseUrl':                        services.utilities.url,
});
const bsr = db.Secrets.updateOne({ SecretKey: 'blocks-Secret' }, { \$set: blocksSecretSet });
print('     blocks-Secret: ' + (bsr.matchedCount ? 'updated' : 'not found'));

// ============================================================
// 5. MonitorConfigurations
// ============================================================
print('5/5  MonitorConfigurations...');

const monitorUrlMap = [
  { name: 'release',      url: services.release.url      + '/ping' },
  { name: 'data',         url: services.data.url         + '/ping' },
  { name: 'localization', url: services.localization.url + '/ping' },
  { name: 'blocks os',    url: services.os.url           + '/ping' },
  { name: 'iam',          url: services.iam.url          + '/ping' },
  { name: 'logic',        url: services.logic.url        + '/ping' },
  { name: 'agents',       url: services.agents.url       + '/ping' },
  { name: 'studio',       url: services.studio.url       + '/ping' },
  { name: 'monitor',      url: services.monitor.url      + '/ping' },
  { name: 'utilities',    url: services.utilities.url    + '/ping' },
];

for (const entry of monitorUrlMap) {
  const r = db.MonitorConfigurations.updateOne(
    { Name: { \$regex: '^' + entry.name + '$', \$options: 'i' } },
    { \$set: { Url: entry.url, LastUpdatedDate: new Date() } }
  );
  print('     ' + entry.name + ': ' + (r.matchedCount ? 'updated' : 'not found'));
}

print('');
print('=== Blocks configure.js complete ===');
JSEOF

echo "configure.sh: configure.js written to $_out"
echo ""
echo "Summary:"
echo "  Domain          : $DOMAIN"
echo "  Root Tenant ID  : $ROOT_TENANT_ID"
echo "  Tenant DB conn  : $TENANT_DB_CONNECTION_STRING"
echo ""
echo "  Service URLs and credentials:"
printf "  %-14s  %s  (clientId: %s)\n" "os"           "$OS_URL"           "$OS_CLIENT_ID"
printf "  %-14s  %s  (clientId: %s)\n" "iam"          "$IAM_URL"          "$IAM_CLIENT_ID"
printf "  %-14s  %s  (clientId: %s)\n" "data"         "$DATA_URL"         "$DATA_CLIENT_ID"
printf "  %-14s  %s  (clientId: %s)\n" "logic"        "$LOGIC_URL"        "$LOGIC_CLIENT_ID"
printf "  %-14s  %s  (clientId: %s)\n" "localization" "$LOCALIZATION_URL" "$LOCALIZATION_CLIENT_ID"
printf "  %-14s  %s  (clientId: %s)\n" "studio"       "$STUDIO_URL"       "$STUDIO_CLIENT_ID"
printf "  %-14s  %s  (clientId: %s)\n" "release"      "$RELEASE_URL"      "$RELEASE_CLIENT_ID"
printf "  %-14s  %s  (clientId: %s)\n" "monitor"      "$MONITOR_URL"      "$MONITOR_CLIENT_ID"
printf "  %-14s  %s  (clientId: %s)\n" "agents"       "$AGENTS_URL"       "$AGENTS_CLIENT_ID"
printf "  %-14s  %s  (clientId: %s)\n" "utilities"    "$UTILITIES_URL"    "$UTILITIES_CLIENT_ID"
echo ""
echo "configure.js will be executed by mongodb-seed on next 'docker compose up --profile infra'."
