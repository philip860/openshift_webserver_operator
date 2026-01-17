# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator base) - patched + certification-friendly
# -----------------------------------------------------------------------------
#FROM quay.io/operator-framework/ansible-operator:v1.34.1
FROM quay.io/operator-framework/ansible-operator:latest

# Need root for patching + installing collections + permissions
USER 0

# This is the directory ansible-operator expects to run from
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# ---- Patch OS packages to pull in latest security errata available at build time ----
# (Helps reduce CVEs in base packages like curl/expat/gnutls/krb5/etc.)
RUN set -eux; \
    if command -v microdnf >/dev/null 2>&1; then \
      mkdir -p /var/cache/yum /var/tmp; \
      microdnf -y update; \
      microdnf -y clean all; \
      rm -rf /var/cache/yum /var/tmp/* /tmp/*; \
    elif command -v dnf >/dev/null 2>&1; then \
      dnf -y update; \
      dnf -y clean all; \
      rm -rf /var/cache/dnf /var/tmp/* /tmp/*; \
    elif command -v yum >/dev/null 2>&1; then \
      yum -y update; \
      yum -y clean all; \
      rm -rf /var/cache/yum /var/tmp/* /tmp/*; \
    else \
      echo "WARN: No package manager found to apply updates." >&2; \
    fi

# ---- Required certification labels (edit values to match your project) ----
LABEL name="webserver-operator-dev" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.34" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

# ---- Licensing for HasLicense check ----
# Put a plain-text license/terms file under /licenses
RUN mkdir -p /licenses \
 && printf "See project repository for license and terms.\n" > /licenses/NOTICE

# ---- Install required Ansible collections ----
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    ansible-galaxy collection install -r /tmp/requirements.yml \
      --collections-path /opt/ansible/.ansible/collections; \
    chmod -R g+rwX /opt/ansible/.ansible; \
    rm -f /tmp/requirements.yml

# ---- Copy operator content ----
COPY watches.yaml ./watches.yaml
COPY playbooks/ ./playbooks/
COPY roles/ ./roles/

# ---- OpenShift-friendly permissions ----
# Allow arbitrary UID (restricted SCC) to write where it needs to.
RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses

# ---- Run as a non-root user in image metadata (fixes RunAsNonRoot) ----
# Use a fixed non-root numeric UID to satisfy preflight.
USER 1001

# If the base image expects ANSIBLE_USER_ID at runtime, keep it consistent:
ENV ANSIBLE_USER_ID=1001

