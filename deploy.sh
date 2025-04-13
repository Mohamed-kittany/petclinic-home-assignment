#!/bin/bash
set -e

# === Configuration ===
RELEASE_NAME="petclinic"
CHART_DIR="spring-petclinic"
NAMESPACE="default"
DOMAIN="petclinic.local"
SEALED_SECRET_NAME="db-secrets"
DB_USERNAME="user"
DB_NAME="petclinic"
DB_HOST="demo-db"
DB_PORT="5432"
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
    echo "🚀 Starting Minikubee..."
    minikube start --cpus=4 --memory=4096
  else
    echo "✅ Minikube is already running."
  fi
}

function enable_ingress() {
  echo "📡 Waiting for kube-root-ca.crt ConfigMap to exist..."

  # Wait until kube-root-ca.crt configmap is created
  until kubectl get configmap kube-root-ca.crt -n kube-system &>/dev/null; do
    sleep 2
    echo "⏳ Waiting for kube-root-ca.crt..."
  done

  echo "🌐 (Re)Enabling ingress controller via Minikube addon..."

  minikube addons disable ingress || true
  sleep 3
  minikube addons enable ingress

  echo "⏳ Waiting for ingress-nginx controller to be ready..."
  kubectl rollout status deployment ingress-nginx-controller -n ingress-nginx --timeout=180s

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
  database: "$DB_NAME"
  username: "$DB_USERNAME"
  password: "$RANDOM_PASSWORD"
  type: "postgresql"
  provider: "postgresql"
  host: "$DB_HOST"
  port: "$DB_PORT"
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
database: "$DB_NAME"
username: "$DB_USERNAME"
password: "$RANDOM_PASSWORD"
EOF

  echo "✅ DB credentials saved to db-password.txt"

  echo "🚮 Cleaning up raw secret..."
  rm raw-secret.yaml
}


function deploy_helm_chart() {
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

echo "📦 Deploying Helm chart..."
deploy_helm_chart

echo "✅ Deployment complete!"

echo
echo "📇 Updating /etc/hosts..."
update_hosts_file

echo 
echo "🌍 Visit your app at: http://$DOMAIN"