# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator base) - patched + certification-friendly
#
# GOALS
#  - Build on the OpenShift-matched Ansible Operator base image (RHEL 9 stream)
#  - Remain "restricted SCC" compatible (arbitrary UID at runtime)
#  - Keep Red Hat certification metadata + HasLicense content
#  - Allow THREE patching strategies:
#      (A) Online update from repos (dnf update)
#      (B) Apply specific Red Hat advisories (RHSA) by ID (dnf update --advisory)
#      (C) Offline/local RPM patching via ./patching/*.rpm (yum localinstall)
#
# NOTE ON CVEs / SCANS
#  - If your scanner reports CVEs but `dnf check-update <pkgs>` shows nothing,
#    you're already at the newest packages in the configured repos.
#  - In that case:
#      - Strategy (B) will only work if the advisory is visible to your repos.
#      - Strategy (C) is your escape hatch *if* you have the correct RPM builds.
#
# IMPORTANT CERTIFICATION NOTE
#  - Applying RHSAs via enabled Red Hat repos is the cleanest/most defensible path.
#  - Offline RPM patching should be reserved for situations where the base stream
#    hasn’t picked up fixes yet (and you have vendor-signed RPMs + dependencies).
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# BASE IMAGE
# -----------------------------------------------------------------------------
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator:v4.20
# (Recommended for reproducibility once you find a "good scan" base digest)
# FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@sha256:...

# Need root for patching + installing collections + permissions
USER 0

# This is the directory ansible-operator expects to run from
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# (A) ONLINE PATCHING: Refresh metadata + full update
# -----------------------------------------------------------------------------
# This keeps the base reasonably current at build time.
# If your build environment has stable network/repo access, keep this enabled.
#
# Tip: If you need to debug what changed, build with:
#   podman build --pull --no-cache -t <image>:<tag> .
#
# Tip: To see if anything is even updatable inside the built image:
#   podman run --rm --entrypoint /bin/sh <image>:<tag> -c \
#     'dnf -q check-update libxml2 krb5-libs pam python3 python3-libs libarchive sqlite-libs expat || true'
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# (B) APPLY SPECIFIC SECURITY ADVISORIES (RHSA) BY ID
# -----------------------------------------------------------------------------
# Why this exists:
#   Your scan output references RHSAs such as:
#     RHSA-2025:2678 (libxml2)
#     RHSA-2025:10399 (python3/python3-libs)
#     RHSA-2024:9547 (krb5-libs)
#     RHSA-2024:10232 (pam)
#     RHSA-2025:14142 (libarchive)
#     RHSA-2025:12036 (sqlite-libs)
#     RHSA-2025:22033 (expat)
#     RHSA-2025:11580 / RHSA-2025:13312 (libxml2)
#
# How it works:
#   - Install dnf-plugins-core so `dnf updateinfo` exists.
#   - For each RHSA, attempt to apply it:
#       dnf -y update --advisory=RHSA-YYYY:NNNN
#
# Important:
#   - This ONLY updates packages if the advisory is visible in the repos inside
#     this base image. If the advisory isn’t available yet, the command will do
#     nothing (or may exit non-zero depending on environment).
#   - We keep this BEST-EFFORT (|| true) so the build doesn’t fail if a given
#     advisory is not present in the repo snapshot.
#
# Tip:
#   If you want to hard-fail when an advisory is missing, remove "|| true".
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y install dnf-plugins-core; \
    echo "=== Available RHSAs (debug) ==="; \
    dnf -y updateinfo list --available | sed -n '1,120p' || true; \
    echo "=== Attempting to apply targeted RHSAs (best-effort) ==="; \
    dnf -y update --advisory=RHSA-2025:2678  || true; \
    dnf -y update --advisory=RHSA-2025:10399 || true; \
    dnf -y update --advisory=RHSA-2024:9547  || true; \
    dnf -y update --advisory=RHSA-2024:10232 || true; \
    dnf -y update --advisory=RHSA-2025:14142 || true; \
    dnf -y update --advisory=RHSA-2025:12036 || true; \
    dnf -y update --advisory=RHSA-2025:22033 || true; \
    dnf -y update --advisory=RHSA-2025:11580 || true; \
    dnf -y update --advisory=RHSA-2025:13312 || true; \
    # Final refresh update to ensure dependency resolutions are completed
    dnf -y update --refresh || true; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# (C) OFFLINE/LOCAL RPM PATCHING (./patching/*.rpm)
# -----------------------------------------------------------------------------
# Purpose:
#   Apply specific RPM updates even when the OpenShift operator base stream
#   has not yet shipped a rebuilt image digest that includes them.
#
# How it works:
#   - Put vendor RPMs in a local directory named: ./patching/
#   - Example:
#       patching/expat-2.5.0-3.el9_5.3.x86_64.rpm
#   - The RPMs are copied into the image and installed using:
#       yum -y localinstall *.rpm
#
# Important:
#   - Use RPMs that match your OS stream/arch (EL9 + x86_64 here).
#   - If those RPMs require dependencies, yum/dnf will attempt to pull deps
#     from enabled repos. If deps are missing, the build will fail (good!).
#   - If you do NOT want offline patching, leave ./patching empty (or remove
#     this block) and the build will skip localinstall.
COPY patching/ /tmp/patching/

RUN set -eux; \
    echo "=== Offline/local patching (if RPMs present) ==="; \
    ls -lah /tmp/patching || true; \
    rpms="$(ls -1 /tmp/patching/*.rpm 2>/dev/null || true)"; \
    if [ -n "${rpms}" ]; then \
      echo "Installing local RPMs:"; \
      echo "${rpms}" | sed 's/^/  - /'; \
      # localinstall will install/upgrade RPMs and pull dependencies from repos if needed
      yum -y localinstall /tmp/patching/*.rpm; \
    else \
      echo "No RPMs found in /tmp/patching (skipping yum localinstall)."; \
    fi; \
    yum -y clean all; \
    rm -rf /var/cache/dnf /var/cache/yum /tmp/patching /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# POST-PATCH VERIFICATION (lightweight, non-fatal)
# -----------------------------------------------------------------------------
# This prints versions for the packages most frequently flagged in your scans.
# It helps you confirm what the uploaded digest *actually* contains.
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
# Put a plain-text license/terms file under /licenses
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
# -----------------------------------------------------------------------------
COPY watches.yaml ./watches.yaml
COPY playbooks/ ./playbooks/
COPY roles/ ./roles/

# -----------------------------------------------------------------------------
# OPENSHIFT-FRIENDLY PERMISSIONS
# -----------------------------------------------------------------------------
# Allow arbitrary UID (restricted SCC) to write where it needs to.
RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses

# -----------------------------------------------------------------------------
# RUN AS NON-ROOT (fixes RunAsNonRoot in preflight)
# -----------------------------------------------------------------------------
# Use a fixed non-root numeric UID to satisfy preflight.
USER 1001

# If the base image expects ANSIBLE_USER_ID at runtime, keep it consistent:
ENV ANSIBLE_USER_ID=1001
