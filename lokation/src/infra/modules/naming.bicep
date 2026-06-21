metadata description = 'Builds deterministic resource names for the OpenSign deployment from slug/project/env.'

@description('4-letter customer slug, e.g. loka.')
@minLength(3)
@maxLength(5)
param slug string

@description('Project key, e.g. esign.')
@minLength(3)
@maxLength(12)
param projectKey string

@description('Deployment environment, e.g. dev or prod.')
param environment string

@description('Short unique suffix to keep globally-unique names distinct (e.g. uniqueString of the subscription/rg).')
param uniqueSuffix string

var base string = '${slug}-${projectKey}-${environment}'
// Names with no dashes allowed (storage, acr) must be <=24 / alphanumeric.
var compact string = toLower('${slug}${projectKey}${environment}')

@export()
type ResourceNames = {
  logAnalytics: string
  appInsights: string
  keyVault: string
  identity: string
  registry: string
  mongo: string
  storage: string
  acaEnvironment: string
  appServer: string
  appClient: string
  appProxy: string
}

output names ResourceNames = {
  logAnalytics: 'log-${base}'
  appInsights: 'appi-${base}'
  // Key Vault max 24 chars; keep compact + suffix.
  keyVault: take('kv-${compact}-${uniqueSuffix}', 24)
  identity: 'id-${base}'
  registry: take('acr${compact}${uniqueSuffix}', 50)
  mongo: 'mongo-${base}'
  storage: take('st${compact}${uniqueSuffix}', 24)
  acaEnvironment: 'cae-${base}'
  appServer: 'ca-${slug}-${projectKey}-server-${environment}'
  appClient: 'ca-${slug}-${projectKey}-client-${environment}'
  appProxy: 'ca-${slug}-${projectKey}-proxy-${environment}'
}
