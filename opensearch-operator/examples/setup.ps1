
####AKS Deployment

$rg = "d-rgr-lmspoc-01"
$location = "westeurope"
$osCustomFile = './linuxosconfig.json'
$admingroupIds = @("ef2e3735-0ae9-4b51-a548-611a75260ad3")
$vmSKu = 'Standard_D4s_v5'

az account set --subscription d-sub-dev-miru-sponsored-2223

#Create vnet
$vnet = az network vnet create --address-prefixes 10.1.0.0/16 --name aksvnet --resource-group $rg --subnet-name aksnodesubnet --subnet-prefixes 10.1.0.0/23 --location $location | convertfrom-json

#Create ACR
$acr = az acr create --name dacrscwylms01 --resource-group $rg --sku Standard --location $location | Convertfrom-Json

#Create aks cluster
az aks create --resource-group $rg --name "d-aks-lmspoc-01" --location $location --enable-aad --enable-azure-rbac --api-server-authorized-ip-ranges 194.230.190.97/32 --node-resource-group "$($rg)-nodes" --node-vm-size $vmSKu --node-osdisk-size 128 --node-count 3 --network-plugin azure --linux-os-config $osCustomFile --aad-admin-group-object-ids $admingroupIds --vnet-subnet-id  $vnet.newVNet.subnets[0].id --generate-ssh-keys

#attach ACR to cluster
az aks update -n d-aks-lmspoc-01 -g $rg --attach-acr $acr.id


#Helm / ACR Config
CD C:\Repos\Github\Opster\opensearch-k8s-operator\charts\opensearch-operator
helm package .
$userName = "00000000-0000-0000-0000-000000000000"
$password = az acr login -n dacrscwylms01 --expose-token --output tsv --query accessToken
$env:HELM_EXPERIMENTAL_OCI = 1
helm registry login dacrscwylms01.azurecr.io --username $username --password $password
helm push .\opensearch-operator-2.1.0.tgz oci://dacrscwylms01.azurecr.io/helm

#Deploy Opensearch Operator from ACR Helm
kubectl create namespace opensearch
helm install opensearch-operator oci://dacrscwylms01.azurecr.io/helm/opensearch-operator --version 2.1.0 -n opensearch


#Deploy OpenSearch Cluster
kubectl apply -f C:\Repos\Github\Opster\opensearch-k8s-operator\opensearch-operator\examples\opensearch-cluster-lab.yaml


#Deploy nginx ingress controller
$Namespace = 'ingress-basic'
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx `
  --create-namespace `
  --namespace $Namespace `
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz


#Configure TLS for nginx
$DnsLabel = "scwydemo" 
$Namespace = "ingress-basic"
$staticIp = az network public-ip create --resource-group d-rgr-lmspoc-01-nodes2 --name d-pip-aksingress-01 --sku Standard --allocation-method static --query publicIp.ipAddress -o tsv
helm upgrade ingress-nginx ingress-nginx/ingress-nginx  --namespace $Namespace --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"=$DnsLabel --set controller.service.loadBalancerIP=$StaticIp


#Import Cert Manager Images into ACR
$REGISTRY_NAME="dacrscwylms01"
$CERT_MANAGER_REGISTRY="quay.io"
$CERT_MANAGER_TAG="v1.8.0"
$CERT_MANAGER_IMAGE_CONTROLLER="jetstack/cert-manager-controller"
$CERT_MANAGER_IMAGE_WEBHOOK="jetstack/cert-manager-webhook"
$CERT_MANAGER_IMAGE_CAINJECTOR="jetstack/cert-manager-cainjector"

az acr import --name $REGISTRY_NAME --source "$($CERT_MANAGER_REGISTRY)/$($CERT_MANAGER_IMAGE_CONTROLLER):$($CERT_MANAGER_TAG)" --image "$($CERT_MANAGER_IMAGE_CONTROLLER):$($CERT_MANAGER_TAG)"
az acr import --name $REGISTRY_NAME --source "$($CERT_MANAGER_REGISTRY)/$($CERT_MANAGER_IMAGE_WEBHOOK):$($CERT_MANAGER_TAG)" --image "$($CERT_MANAGER_IMAGE_WEBHOOK):$($CERT_MANAGER_TAG)"
az acr import --name $REGISTRY_NAME --source "$($CERT_MANAGER_REGISTRY)/$($CERT_MANAGER_IMAGE_CAINJECTOR):$($CERT_MANAGER_TAG)" --image "$($CERT_MANAGER_IMAGE_CAINJECTOR):$($CERT_MANAGER_TAG)"

#Deploy Cert Manager
# Set variable for ACR location to use for pulling images
$ACR_URL="dacrscwylms01.azurecr.io"

# Label the ingress-basic namespace to disable resource validation
kubectl label namespace ingress-basic cert-manager.io/disable-validation=true

# Add the Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io

# Update your local Helm chart repository cache
helm repo update

# Install the cert-manager Helm chart
helm install cert-manager jetstack/cert-manager `
  --namespace ingress-basic `
  --version $CERT_MANAGER_TAG `
  --set installCRDs=true `
  --set nodeSelector."kubernetes\.io/os"=linux `
  --set image.repository="$($ACR_URL)/$($CERT_MANAGER_IMAGE_CONTROLLER)" `
  --set image.tag=$CERT_MANAGER_TAG `
  --set webhook.image.repository="$($ACR_URL)/$($CERT_MANAGER_IMAGE_WEBHOOK)" `
  --set webhook.image.tag=$CERT_MANAGER_TAG `
  --set cainjector.image.repository="$($ACR_URL)/$($CERT_MANAGER_IMAGE_CAINJECTOR)" `
  --set cainjector.image.tag=$CERT_MANAGER_TAG