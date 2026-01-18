# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator base) - patched + certification-friendly
#
# GOALS
#  - Build on the OpenShift-matched Ansible Operator base image (RHEL 9 stream)
#  - Remain "restricted SCC" compatible (arbitrary UID at runtime)
#  - Keep Red Hat certification metadata + HasLicense content
#  - Allow TWO patching strategies:
#      (A) Online update from repos (dnf update)
#      (B) Offline/local RPM patching via ./patching/*.rpm (yum localinstall)
#
# NOTE ON CVEs / SCANS
#  - If your scanner reports CVEs but `dnf check-update <pkgs>` shows nothing,
#    you're already at the newest packages in the configured repos.
#  - In that case, local RPM patching (./patching) is your "escape hatch",
#    but ONLY if you have the correct vendor-signed RPM builds (and deps).
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
# (A) OPTIONAL: Online patching from enabled repos
# -----------------------------------------------------------------------------
# This keeps the base reasonably current at build time.
# If your build environment has stable network/repo access, keep this enabled.
#
# Tip: If you need to debug what changed, build with:
#   podman build --pull --no-cache -t <image>:<tag> .
#
# Tip: To see if anything is even updatable inside the built image:
#   podman run --rm --entrypoint /bin/sh <image>:<tag> -c \
#     'dnf -q check-update libxml2 krb5-libs pam python3 python3-libs || true'
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# (B) OPTIONAL: Offline/local RPM patching (./patching/*.rpm)
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
