# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - CVE-aware builds with two strategies
#
# TARGETS
#   1) basepatched : Patch the official OpenShift-matched operator base in-place
#   2) rebased     : Patch UBI9 first, then copy ONLY operator/runtime bits
#                   (avoids breaking dnf/libdnf like your error)
#
# BUILD EXAMPLES
#   podman build --target basepatched -t quay.io/philip860/webserver-operator:basepatched .
#   podman build --target rebased     -t quay.io/philip860/webserver-operator:rebased     .
#
# OPTIONAL OVERRIDES
#   --build-arg BASE_OPERATOR_IMAGE=registry.redhat.io/openshift4/ose-ansible-rhel9-operator@sha256:...
#   --build-arg UBI_IMAGE=registry.access.redhat.com/ubi9/ubi@sha256:...
# -----------------------------------------------------------------------------

ARG BASE_OPERATOR_IMAGE=registry.redhat.io/openshift4/ose-ansible-rhel9-operator@sha256:440d3e4711ebd68f14e1e1575b757db4d202850070f0f634dc5c6cab89d02e7b
ARG UBI_IMAGE=registry.access.redhat.com/ubi9/ubi:latest

# -----------------------------------------------------------------------------
# Stage 0: official operator base (source of operator runtime bits for rebase)
# -----------------------------------------------------------------------------
FROM ${BASE_OPERATOR_IMAGE} AS operator-src

# -----------------------------------------------------------------------------
# Stage 1: basepatched (patch in-place on the official base)
# -----------------------------------------------------------------------------
FROM ${BASE_OPERATOR_IMAGE} AS basepatched

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# (A) ONLINE PATCHING
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# (B) APPLY SPECIFIC SECURITY ADVISORIES (RHSA) BY ID (best-effort)
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y install dnf-plugins-core; \
    echo "=== Available RHSAs (debug) ==="; \
    dnf -y updateinfo list --available | sed -n '1,160p' || true; \
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

# -----------------------------------------------------------------------------
# (C) OFFLINE/LOCAL RPM PATCHING (./patching/*.rpm)
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# POST-PATCH VERIFICATION (lightweight, non-fatal)
# -----------------------------------------------------------------------------
RUN set -eux; \
    echo "=== RPM versions after patching ==="; \
    rpm -q libxml2 sqlite-libs krb5-libs pam python3 python3-libs libarchive expat 2>/dev/null || true

# -----------------------------------------------------------------------------
# REQUIRED CERTIFICATION LABELS (edit values to match your project)
# -----------------------------------------------------------------------------
LABEL name="webserver-operator-dev" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.35" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

# -----------------------------------------------------------------------------
# LICENSING FOR HasLicense CHECK
# -----------------------------------------------------------------------------
RUN mkdir -p /licenses \
 && printf "See project repository for license and terms.\n" > /licenses/NOTICE

# -----------------------------------------------------------------------------
# INSTALL REQUIRED ANSIBLE COLLECTIONS
# -----------------------------------------------------------------------------
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    ansible-galaxy collection install -r /tmp/requirements.yml \
      --collections-path /opt/ansible/.ansible/collections; \
    chmod -R g+rwX /opt/ansible/.ansible; \
    rm -f /tmp/requirements.yml

# -----------------------------------------------------------------------------
# COPY OPERATOR CONTENT
# -------------------------------
