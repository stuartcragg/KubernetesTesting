#!/bin/bash

# Exit on any error
set -e

# Variables (customize these as needed)
RESOURCE_GROUP="my-resource-group"              # Resource group in your subscription
LOCATION="eastus"                               # Azure region
STORAGE_ACCOUNT_NAME="mystorage$(date +%s)"     # Unique storage account name (timestamp for uniqueness)
VNET_NAME="my-vnet"                             # Existing VNet name
SUBNET_NAME="my-subnet"                         # Existing subnet name
PRIVATE_ENDPOINT_NAME="${STORAGE_ACCOUNT_NAME}-pe"
DNS_SUBSCRIPTION_ID="<dns-subscription-id>"     # Subscription ID with the private DNS zone
DNS_RESOURCE_GROUP="dns-rg"                     # Resource group with the private DNS zone
DNS_ZONE_NAME="privatelink.blob.core.windows.net" # Private DNS zone for Blob storage
DNS_RECORD_NAME="${STORAGE_ACCOUNT_NAME}"       # A record name (matches storage account)
CONTAINER_NAME="tfstate"                        # Container for Terraform state

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to check if a command succeeded
check_status() {
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: $1 failed${NC}"
        exit 1
    fi
}

echo -e "${GREEN}Starting deployment...${NC}"

# Step 1: Deploy the storage account with private endpoint
echo "Creating storage account: $STORAGE_ACCOUNT_NAME"

# Create the storage account
az storage account create \
    --name "$STORAGE_ACCOUNT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --kind "StorageV2" \
    --access-tier "Hot" \
    --min-tls-version "TLS1_2" \
    --require-infrastructure-encryption \
    --https-only true \
    --sku "Standard_LRS" \
    --default-action "Deny" \
    --bypass "AzureServices" \
    --output none
check_status "Storage account creation"

# Create the private endpoint
echo "Creating private endpoint for storage account"
SUBNET_ID=$(az network vnet subnet show \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --query id -o tsv)
check_status "Subnet ID retrieval"

az network private-endpoint create \
    --name "$PRIVATE_ENDPOINT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --subnet-id "$SUBNET_ID" \
    --private-connection-resource-id "$(az storage account show --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)" \
    --group-id "blob" \
    --connection-name "${STORAGE_ACCOUNT_NAME}-plink" \
    --location "$LOCATION" \
    --output none
check_status "Private endpoint creation"

# Update storage account network rules to allow private endpoint access
echo "Configuring storage account network rules"
PRIVATE_ENDPOINT_IP=$(az network private-endpoint show \
    --name "$PRIVATE_ENDPOINT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "customDnsConfigs[0].ipAddresses[0]" -o tsv)
check_status "Private endpoint IP retrieval"

az storage account network-rule add \
    --resource-group "$RESOURCE_GROUP" \
    --account-name "$STORAGE_ACCOUNT_NAME" \
    --subnet "$SUBNET_ID" \
    --output none
check_status "Network rule addition"

# Step 2: Create DNS A record in the private DNS zone in another subscription
echo "Creating DNS A record in subscription $DNS_SUBSCRIPTION_ID"
az account set --subscription "$DNS_SUBSCRIPTION_ID"
check_status "Switching to DNS subscription"

# Check if the A record already exists and update or create it
RECORD_EXISTS=$(az network private-dns record-set a show \
    --resource-group "$DNS_RESOURCE_GROUP" \
    --zone-name "$DNS_ZONE_NAME" \
    --name "$DNS_RECORD_NAME" \
    --query "id" -o tsv 2>/dev/null || echo "")
if [ -n "$RECORD_EXISTS" ]; then
    echo "Updating existing A record"
    az network private-dns record-set a update \
        --resource-group "$DNS_RESOURCE_GROUP" \
        --zone-name "$DNS_ZONE_NAME" \
        --name "$DNS_RECORD_NAME" \
        --set "aRecords[0].ipv4Address=$PRIVATE_ENDPOINT_IP" \
        --output none
    check_status "A record update"
else
    echo "Creating new A record"
    az network private-dns record-set a create \
        --resource-group "$DNS_RESOURCE_GROUP" \
        --zone-name "$DNS_ZONE_NAME" \
        --name "$DNS_RECORD_NAME" \
        --ttl 3600 \
        --output none
    check_status "A record creation"
    az network private-dns record-set a add-record \
        --resource-group "$DNS_RESOURCE_GROUP" \
        --zone-name "$DNS_ZONE_NAME" \
        --record-set-name "$DNS_RECORD_NAME" \
        --ipv4-address "$PRIVATE_ENDPOINT_IP" \
        --output none
    check_status "A record IP addition"
fi

# Switch back to the original subscription (optional, assumes your default sub is the storage one)
az account set --subscription "$(az account show --query id -o tsv)"
check_status "Switching back to original subscription"

# Step 3: Create a storage container for Terraform state
echo "Creating storage container: $CONTAINER_NAME"
az storage container create \
    --account-name "$STORAGE_ACCOUNT_NAME" \
    --name "$CONTAINER_NAME" \
    --public-access "off" \
    --auth-mode login \
    --output none
check_status "Storage container creation"

echo -e "${GREEN}Deployment completed successfully!${NC}"
echo "Storage Account: $STORAGE_ACCOUNT_NAME"
echo "Private Endpoint IP: $PRIVATE_ENDPOINT_IP"
echo "DNS A Record: $DNS_RECORD_NAME.$DNS_ZONE_NAME"
echo "Container: $CONTAINER_NAME"
