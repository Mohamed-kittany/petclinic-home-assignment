#!/bin/bash
set -e

# === Configuration ===
RELEASE_NAME="petclinic"
CHART_DIR="spring-petclinic"
NAMESPACE="default"
DOMAIN="petclinic.local"
SEALED_SECRET_NAME="db-secrets"
RANDOM_PASSWORD=$(openssl rand -base64 12)

# === Functions ===
function validate_prerequisites() {
  for cmd in helm minikube kubectl kubeseal openssl; do
    if ! command -v $cmd &>/dev/null; then
      echo "❌ Required command '$cmd' not found. Please install it."
      exit 1
    fi
  done

  if [ ! -d "$CHART_DIR" ]; then
    echo "❌ Helm chart directory '$CHART_DIR' not found. Please check CHART_DIR."
    exit 1
  fi
}

function ensure_minikube_running() {
  if ! minikube status | grep -q "Running"; then
    echo "🚀 Starting Minikube with more resources..."
    minikube start --cpus=4 --memory=4096
  else
    echo "✅ Minikube is already running."
  fi
}

function enable_ingress() {
  echo "🌐 Enabling ingress controller via Minikube addon..."

  if ! minikube addons list | grep ingress | grep -q enabled; then
    minikube addons enable ingress
  else
    echo "✅ Ingress addon already enabled."
  fi

  echo "⏳ Waiting for ingress controller pod to be ready..."
  ATTEMPTS=0
  until kubectl get pods -n ingress-nginx | grep controller | grep -q "Running"; do
    sleep 5
    ((ATTEMPTS++))
    if [ $ATTEMPTS -gt 18 ]; then
      echo "❌ Ingress controller failed to become ready after 90 seconds."
      kubectl get pods -n ingress-nginx
      exit 1
    fi
    echo "⌛ Waiting for ingress-nginx... ($ATTEMPTS/18)"
  done

  echo "✅ Ingress controller is ready."
}

function update_hosts_file() {
  MINIKUBE_IP=$(minikube ip)

  if grep -q "$DOMAIN" /etc/hosts; then
    CURRENT_ENTRY=$(grep "$DOMAIN" /etc/hosts)
    echo "✅ Domain entry already exists in /etc/hosts:"
    echo "$CURRENT_ENTRY"
  else
    echo "💡 Please run this command to access your app:"
    echo "echo \"$MINIKUBE_IP $DOMAIN\" | sudo tee -a /etc/hosts"
  fi
}


function install_sealed_secrets() {
  echo "🔐 Installing Sealed Secrets via Helm..."
  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
  helm repo update

  helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
    --namespace kube-system \
    --create-namespace \
    --wait

  echo "⏳ Waiting for sealed-secrets controller to be ready..."
  kubectl rollout status deployment sealed-secrets -n kube-system --timeout=90s
}

function generate_and_apply_sealed_secret() {
  echo "🔑 Generating PostgreSQL-style secret with random password..."

  cat <<EOF > raw-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: $SEALED_SECRET_NAME
  namespace: $NAMESPACE
type: servicebinding.io/postgresql
stringData:
  type: "postgresql"
  provider: "postgresql"
  host: "demo-db"
  port: "5432"
  database: "petclinic"
  username: "user"
  password: "$RANDOM_PASSWORD"
EOF

  echo "🔐 Sealing the secret..."
  kubeseal \
    --controller-name=sealed-secrets \
    --controller-namespace=kube-system \
    --format yaml < raw-secret.yaml > sealed-secret.yaml

  echo "📦 Applying sealed secret..."
  kubectl apply -f sealed-secret.yaml

  echo "💾 Saving DB credentials to db-password.txt..."
  cat <<EOF > db-password.txt
# PostgreSQL Credentials for petclinic
host=demo-db
port=5432
database=petclinic
username=user
password=$RANDOM_PASSWORD
EOF

  echo "✅ DB credentials saved to db-password.txt"

  echo "🚮 Cleaning up raw secret..."
  rm raw-secret.yaml
}


function deploy_helm_chart() {
  echo "📦 Deploying Helm chart..."
  helm upgrade --install "$RELEASE_NAME" "$CHART_DIR" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --wait
}

# === Script Execution ===
echo "🔍 Validating prerequisites..."
validate_prerequisites

echo "🧱 Ensuring Minikube is running..."
ensure_minikube_running

enable_ingress

echo "🔐 Installing Sealed Secrets..."
install_sealed_secrets

echo "🔏 Creating and applying sealed secret..."
generate_and_apply_sealed_secret

echo "🚢 Deploying Helm chart..."
deploy_helm_chart

echo "✅ Deployment complete!"

echo
echo "📇 Updating /etc/hosts..."
update_hosts_file

echo 
echo "🌍 Visit your app at: http://$DOMAIN"