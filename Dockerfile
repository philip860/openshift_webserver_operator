# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - CVE-aware builds + RunAsNonRoot safe
# Updated to newest ose-ansible-rhel9-operator digest (Created 2026-01-12)
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Stage 0: official operator base (source of runtime bits for optional rebased)
# -----------------------------------------------------------------------------
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88 AS operator-src

# -----------------------------------------------------------------------------
# Stage 1: basepatched (patch in-place on the official base)
# This is the image you actually publish (Stage 3).
# -----------------------------------------------------------------------------
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88 AS basepatched

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# (0) Sanity: show base OS + enabled repos (non-fatal)
RUN set -eux; \
    cat /etc/redhat-release || true; \
    dnf -y repolist || true

# (A) Online patching (best-effort)
RUN set -eux; \
    dnf -y makecache --refresh || true; \
    dnf -y update --refresh || true; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# (B) Targeted advisory attempts (best-effort)
# NOTE: Advisories must exist in the enabled repo set or these will no-op.
RUN set -eux; \
    dnf -y makecache --refresh || true; \
    dnf -y install dnf-plugins-core || true; \
    echo "=== Available RHSAs (debug) ==="; \
    dnf -y updateinfo list --available | sed -n '1,200p' || true; \
    echo "=== Attempting targeted RHSAs (best-effort) ==="; \
    dnf -y update --advisory=RHSA-2025:2678  || true; \
    dnf -y update --advisory=RHSA-2025:10399 || true; \
    dnf -y update --advisory=RHSA-2024:9547  || true; \
    dnf -y update --advisory=RHSA-2024:10232 || true; \
    dnf -y update --advisory=RHSA-2025:14142 || true; \
    dnf -y update --advisory=RHSA-2025:12036 || true; \
    dnf -y update --advisory=RHSA-2025:22033 || true; \
    dnf -y update --advisory=RHSA-2025:11580 || true; \
    dnf -y update --advisory=RHSA-2025:13312 || true; \
    dnf -y update --refresh || true; \
    dnf -y remove dnf-plugins-core || true; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# # (C) Offline/local RPM patching (./patching/*.rpm)
# COPY patching/ /tmp/patching/
# RUN set -eux; \
#     echo "=== Offline/local patching (if RPMs present) ==="; \
#     ls -lah /tmp/patching || true; \
#     rpms="$(ls -1 /tmp/patching/*.rpm 2>/dev/null || true)"; \
#     if [ -n "${rpms}" ]; then \
#       echo "Installing local RPMs:"; \
#       echo "${rpms}" | sed 's/^/  - /'; \
#       yum -y localinstall /tmp/patching/*.rpm; \
#     else \
#       echo "No RPMs found in /tmp/patching (skipping yum localinstall)."; \
#     fi; \
#     yum -y clean all; \
#     rm -rf /var/cache/dnf /var/cache/yum /tmp/patching /var/tmp/* /tmp/*

# Post-patch verification (non-fatal)
RUN set -eux; \
    echo "=== RPM versions after patching ==="; \
    rpm -q pam libxml2 sqlite-libs krb5-libs python3 python3-libs libarchive expat 2>/dev/null || true

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

# RunAsNonRoot MUST be the last USER in the final image config
USER 1001
ENV ANSIBLE_USER_ID=1001

# -----------------------------------------------------------------------------
# Stage 2: rebased (OPTIONAL)
# If you want to *publish* this instead, change Stage 3 to "FROM rebased".
# -----------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi9/ubi:latest AS rebased

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# Enable UBI repos explicitly (baseos/appstream/crb) + patch
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates curl yum; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y makecache --refresh; \
    dnf -y update --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Create expected dirs
RUN set -eux; \
    mkdir -p /opt/ansible /opt/ansible/.ansible /licenses /opt/ansible-operator /tmp/patching

# Copy ONLY operator runtime bits from the official operator base
COPY --from=operator-src /usr/local/bin/ /usr/local/bin/
COPY --from=operator-src /opt/ /opt/

# Optional offline/local RPM patching
COPY patching/ /tmp/patching/
RUN set -eux; \
    rpms="$(ls -1 /tmp/patching/*.rpm 2>/dev/null || true)"; \
    if [ -n "${rpms}" ]; then \
      yum -y localinstall /tmp/patching/*.rpm; \
    fi; \
    yum -y clean all; \
    rm -rf /var/cache/dnf /var/cache/yum /tmp/patching /var/tmp/* /tmp/*

# Verification
RUN set -eux; \
    echo "=== RPM versions after rebasing ==="; \
    rpm -q pam libxml2 2>/dev/null || true

# Labels + license
LABEL name="webserver-operator-dev" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.35" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

RUN mkdir -p /licenses \
 && printf "See project repository for license and terms.\n" > /licenses/NOTICE

# Collections
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    ansible-galaxy collection install -r /tmp/requirements.yml \
      --collections-path /opt/ansible/.ansible/collections; \
    chmod -R g+rwX /opt/ansible/.ansible; \
    rm -f /tmp/requirements.yml

# Operator content
COPY watches.yaml ./watches.yaml
COPY playbooks/ ./playbooks/
COPY roles/ ./roles/

# Perms
RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses

USER 1001
ENV ANSIBLE_USER_ID=1001

# -----------------------------------------------------------------------------
# Stage 3: final (default output of "podman build .")
# Publishing the patched official base image.
# -----------------------------------------------------------------------------
FROM basepatched AS final
USER 1001
ENV ANSIBLE_USER_ID=1001
