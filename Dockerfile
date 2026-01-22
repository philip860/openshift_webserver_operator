# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - Path B (Publish REBASED UBI image)
# Goal: Use UBI9 repos for security errata, then copy operator runtime bits
# from the official ose-ansible-rhel9-operator base.
#
# IMPORTANT:
# - Final stage is FROM rebased (NOT basepatched)
# - We enable UBI baseos/appstream (and optionally CRB) explicitly
# - We run a security update BEFORE copying /opt from operator-src, then
#   run a second update AFTER copying (so any deps brought in by /opt get patched)
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# -----------------------------------------------------------------------------
# Stage 0: official operator base (source of runtime bits)
# -----------------------------------------------------------------------------
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

# -----------------------------------------------------------------------------
# Stage 1: rebased (UBI9 is the filesystem we publish)
# -----------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi9/ubi:latest AS rebased

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# ---- Enable UBI repos deterministically (baseos + appstream; optional CRB) ----
# NOTE: UBI containers use UBI repos; subscription-manager is typically not used.
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates curl yum; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y repolist; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# ---- Patch UBI FIRST (before copying operator bits) ----
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Create expected dirs
RUN set -eux; \
    mkdir -p /opt/ansible /opt/ansible/.ansible /licenses /opt/ansible-operator /tmp/patching

# ---- Copy ONLY operator runtime bits from the official operator base ----
# This brings in /opt/ansible-operator, operator-sdk entrypoints, ansible runtime, etc.
COPY --from=operator-src /usr/local/bin/ /usr/local/bin/
COPY --from=operator-src /opt/ /opt/

# ---- Patch AGAIN after copying /opt (so any newly introduced RPM content is updated) ----
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# (Optional) Offline/local RPM patching (./patching/*.rpm)
# Use this only if you have vetted RPMs that match UBI/RHEL streams.
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

# Verification (helps you confirm pam/libxml2 moved off older builds)
RUN set -eux; \
    echo "=== RPM versions (rebased final) ==="; \
    rpm -q pam libxml2 libarchive expat sqlite-libs krb5-libs 2>/dev/null || true; \
    echo "=== Available pam/libxml2 versions (rebased final) ==="; \
    dnf -y repoquery --show-duplicates pam libxml2 | tail -80 || true

# REQUIRED CERTIFICATION LABELS (edit values to match your project)
LABEL name="webserver-operator" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.35" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

# LICENSING FOR HasLicense CHECK
RUN mkdir -p /licenses \
 && printf "See project repository for license and terms.\n" > /licenses/NOTICE

# INSTALL REQUIRED ANSIBLE COLLECTIONS
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    ansible-galaxy collection install -r /tmp/requirements.yml \
      --collections-path /opt/ansible/.ansible/collections; \
    chmod -R g+rwX /opt/ansible/.ansible; \
    rm -f /tmp/requirements.yml

# COPY OPERATOR CONTENT
COPY watches.yaml ./watches.yaml
COPY playbooks/ ./playbooks/
COPY roles/ ./roles/

# OPENSHIFT-FRIENDLY PERMISSIONS (arbitrary UID)
RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses

# RunAsNonRoot MUST be the last USER in the final image config
USER 1001
ENV ANSIBLE_USER_ID=1001

# -----------------------------------------------------------------------------
# Stage 2: final (default output of "podman build .")
# Path B: publish the rebased UBI filesystem
# -----------------------------------------------------------------------------
FROM rebased AS final
USER 1001
ENV ANSIBLE_USER_ID=1001
