metadata description = 'Azure-native, self-hosted MongoDB 7 replica set (3 nodes) on Azure Container Apps. Each node is a single-replica container app with internal TCP ingress and its own Azure Files volume for /data/db, plus a shared keyfile for internal auth. Replica-set initiation (rs.initiate) is performed once by deploy.sh after the nodes are healthy. This is the OpenSign-compatible MongoDB backend (Cosmos vCore is incompatible).'

@description('Container Apps managed environment resource id.')
param managedEnvironmentId string

@description('Azure region.')
param location string

@description('Standard tag set.')
param tags object

@description('Base name for the mongo node apps, e.g. ca-loka-esign-mongo.')
param nodeBaseName string

@description('Storage account name that backs the per-node Azure Files shares.')
param storageAccountName string

@description('MongoDB image (pinned).')
param mongoImage string = 'docker.io/library/mongo:7.0'

@description('Per-node CPU.')
param cpu string = '2.0'

@description('Per-node memory.')
param memory string = '4Gi'

@description('Replica set name.')
param replicaSetName string = 'rs0'

@description('MongoDB keyfile contents (base64, >=6 chars) for internal replica-set auth.')
@secure()
param keyfileContent string

@description('MongoDB root username.')
param rootUser string = 'osgnroot'

@description('MongoDB root password.')
@secure()
param rootPassword string

var nodeCount int = 3

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2024-01-01' existing = {
  parent: storage
  name: 'default'
}

// Per-node data shares.
resource dataShares 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = [for i in range(0, nodeCount): {
  parent: fileService
  name: 'mongo-data-${i}'
  properties: {
    shareQuota: 128
    enabledProtocols: 'SMB'
  }
}]

resource env 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: last(split(managedEnvironmentId, '/'))
}

// Register each data share as an environment storage so apps can mount it.
resource envStorages 'Microsoft.App/managedEnvironments/storages@2024-03-01' = [for i in range(0, nodeCount): {
  parent: env
  name: 'mongo-data-${i}'
  properties: {
    azureFile: {
      accountName: storageAccountName
      accountKey: storage.listKeys().keys[0].value
      shareName: 'mongo-data-${i}'
      accessMode: 'ReadWrite'
    }
  }
  dependsOn: [
    dataShares
  ]
}]

// Three MongoDB nodes, each a single-replica container app with internal TCP ingress.
resource mongoNodes 'Microsoft.App/containerApps@2024-03-01' = [for i in range(0, nodeCount): {
  name: '${nodeBaseName}-${i}'
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: 27017
        exposedPort: 27017
        transport: 'tcp'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      secrets: [
        { name: 'keyfile', value: keyfileContent }
        { name: 'root-user', value: rootUser }
        { name: 'root-password', value: rootPassword }
      ]
    }
    template: {
      containers: [
        {
          name: 'mongo'
          image: mongoImage
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          // Start mongod as a replica-set member with keyfile auth.
          command: [
            '/bin/sh'
            '-c'
          ]
          args: [
            'set -e; install -m 400 -o 999 -g 999 /tmp/keyfile-src /data/keyfile 2>/dev/null || (cp /tmp/keyfile-src /data/keyfile && chmod 400 /data/keyfile && chown 999:999 /data/keyfile); exec docker-entrypoint.sh mongod --replSet ${replicaSetName} --keyFile /data/keyfile --bind_ip_all --dbpath /data/db'
          ]
          env: [
            { name: 'MONGO_INITDB_ROOT_USERNAME', secretRef: 'root-user' }
            { name: 'MONGO_INITDB_ROOT_PASSWORD', secretRef: 'root-password' }
          ]
          volumeMounts: [
            {
              volumeName: 'data'
              mountPath: '/data/db'
            }
            {
              volumeName: 'keyfile'
              mountPath: '/tmp'
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'data'
          storageType: 'AzureFile'
          storageName: 'mongo-data-${i}'
        }
        {
          name: 'keyfile'
          storageType: 'Secret'
          secrets: [
            {
              secretRef: 'keyfile'
              path: 'keyfile-src'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
  dependsOn: [
    envStorages
  ]
}]

output replicaSetName string = replicaSetName
output nodeHosts array = [for i in range(0, nodeCount): '${nodeBaseName}-${i}.internal.${env.properties.defaultDomain}:27017']
output internalDomain string = env.properties.defaultDomain
output nodeBaseName string = nodeBaseName
output nodeCount int = nodeCount
