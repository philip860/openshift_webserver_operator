# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - Path B (Publish REBASED UBI image)
#
# Goal:
#   - Pass Red Hat security scans (publish UBI filesystem)
#   - Still behave like the official ansible-operator base at runtime
#
# Key point:
#   - UBI base DOES NOT include the operator ENTRYPOINT/CMD
#   - Therefore we must copy the operator runtime binaries + set ENTRYPOINT/CMD
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# Stage 0: official operator base (source of runtime bits we want)
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

# Stage 1: rebased UBI filesystem we publish
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0

# The directory ansible-operator expects
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# Repo hygiene: keep UBI repos only
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# -----------------------------------------------------------------------------
# Install tooling + ansible-core for ansible-galaxy
# NOTE: Do NOT install curl (curl-minimal is present and conflicts)
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
    ansible-galaxy --version; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# Patch UBI first (security errata)
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# Create expected dirs + OpenShift arbitrary UID friendly HOME
# -----------------------------------------------------------------------------
ENV HOME=/opt/ansible \
    ANSIBLE_LOCAL_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_REMOTE_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_COLLECTIONS_PATHS=/opt/ansible/.ansible/collections:/usr/share/ansible/collections \
    ANSIBLE_ROLES_PATH=/opt/ansible/.ansible/roles:/etc/ansible/roles:/usr/share/ansible/roles \
    ANSIBLE_STDOUT_CALLBACK=default \
    ANSIBLE_LOAD_CALLBACK_PLUGINS=1 \
    ANSIBLE_FORCE_COLOR=0 \
    PYTHONUNBUFFERED=1

RUN set -eux; \
    mkdir -p /opt/ansible/.ansible/tmp /opt/ansible/.ansible/collections /opt/ansible/.ansible/roles \
             /licenses ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# Copy operator runtime bits from official base
#
# CRITICAL:
#   /opt/ alone is NOT enough. The container must start ansible-operator.
#   These are typically located in /usr/local/bin in the operator base image.
# -----------------------------------------------------------------------------
COPY --from=operator-src /opt/ /opt/
COPY --from=operator-src /usr/local/bin/ /usr/local/bin/

# -----------------------------------------------------------------------------
# Python deps required by kubernetes.core modules
#
# First try RPMs (preferred). If not available, fall back to pip.
# -----------------------------------------------------------------------------
RUN set -eux; \
    if dnf -y install python3-kubernetes python3-openshift; then \
      echo "Installed kubernetes deps via RPM"; \
    else \
      echo "RPMs not available; installing via pip"; \
      python3 -m pip install --no-cache-dir "kubernetes>=24.2.0" "openshift>=0.13.2"; \
    fi; \
    dnf -y clean all || true; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# Required certification labels
# -----------------------------------------------------------------------------
LABEL name="webserver-operator" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.35" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

# Licensing
RUN set -eux; \
    mkdir -p /licenses; \
    printf "See project repository for license and terms.\n" > /licenses/NOTICE

# -----------------------------------------------------------------------------
# Install required Ansible collections
# -----------------------------------------------------------------------------
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    if [ -s /tmp/requirements.yml ]; then \
      ansible-galaxy collection install -r /tmp/requirements.yml \
        --collections-path /opt/ansible/.ansible/collections; \
    fi; \
    rm -f /tmp/requirements.yml

# -----------------------------------------------------------------------------
# Copy operator content (watches + playbooks + roles)
# -----------------------------------------------------------------------------
COPY watches.yaml ${ANSIBLE_OPERATOR_DIR}/watches.yaml
COPY playbooks/   ${ANSIBLE_OPERATOR_DIR}/playbooks/
COPY roles/       ${ANSIBLE_OPERATOR_DIR}/roles/

# -----------------------------------------------------------------------------
# OpenShift-friendly permissions (arbitrary UID)
# -----------------------------------------------------------------------------
RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /usr/local/bin; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /usr/local/bin

USER 1001
ENV ANSIBLE_USER_ID=1001

# -----------------------------------------------------------------------------
# IMPORTANT: Make the rebased image behave like the operator base at runtime
# -----------------------------------------------------------------------------
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["ansible-operator", "run", "--watches-file=/opt/ansible-operator/watches.yaml"]
