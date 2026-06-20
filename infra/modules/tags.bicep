metadata description = 'Returns the standard LoKation OpenSign tag set.'

@description('Deployment environment, e.g. dev or prod.')
param environment string

@description('Cost center tag value.')
param costCenter string = 'lokation-esign'

@export()
type TagSet = {
  project: string
  solution: string
  environment: string
  costCenter: string
  managedBy: string
}

var tagsOut object = {
  project: 'esign'
  solution: 'opensign'
  environment: environment
  costCenter: costCenter
  managedBy: 'bicep'
}

output tags object = tagsOut
