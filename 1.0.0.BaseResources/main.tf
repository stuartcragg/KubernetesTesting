#--------------------------------------------------------------------------------------------------------
# 1) Call the GitHub Service Connection Module to setup a OIDC with a managed identity
#--------------------------------------------------------------------------------------------------------

module "oidc" {
    source = "github.com/stuartcragg/TerraformModules//TFGHServiceConnection?ref=main"

    subscription_id = var.subscription_id
    tenant_id = var.tenant_id
    rg_name = var.rg_name
    location = var.location
    mi_name = var.mi_name
    scope = var.scope
    github_org = var.github_org
    github_repo = var.github_repo
}