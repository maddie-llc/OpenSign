metadata description = 'OpenSign compute layer: Container Apps environment, Azure Files storage link, and the server, client, and Caddy proxy container apps. Resource-group scoped.'

@description('Resource names from the naming module.')
param names object

@description('Azure region.')
param location string

@description('Standard tag set.')
param tags object

@description('User-assigned managed identity resource id.')
param identityId string

@description('Log Analytics customer (workspace) id.')
param logAnalyticsCustomerId string

@description('Log Analytics shared key.')
@secure()
param logAnalyticsSharedKey string

@description('Existing storage account name (for the Azure Files mount).')
param storageName string

@description('Azure Files share name.')
param fileShareName string

@description('Server container image.')
param serverImage string

@description('Client container image.')
param clientImage string

@description('Caddy proxy container image.')
param caddyImage string

@description('OpenSign app id (non-secret).')
param appId string

@description('OpenSign master key.')
@secure()
param masterKey string

@description('Full MongoDB connection URI (assembled in deploy.sh).')
@secure()
param mongoUri string

@description('Server scaling spec.')
param serverScale object

@description('Edge (client/proxy) scaling spec.')
param edgeScale object

@description('Mongo driver max pool size per replica.')
param mongoMaxPoolSize int

@description('Max concurrent docx->pdf conversions per replica.')
param docx2pdfConcurrency int

@description('Optional SMTP host for disposable-inbox OTP testing. Empty disables email.')
param smtpHost string = ''

@description('SMTP port.')
param smtpPort string = '587'

@description('SMTP from/user email.')
param smtpUserEmail string = ''

@description('SMTP password.')
@secure()
param smtpPass string = ''

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageName
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: names.acaEnvironment
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsCustomerId
        sharedKey: logAnalyticsSharedKey
      }
    }
  }
}

resource envStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: env
  name: 'opensign-files'
  properties: {
    azureFile: {
      accountName: storageName
      accountKey: storage.listKeys().keys[0].value
      shareName: fileShareName
      accessMode: 'ReadWrite'
    }
  }
}

var hostUrl string = 'https://${names.appProxy}.${env.properties.defaultDomain}'
var serverInternalFqdn string = '${names.appServer}.internal.${env.properties.defaultDomain}'
var clientInternalFqdn string = '${names.appClient}.internal.${env.properties.defaultDomain}'

var smtpEnabled bool = !empty(smtpHost)

var serverEnvBase array = [
  { name: 'APP_ID', value: appId }
  { name: 'appName', value: 'OpenSign' }
  { name: 'PARSE_MOUNT', value: '/app' }
  { name: 'USE_LOCAL', value: 'true' }
  { name: 'SERVER_URL', value: '${hostUrl}/api/app' }
  { name: 'PUBLIC_URL', value: hostUrl }
  { name: 'MONGODB_URI', secretRef: 'mongodb-uri' }
  { name: 'DATABASE_URI', secretRef: 'mongodb-uri' }
  { name: 'MASTER_KEY', secretRef: 'master-key' }
  { name: 'DOCX2PDF_CONCURRENCY', value: string(docx2pdfConcurrency) }
  { name: 'MONGO_MAX_POOL_SIZE', value: string(mongoMaxPoolSize) }
]

var serverEnvSmtp array = smtpEnabled ? [
  { name: 'SMTP_ENABLE', value: 'true' }
  { name: 'SMTP_HOST', value: smtpHost }
  { name: 'SMTP_PORT', value: smtpPort }
  { name: 'SMTP_USER_EMAIL', value: smtpUserEmail }
  { name: 'SMTP_PASS', secretRef: 'smtp-pass' }
] : []

resource serverApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: names.appServer
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: 8080
        transport: 'http'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      secrets: concat([
        { name: 'master-key', value: masterKey }
        { name: 'mongodb-uri', value: mongoUri }
      ], smtpEnabled ? [ { name: 'smtp-pass', value: smtpPass } ] : [])
    }
    template: {
      containers: [
        {
          name: 'server'
          image: serverImage
          resources: {
            cpu: json(serverScale.cpu)
            memory: serverScale.memory
          }
          env: concat(serverEnvBase, serverEnvSmtp)
          volumeMounts: [
            {
              volumeName: 'files'
              mountPath: '/usr/src/app/files'
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'files'
          storageType: 'AzureFile'
          storageName: envStorage.name
        }
      ]
      scale: {
        minReplicas: serverScale.minReplicas
        maxReplicas: serverScale.maxReplicas
        rules: [
          {
            name: 'http-concurrency'
            http: {
              metadata: {
                concurrentRequests: string(serverScale.concurrency)
              }
            }
          }
        ]
      }
    }
  }
}

resource clientApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: names.appClient
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: 3000
        transport: 'http'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'client'
          image: clientImage
          resources: {
            cpu: json(edgeScale.cpu)
            memory: edgeScale.memory
          }
          env: [
            { name: 'REACT_APP_APPID', value: appId }
            { name: 'REACT_APP_SERVERURL', value: '${hostUrl}/api/app' }
            { name: 'PUBLIC_URL', value: hostUrl }
          ]
        }
      ]
      scale: {
        minReplicas: edgeScale.minReplicas
        maxReplicas: edgeScale.maxReplicas
      }
    }
  }
}

// Caddy reverse proxy: routes /api/* to the server and everything else to the client.
// The Caddyfile is injected as a mounted secret so no custom image build is required.
var caddyfile string = '''
:80 {
  encode gzip
  handle_path /api/* {
    reverse_proxy http://SERVER_FQDN:8080
  }
  reverse_proxy http://CLIENT_FQDN:3000
}
'''

var caddyfileResolved string = replace(replace(caddyfile, 'SERVER_FQDN', serverInternalFqdn), 'CLIENT_FQDN', clientInternalFqdn)

resource proxyApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: names.appProxy
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 80
        transport: 'http'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      secrets: [
        {
          name: 'caddyfile'
          value: caddyfileResolved
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'proxy'
          image: caddyImage
          resources: {
            cpu: json(edgeScale.cpu)
            memory: edgeScale.memory
          }
          volumeMounts: [
            {
              volumeName: 'caddy-config'
              mountPath: '/etc/caddy'
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'caddy-config'
          storageType: 'Secret'
          secrets: [
            {
              secretRef: 'caddyfile'
              path: 'Caddyfile'
            }
          ]
        }
      ]
      scale: {
        minReplicas: edgeScale.minReplicas
        maxReplicas: edgeScale.maxReplicas
      }
    }
  }
}

output proxyFqdn string = proxyApp.properties.configuration.ingress.fqdn
output serverInternalFqdn string = serverInternalFqdn
output hostUrl string = hostUrl
