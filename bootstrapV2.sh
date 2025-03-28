#!/bin/bash

# Exit on any error
set -e

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

# Function to display usage
usage() {
    echo "Usage: $0 [-f <params_file>] [-r <resource_group>] [-l <location>] [-s <storage_account_name>] [-v <vnet_name>] [-n <subnet_name>] [-p <private_endpoint_name>] [-d <dns_subscription_id>] [-g <dns_resource_group>] [-z <dns_zone_name>] [-c <container_name>]"
    echo "  -f: Path to parameters file (e.g., params_dev.json)"
    echo "  Required parameters: resourceGroup, location, storageAccountName, vnetName, subnetName, privateEndpointName, dnsSubscriptionId, dnsResourceGroup, dnsZoneName, containerName"
    echo "  Example with file: $0 -f params_dev.json"
    echo "  Example with args: $0 -r my-rg -l eastus -s mystorage123 -v my-vnet -n my-subnet -p mystorage123-pe -d <dns-sub-id> -g dns-rg -z privatelink.blob.core.windows.net -c tfstate"
    exit 1
}

# Parse command-line arguments
while getopts "f:r:l:s:v:n:p:d:g:z:c:h" opt; do
    case $opt in
        f) PARAMS_FILE="$OPTARG";;
        r) RESOURCE_GROUP="$OPTARG";;
        l) LOCATION="$OPTARG";;
        s) STORAGE_ACCOUNT_NAME="$OPTARG";;
        v) VNET_NAME="$OPTARG";;
        n) SUBNET_NAME="$OPTARG";;
        p) PRIVATE_ENDPOINT_NAME="$OPTARG";;
        d) DNS_SUBSCRIPTION_ID="$OPTARG";;
        g) DNS_RESOURCE_GROUP="$OPTARG";;
        z) DNS_ZONE_NAME="$OPTARG";;
        c) CONTAINER_NAME="$OPTARG";;
        h) usage;;
        ?) usage;;
    esac
done

# If a parameters file is provided, load values from it (JSON format)
if [ -n "$PARAMS_FILE" ]; then
    if [ ! -f "$PARAMS_FILE" ]; then
        echo -e "${RED}Error: Parameters file '$PARAMS_FILE' not found${NC}"
        exit 1
    fi
    # Use jq to parse JSON (requires jq installed)
    RESOURCE_GROUP=$(jq -r '.resourceGroup // empty' "$PARAMS_FILE")
    LOCATION=$(jq -r '.location // empty' "$PARAMS_FILE")
    STORAGE_ACCOUNT_NAME=$(jq -r '.storageAccountName // empty' "$PARAMS_FILE")
    VNET_NAME=$(jq -r '.vnetName // empty' "$PARAMS_FILE")
    SUBNET_NAME=$(jq -r '.subnetName // empty' "$PARAMS_FILE")
    PRIVATE_ENDPOINT_NAME=$(jq -r '.privateEndpointName // empty' "$PARAMS_FILE")
    DNS_SUBSCRIPTION_ID=$(jq -r '.dnsSubscriptionId // empty' "$PARAMS_FILE")
    DNS_RESOURCE_GROUP=$(jq -r '.dnsResourceGroup // empty' "$PARAMS_FILE")
    DNS_ZONE_NAME=$(jq -r '.dnsZoneName // empty' "$PARAMS_FILE")
    CONTAINER_NAME=$(jq -r '.containerName // empty' "$PARAMS_FILE")
fi

# Validate all required parameters are set
for var in RESOURCE_GROUP LOCATION STORAGE_ACCOUNT_NAME VNET_NAME SUBNET_NAME PRIVATE_ENDPOINT_NAME DNS_SUBSCRIPTION_ID DNS_RESOURCE_GROUP DNS_ZONE_NAME CONTAINER_NAME; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: Missing required parameter: $var${NC}"
        usage
    fi
done

# Derived variables
DNS_RECORD_NAME="${STORAGE_ACCOUNT_NAME}"

echo -e "${GREEN}Starting deployment with the following settings:${NC}"
echo "Resource Group: $RESOURCE_GROUP"
echo "Location: $LOCATION"
echo "Storage Account: $STORAGE_ACCOUNT_NAME"
echo "VNet: $VNET_NAME"
echo "Subnet: $SUBNET_NAME"
echo "Private Endpoint: $PRIVATE_ENDPOINT_NAME"
echo "DNS Subscription: $DNS_SUBSCRIPTION_ID"
echo "DNS Resource Group: $DNS_RESOURCE_GROUP"
echo "DNS Zone: $DNS_ZONE_NAME"
echo "Container: $CONTAINER_NAME"

# Step 1: Deploy the storage account with private endpoint
echo "Creating storage account: $STORAGE_ACCOUNT_NAME"
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
