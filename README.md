# WebServer Operator (Production-Ready, OLM-Enabled, Ansible-Based)

This project is a production-style custom operator for OpenShift that:

- Uses **Ansible Operator** under the hood.
- Exposes a `WebServer` Custom Resource (CRD) with validation and
  OpenShift console form hints.
- Deploys **NGINX** or **Apache HTTPD** based on `spec.type`.
- Is packaged as an **OLM bundle**, so it appears under
  **Operators → Installed Operators** in the OpenShift web console.

## Images

- Operator (runtime) image:
  - `quay.io/philip860/webserver-operator:latest`
- Bundle image (for OLM):
  - `quay.io/philip860/webserver-operator-bundle:v1.0.0`

## Layout

- `Dockerfile` – builds the operator runtime image
- `watches.yaml` – connects the `WebServer` CRD to the Ansible playbook
- `playbooks/webserver.yml` – reconciliation logic (Deployment/Service/Route)
- `roles/webserver/` – placeholder Ansible role
- `config/` – CRD, RBAC, manager Deployment, samples (operator-sdk style)
- `deploy/` – namespace + OLM helper manifests (CatalogSource, Subscription)
- `bundle/` – pre-generated OLM bundle (CSV, CRD, annotations)
- `bundle/Dockerfile` – Dockerfile to build the bundle image
- `Makefile` – simple targets for building/pushing images

## 1. Build & Push Operator Image

If not already done:

```bash
export IMG=quay.io/philip860/webserver-operator:latest
podman build -t $IMG .
podman push $IMG
```

## 2. Build & Push Bundle Image

From the project root:

```bash
export BUNDLE_IMG=quay.io/philip860/webserver-operator-bundle:v1.0.0
podman build -f bundle/Dockerfile -t $BUNDLE_IMG bundle
podman push $BUNDLE_IMG
```

## 3. Install via OLM (shows in Installed Operators)

### Option A – YAML (CatalogSource + Subscription)

```bash
# Create target namespace for the operator runtime
oc apply -f deploy/namespace.yaml

# Register your bundle as a CatalogSource
oc apply -f deploy/olm/catalogsource.yaml

# Create the Subscription in the operator's namespace
oc apply -f deploy/olm/subscription.yaml
```

Then, in the OpenShift console:

- Go to **Operators → Installed Operators**
- You should see **WebServer Operator** in the `webserver-operator-system` namespace.
- Click into it to view its provided API: **WebServer (example.com/v1alpha1)**.

### Option B – operator-sdk helper (dev/test)

```bash
operator-sdk run bundle quay.io/philip860/webserver-operator-bundle:v1.0.0
```

This will create a CatalogSource & Subscription automatically.

## 4. Using the WebServer CRD from the Web Console

With the operator installed via OLM:

1. Go to **Operators → Installed Operators → WebServer Operator**.
2. Click the **WebServer** API under "Provided APIs".
3. Click **Create WebServer**.
4. The form will show:
   - **Web Server Type** (dropdown: `nginx` or `apache`)
   - **Replicas** (number)
   - **Container Port**
   - **Custom Image** (optional)
5. Submit the form.

The operator will:

- Create/update a `Deployment` with the selected web server.
- Expose it via a `Service` (port 80 → container port).
- Create an OpenShift `Route` (edge TLS).

## 5. CLI Example: Create WebServer via YAML

```bash
cat <<EOF | oc apply -f -
apiVersion: example.com/v1alpha1
kind: WebServer
metadata:
  name: my-webserver
  namespace: default
spec:
  type: nginx
  replicas: 2
  port: 8080
EOF
```

Check resources:

```bash
oc get webservers.example.com -A
oc get deploy,svc,route -n default
```

Switch from NGINX to Apache:

```bash
oc patch webserver my-webserver -n default --type=merge -p '{
  "spec": { "type": "apache" }
}'
```

The operator will reconcile and roll out Apache instead of NGINX while
preserving the Service/Route.
