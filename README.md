# WebServer Operator (Ansible-based, minimal)

This is a minimal OpenShift/Kubernetes operator implemented with the
`quay.io/operator-framework/ansible-operator` base image.

It manages a custom resource `WebServer` that lets you choose to deploy
either **NGINX** or **Apache HTTPD** with a Route exposed on OpenShift.

## Operator image location

The operator Deployment uses the image:

```yaml
# deploy/operator.yaml
spec:
  template:
    spec:
      containers:
        - name: ansible-operator
          image: "quay.io/philip860/webserver-operator:latest"
```

Whenever you push a new version of the operator image to Quay, make sure
this reference matches the tag you want to run.

## Layout

- `Dockerfile`               - Builds the operator image
- `watches.yaml`             - Tells ansible-operator which CR to watch and which playbook to run
- `playbooks/webserver.yml`  - Reconciliation logic (creates Deployment/Service/Route)
- `roles/`                   - Placeholder for Ansible roles
- `deploy/`                  - CRD, RBAC, Deployment, Namespace, and sample CR

## Build the operator image

You already have:

- `quay.io/philip860/webserver-operator:latest`

If you rebuild locally:

```bash
podman build -t quay.io/philip860/webserver-operator:latest .
podman push quay.io/philip860/webserver-operator:latest
```

## Install the operator on OpenShift

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

## Access from the OpenShift Web Console

With the CRD and operator installed, the operator is accessible via the
standard OpenShift UI for custom resources:

- Go to **Administration → CustomResourceDefinitions** and search for
  `WebServer` or `webservers.example.com`.
  - Click into the CRD and use **Create WebServer** to create instances
    via YAML or form view.
- Go to **Home → Search**, change **Resources** to `WebServer`, and you'll
  see your `WebServer` instances (e.g. `my-webserver`). Click on one to
  view/edit it.

That flow is how you manage this operator and its CRs via the GUI.

> Important:
> This manifest-based install does **not** create an entry under
> **Operators → Installed Operators** because that view is driven by the
> Operator Lifecycle Manager (OLM) and requires bundle/Subscription
> metadata.
>
> For home lab or non-OLM usage, installing via YAML like this is
> completely fine and the CRD + CRs remain fully accessible in the GUI.
>
> If you later want it to appear under **Installed Operators**, you'll
> package this as an OLM bundle (ClusterServiceVersion, CatalogSource,
> Subscription). The runtime image will still be
> `quay.io/philip860/webserver-operator:latest`.

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
