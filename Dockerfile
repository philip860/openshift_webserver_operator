# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - Path B (Rebased UBI, Red Hat scan-friendly)
#
# GOALS
#   1) Publish a UBI-based image (ubi9/ubi) that passes Red Hat security scans.
#   2) Keep core operator functionality:
#        - run ansible-operator
#        - read watches.yaml from /opt/ansible-operator
#        - respect CSV/env vars (WATCH_NAMESPACE, OPERATOR_NAME, etc.)
#   3) Avoid repo mixing + curl conflicts:
#        - remove redhat.repo
#        - do NOT install curl (curl-minimal is already present in UBI)
#   4) Fix common runtime failures:
#        - arbitrary UID permissions (OpenShift SCC)
#        - kubernetes/openshift python libs needed by kubernetes.core modules
#        - ensure ansible output goes to pod logs
#
# Option A applied:
#   - DO NOT copy a non-existent /usr/local/bin/entrypoint from operator-src
#   - Create our OWN tiny entrypoint shim that execs ansible-operator
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# -----------------------------------------------------------------------------
# Stage 0: Source of ansible-operator binary + operator runtime bits (/opt)
# -----------------------------------------------------------------------------
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

# -----------------------------------------------------------------------------
# Stage 1: Build the rebased filesystem we will publish (UBI 9)
# -----------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0

# Where the ansible-operator base expects operator content
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# 1) Repo hygiene: keep ONLY UBI repos
#    (avoid rhel-9-for-* repo mixing and scan noise)
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# -----------------------------------------------------------------------------
# 2) Install minimal tooling INCLUDING ansible-core so ansible-galaxy works natively
#    NOTE: Do NOT install curl (curl-minimal already present and conflicts)
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates yum \
      python3 python3-setuptools python3-pip \
      ansible-core; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y repolist; \
    python3 --version; \
    ansible --version; \
    ansible-galaxy --version; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# 3) Patch UBI packages (security errata)
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# 4) Create expected dirs + OpenShift-friendly HOME/Ansible dirs
#    - OpenShift runs containers with arbitrary UID in many cases.
#    - We keep everything writable by group 0.
# -----------------------------------------------------------------------------
ENV HOME=/opt/ansible \
    ANSIBLE_LOCAL_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_REMOTE_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_COLLECTIONS_PATHS=/opt/ansible/.ansible/collections:/usr/share/ansible/collections \
    ANSIBLE_ROLES_PATH=/opt/ansible/.ansible/roles:/etc/ansible/roles:/usr/share/ansible/roles \
    # Log/console behavior:
    ANSIBLE_STDOUT_CALLBACK=default \
    ANSIBLE_LOAD_CALLBACK_PLUGINS=1 \
    ANSIBLE_FORCE_COLOR=0 \
    PYTHONUNBUFFERED=1

RUN set -eux; \
    mkdir -p \
      /opt/ansible/.ansible/tmp \
      /opt/ansible/.ansible/collections \
      /opt/ansible/.ansible/roles \
      /licenses \
      ${ANSIBLE_OPERATOR_DIR}; \
    chgrp -R 0 /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR}; \
    chmod -R g+rwX /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# 5) Copy operator runtime bits from official OpenShift operator base
#    IMPORTANT: keep to /opt only (your prior scan-friendly approach)
# -----------------------------------------------------------------------------
COPY --from=operator-src /opt/ /opt/

# -----------------------------------------------------------------------------
# 6) Copy ansible-operator binary from operator-src
#    Different builds may place it in /usr/local/bin or /usr/bin.
#    We detect and copy the right one *without* guessing.
# -----------------------------------------------------------------------------
RUN set -eux; \
    if [ -x /usr/local/bin/ansible-operator ]; then \
      echo "ansible-operator already exists in this image (unexpected)"; \
    fi

# We copy both possible locations in two COPY lines with guards via build args?
# Dockerfile COPY cannot be conditional; so we use a safe approach:
# - copy the whole /usr/local/bin and /usr/bin from operator-src into a temp dir,
# - then install only the ansible-operator binary if found.
COPY --from=operator-src /usr/local/bin/ /tmp/operator-src/usr-local-bin/
COPY --from=operator-src /usr/bin/ /tmp/operator-src/usr-bin/

RUN set -eux; \
    if [ -x /tmp/operator-src/usr-local-bin/ansible-operator ]; then \
      install -m 0755 /tmp/operator-src/usr-local-bin/ansible-operator /usr/local/bin/ansible-operator; \
    elif [ -x /tmp/operator-src/usr-bin/ansible-operator ]; then \
      install -m 0755 /tmp/operator-src/usr-bin/ansible-operator /usr/local/bin/ansible-operator; \
    else \
      echo "ERROR: ansible-operator not found in operator-src image"; \
      ls -la /tmp/operator-src/usr-local-bin || true; \
      ls -la /tmp/operator-src/usr-bin || true; \
      exit 1; \
    fi; \
    rm -rf /tmp/operator-src; \
    /usr/local/bin/ansible-operator version

# -----------------------------------------------------------------------------
# 7) Install Python libraries required by kubernetes.core modules
#    Fixes: "Failed to import the required Python library (kubernetes)"
#    Try RPMs first; if not available in UBI repos, fall back to pip.
# -----------------------------------------------------------------------------
RUN set -eux; \
    if dnf -y install python3-kubernetes python3-openshift; then \
      echo "Installed kubernetes/openshift via RPMs"; \
    else \
      echo "RPMs not available; installing via pip"; \
      python3 -m pip install --no-cache-dir \
        "kubernetes>=24.2.0" \
        "openshift>=0.13.2"; \
    fi; \
    python3 -c "import kubernetes, openshift; print('python deps OK')" ; \
    dnf -y clean all || true; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# 8) Required certification labels + NOTICE
# -----------------------------------------------------------------------------
LABEL name="webserver-operator" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.35" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

RUN set -eux; \
    mkdir -p /licenses; \
    printf "See project repository for license and terms.\n" > /licenses/NOTICE

# -----------------------------------------------------------------------------
# 9) Operator content + collections
# -----------------------------------------------------------------------------
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    if [ -s /tmp/requirements.yml ]; then \
      ansible-galaxy collection install -r /tmp/requirements.yml \
        --collections-path /opt/ansible/.ansible/collections; \
    fi; \
    rm -f /tmp/requirements.yml; \
    chgrp -R 0 /opt/ansible; \
    chmod -R g+rwX /opt/ansible

COPY watches.yaml ${ANSIBLE_OPERATOR_DIR}/watches.yaml
COPY playbooks/ ${ANSIBLE_OPERATOR_DIR}/playbooks/
COPY roles/ ${ANSIBLE_OPERATOR_DIR}/roles/

# Ensure operator dir readable/writable for random UID (group 0)
RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses

# -----------------------------------------------------------------------------
# 10) Option A: Provide our own tiny entrypoint shim
#     This is what makes the container *actually run the operator*.
# -----------------------------------------------------------------------------
RUN set -eux; \
    cat > /usr/local/bin/entrypoint <<'EOF'\n\
#!/bin/sh\n\
set -eu\n\
# Run the operator using the watches file packaged into the image.\n\
# The operator will still consume the standard env vars injected by the CSV:\n\
#   WATCH_NAMESPACE, POD_NAME, OPERATOR_NAME (deprecated), etc.\n\
exec /usr/local/bin/ansible-operator run --watches-file=/opt/ansible-operator/watches.yaml\n\
EOF\n\
    chmod +x /usr/local/bin/entrypoint

# -----------------------------------------------------------------------------
# 11) Drop to non-root for OpenShift
# -----------------------------------------------------------------------------
USER 1001
ENV ANSIBLE_USER_ID=1001

ENTRYPOINT ["/usr/local/bin/entrypoint"]
