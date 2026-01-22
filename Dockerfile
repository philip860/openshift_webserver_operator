# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - CVE-aware builds + RunAsNonRoot safe
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Stage 0: official operator base (source of runtime bits for rebased)
# -----------------------------------------------------------------------------
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator:latest AS operator-src

# -----------------------------------------------------------------------------
# Stage 1: basepatched (patch in-place on the official base)
# -----------------------------------------------------------------------------
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator:latest AS basepatched

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# Enable required repos (CRB/CodeReady Builder + EPEL) best-effort
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates || true; \
    echo "=== Enabling CodeReady Builder / CRB (best-effort) ==="; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms 2>/dev/null || true; \
    dnf config-manager --set-enabled crb 2>/dev/null || true; \
    echo "=== Enabling EPEL (best-effort) ==="; \
    dnf -y install epel-release 2>/dev/null || true; \
    echo "=== Enabled repos (debug) ==="; \
    dnf repolist || true; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*


# (A) ONLINE PATCHING
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# (B) APPLY SPECIFIC SECURITY ADVISORIES (RHSA) BY ID (best-effort)
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

# (C) OFFLINE/LOCAL RPM PATCHING (./patching/*.rpm)
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

# POST-PATCH VERIFICATION (non-fatal)
RUN set -eux; \
    echo "=== RPM versions after patching ==="; \
    rpm -q libxml2 sqlite-libs krb5-libs pam python3 python3-libs libarchive expat 2>/dev/null || true

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
# Stage 2: rebased (patch UBI first, then copy ONLY operator/runtime bits)
# -----------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi9/ubi:latest AS rebased

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# Enable required repos (UBI CodeReady Builder + EPEL) best-effort
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates curl yum || true; \
    \
    echo "=== Enabling CodeReady Builder / CRB (best-effort) ==="; \
    if command -v subscription-manager >/dev/null 2>&1; then \
      subscription-manager repos --enable "codeready-builder-for-rhel-9-$(arch)-rpms" || true; \
    fi; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms 2>/dev/null || true; \
    dnf config-manager --set-enabled crb 2>/dev/null || true; \
    \
    echo "=== Enabling EPEL (best-effort) ==="; \
    dnf -y install epel-release 2>/dev/null || \
      dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm 2>/dev/null || true; \
    \
    echo "=== Enabled repos (debug) ==="; \
    dnf repolist || true; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Patch UBI FIRST
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --refresh; \
    dnf -y install dnf-plugins-core yum; \
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

# Create expected dirs
RUN set -eux; \
    mkdir -p /opt/ansible /opt/ansible/.ansible /licenses /opt/ansible-operator /tmp/patching

# Copy ONLY operator runtime bits (safe)
COPY --from=operator-src /usr/local/bin/ /usr/local/bin/
COPY --from=operator-src /opt/ /opt/

# Offline/local RPM patching (optional)
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

# Verification
RUN set -eux; \
    echo "=== RPM versions after patching ==="; \
    rpm -q libxml2 sqlite-libs krb5-libs pam python3 python3-libs libarchive expat 2>/dev/null || true

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

# RunAsNonRoot MUST be last
USER 1001
ENV ANSIBLE_USER_ID=1001


# -----------------------------------------------------------------------------
# Stage 3: final (default output of "podman build .")
# -----------------------------------------------------------------------------
FROM basepatched AS final
USER 1001
ENV ANSIBLE_USER_ID=1001
