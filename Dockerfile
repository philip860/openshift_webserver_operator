# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - Path B (Publish REBASED UBI image)
#
# Fixes included:
# - Use newest ose-ansible-rhel9-operator digest as source
# - Keep UBI repo hygiene (avoid rhel-9-for-* repo mixing)
# - Avoid curl vs curl-minimal conflict (do NOT install curl)
# - Fix ansible-galaxy "bad interpreter" by ensuring /usr/local/bin/python3 exists
#   (install python3 in UBI and symlink /usr/local/bin/python3 -> /usr/bin/python3)
#
# Final stage publishes the UBI rebased filesystem.
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# -----------------------------------------------------------------------------
# Stage 0: official operator base (source of runtime bits)
# -----------------------------------------------------------------------------
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

# -----------------------------------------------------------------------------
# Stage 1: rebased (UBI9 filesystem we publish)
# -----------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi9/ubi:latest AS rebased

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# Repo hygiene: keep UBI repos only.
# If a build environment injects subscription-manager content, /etc/yum.repos.d/redhat.repo
# can appear and enable rhel-9-for-* repos. Remove it for Path B.
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# -----------------------------------------------------------------------------
# Enable UBI repos and install minimal tooling.
# NOTE: Do NOT install `curl` (UBI ships curl-minimal and curl conflicts).
# Also install python3 so we can provide /usr/local/bin/python3 for ansible-galaxy wrapper.
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates yum python3 python3-setuptools; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y repolist; \
    mkdir -p /usr/local/bin; \
    ln -sf /usr/bin/python3 /usr/local/bin/python3; \
    /usr/local/bin/python3 --version; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Patch UBI first
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Create expected dirs
RUN set -eux; \
    mkdir -p /opt/ansible /opt/ansible/.ansible /licenses /opt/ansible-operator

# Copy operator runtime bits from official base
# (ansible-galaxy wrapper is in /usr/local/bin; operator content in /opt)
COPY --from=operator-src /opt/ /opt/
COPY --from=operator-src /usr/local/bin/ /usr/local/bin/

# Sanity check: confirm wrapper sees python
RUN set -eux; \
    head -n1 /usr/local/bin/ansible-galaxy || true; \
    test -x /usr/local/bin/python3; \
    /usr/local/bin/ansible-galaxy --version || true

# Patch again after copying runtime bits
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Required certification labels
LABEL name="webserver-operator" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.35" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

# Licensing for HasLicense check
RUN mkdir -p /licenses \
 && printf "See project repository for license and terms.\n" > /licenses/NOTICE

# Install required Ansible collections (using the operator base wrapper)
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    /usr/local/bin/ansible-galaxy collection install -r /tmp/requirements.yml \
      --collections-path /opt/ansible/.ansible/collections; \
    chmod -R g+rwX /opt/ansible/.ansible; \
    rm -f /tmp/requirements.yml

# Copy operator content
COPY watches.yaml ./watches.yaml
COPY playbooks/ ./playbooks/
COPY roles/ ./roles/

# OpenShift-friendly permissions (arbitrary UID)
RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses

# RunAsNonRoot MUST be last
USER 1001
ENV ANSIBLE_USER_ID=1001

# -----------------------------------------------------------------------------
# Stage 2: final (publish the rebased UBI filesystem)
# -----------------------------------------------------------------------------
FROM rebased AS final
USER 1001
ENV ANSIBLE_USER_ID=1001
