# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - Path B (UBI rebase) WITHOUT breaking runner events
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# -----------------------------------------------------------------------------
# Stage 0: Use official operator image as the "truth" for ansible/runner behavior
# -----------------------------------------------------------------------------
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# Pre-install collections USING the official image (so we don't need ansible-core in UBI)
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    if [ -s /tmp/requirements.yml ]; then \
      ansible-galaxy collection install -r /tmp/requirements.yml \
        --collections-path /opt/ansible/.ansible/collections; \
    fi; \
    rm -f /tmp/requirements.yml

# Bring in operator content (packaged into /opt in the final image)
COPY watches.yaml ${ANSIBLE_OPERATOR_DIR}/watches.yaml
COPY playbooks/ ${ANSIBLE_OPERATOR_DIR}/playbooks/
COPY roles/ ${ANSIBLE_OPERATOR_DIR}/roles/

# -----------------------------------------------------------------------------
# Stage 1: Final UBI filesystem we publish (scan-friendly)
# -----------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# Repo hygiene: keep ONLY UBI repos
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# Install only the minimal OS/python runtime pieces (NO ansible-core here)
# Avoid curl install to prevent curl vs curl-minimal conflicts.
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates \
      python3 python3-pyyaml python3-jinja2 python3-cryptography python3-requests python3-six \
      python3-pexpect \
      tar gzip findutils which shadow-utils; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Patch UBI (your CVE reduction lever)
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh || dnf -y update --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# OpenShift-friendly dirs + env (DO NOT force stdout_callback)
ENV HOME=/opt/ansible \
    ANSIBLE_LOCAL_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_REMOTE_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_COLLECTIONS_PATHS=/opt/ansible/.ansible/collections:/usr/share/ansible/collections \
    ANSIBLE_ROLES_PATH=/opt/ansible/.ansible/roles:/etc/ansible/roles:/usr/share/ansible/roles \
    ANSIBLE_NOCOLOR=1 \
    ANSIBLE_FORCE_COLOR=0 \
    TERM=dumb \
    PYTHONUNBUFFERED=1

RUN set -eux; \
    mkdir -p \
      /opt/ansible/.ansible/tmp \
      /opt/ansible/.ansible/collections \
      /opt/ansible/.ansible/roles \
      /etc/ansible \
      /licenses \
      ${ANSIBLE_OPERATOR_DIR}

# ---- TRANSPLANT runtime from official operator image (this is the key) ----

# /opt runtime bits (includes your operator content + installed collections)
COPY --from=operator-src /opt/ /opt/

# ansible-operator binary
COPY --from=operator-src /usr/local/bin/ansible-operator /usr/local/bin/ansible-operator

# ansible/runner executables that the operator expects to call
COPY --from=operator-src /usr/bin/ansible /usr/bin/ansible
COPY --from=operator-src /usr/bin/ansible-playbook /usr/bin/ansible-playbook
COPY --from=operator-src /usr/bin/ansible-galaxy /usr/bin/ansible-galaxy
COPY --from=operator-src /usr/bin/ansible-doc /usr/bin/ansible-doc
COPY --from=operator-src /usr/bin/ansible-runner /usr/bin/ansible-runner

# python modules for ansible + ansible-runner (keep event/callback behavior identical)
COPY --from=operator-src /usr/lib/python3.9/site-packages/ansible/ /usr/lib/python3.9/site-packages/ansible/
COPY --from=operator-src /usr/lib/python3.9/site-packages/ansible-*.dist-info/ /usr/lib/python3.9/site-packages/
COPY --from=operator-src /usr/lib/python3.9/site-packages/ansible_runner/ /usr/lib/python3.9/site-packages/ansible_runner/
COPY --from=operator-src /usr/lib/python3.9/site-packages/ansible_runner-*.dist-info/ /usr/lib/python3.9/site-packages/

# NOTE: do NOT write stdout_callback in ansible.cfg
RUN set -eux; \
    printf "%s\n" \
      "[defaults]" \
      "bin_ansible_callbacks = True" \
      "nocows = 1" \
      > /etc/ansible/ansible.cfg

# Required certification labels + NOTICE
LABEL name="webserver-operator" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.35" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

RUN set -eux; \
    printf "See project repository for license and terms.\n" > /licenses/NOTICE

# Permissions for arbitrary UID
RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /etc/ansible /usr/local/bin || true; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /etc/ansible /usr/local/bin || true

# Entrypoint
RUN set -eux; \
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'exec /usr/local/bin/ansible-operator run --watches-file=/opt/ansible-operator/watches.yaml' \
  > /usr/local/bin/entrypoint; \
  chmod 0755 /usr/local/bin/entrypoint

USER 1001
ENV ANSIBLE_USER_ID=1001
ENTRYPOINT ["/usr/local/bin/entrypoint"]
