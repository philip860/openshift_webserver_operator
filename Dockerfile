# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - Path B (Publish REBASED UBI image)
# Fixes curl-minimal vs curl conflict + prevents RHEL subscription repos mixing
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
# IMPORTANT REPO HYGIENE
# - UBI images can have /etc/yum.repos.d/redhat.repo (subscription-manager in container mode)
# - That repo can pull rhel-9-for-* repos and cause mixing/conflicts with UBI repos
# - For Path B, we want UBI repos only, so remove redhat.repo up-front.
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# -----------------------------------------------------------------------------
# Enable UBI repos deterministically and install only what we need.
# NOTE: DO NOT install `curl` (UBI ships curl-minimal; installing curl conflicts).
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates yum; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y repolist; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Patch UBI FIRST
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Create expected dirs
RUN set -eux; \
    mkdir -p /opt/ansible /opt/ansible/.ansible /licenses /opt/ansible-operator /tmp/patching

# Copy ONLY operator runtime bits from the official operator base
COPY --from=operator-src /usr/local/bin/ /usr/local/bin/
COPY --from=operator-src /opt/ /opt/

# Patch AGAIN after copying /opt (to update any newly introduced RPM content)
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# (Optional) Offline/local RPM patching (./patching/*.rpm)
COPY patching/ /tmp/patching/
RUN set -eux; \
    echo "=== Offline/local patching (if RPMs present) ==="; \
    ls -lah /tmp/patching || true; \
    rpms="$(ls -1 /tmp/patching/*.rpm 2>/dev/null || true)"; \
    if [ -n "${rpms}" ]; then \
      echo "Installing local RPMs:"; \
      echo "${rpms}" | sed 's/^/  - /'; \
      yum -y localinstall /tmp/patching/*.rpm; \
    else \
      echo "No RPMs found in /tmp/patching (skipping yum localinstall)."; \
    fi; \
    yum -y clean all; \
    rm -rf /var/cache/dnf /var/cache/yum /tmp/patching /var/tmp/* /tmp/*

# Verification (debug; can remove later)
RUN set -eux; \
    echo "=== Enabled repos (final) ==="; \
    dnf -y repolist || true; \
    echo "=== RPM versions (rebased final) ==="; \
    rpm -q curl-minimal curl pam libxml2 libarchive expat sqlite-libs krb5-libs 2>/dev/null || true

# Required certification labels (edit as needed)
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

# Install required Ansible collections
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    ansible-galaxy collection install -r /tmp/requirements.yml \
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
