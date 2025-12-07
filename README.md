# WebServer Operator (Ansible-based, minimal)

This is a minimal OpenShift/Kubernetes operator implemented with the
`quay.io/operator-framework/ansible-operator` base image.

It manages a custom resource `WebServer` that lets you choose to deploy
either **NGINX** or **Apache HTTPD** with a Route exposed on OpenShift.

## Layout

- `Dockerfile`               - Builds the operator image
- `watches.yaml`             - Tells ansible-operator which CR to watch and which playbook to run
- `playbooks/webserver.yml`  - Reconciliation logic (creates Deployment/Service/Route)
- `roles/`                   - Placeholder for Ansible roles (not required for this minimal example)
- `deploy/`                  - CRD, RBAC, Deployment, Namespace, and sample CR

## Build the operator image

```bash
podman build -t quay.io/<your-namespace>/webserver-operator:latest .
podman push quay.io/<your-namespace>/webserver-operator:latest
```

Then edit `deploy/operator.yaml` and replace:

```yaml
image: "quay.io/CHANGE_ME/webserver-operator:latest"
```

with your actual image reference.

## Install the operator

```bash
# Create namespace for the operator
oc apply -f deploy/namespace.yaml

# Install CRD
oc apply -f deploy/crd-webservers.yaml

# Install RBAC + operator Deployment
oc apply -f deploy/service_account.yaml
oc apply -f deploy/role.yaml
oc apply -f deploy/role_binding.yaml
oc apply -f deploy/operator.yaml
```

Wait for the operator pod to be running:

```bash
oc get pods -n webserver-operator-system
```

## Create a WebServer instance

```bash
oc apply -f deploy/sample_webserver.yaml
```

This will create:

- a Deployment running either NGINX or Apache (based on `spec.type`)
- a Service exposing port 80
- a Route (edge-terminated TLS) pointing at the Service

Check resources:

```bash
oc get webservers.example.com
oc get deploy,svc,route
```

To switch the running web server type:

```bash
oc patch webserver my-webserver -n default --type=merge -p '{
  "spec": { "type": "apache" }
}'
```

The operator will reconcile and roll out Apache instead of NGINX while
preserving the Service/Route.
