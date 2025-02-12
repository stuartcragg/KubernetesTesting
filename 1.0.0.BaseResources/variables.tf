#--------------------------------------------------------------------------------------------------------
# 1) Variables for the GitHub Service Connection Module.
#--------------------------------------------------------------------------------------------------------

variable "subscription_id" {
  description = "The Azure subscription where the managed identity will be created"
  type = string
}

variable "tenant_id" {
  description = "Azure tenant ID for the deployment"
  type        = string
}

variable "location" {
  description = "Azure region for the deployment"
  type        = string
}

variable "rg_name" {
  description = "Name of the resource group for the managed idetity deployment"
  type = string
}

variable "mi_name" {
    description = "Name of the managed identity as seen on Azure"
    type = string
}

variable "github_org" {
    description = "GitHub organization"
    type = string
}

variable "github_repo" {
    description = "GitHub repository that the service connection will have access to"
}

variable "scope" {
  description = "Scope of where to apply the permissions for the managed identity."
  type = string
}