# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - UBI Rebase that still RUNS like the
# Red Hat ose-ansible-rhel9-operator image.
#
# Fixes:
# - Provide /usr/local/bin/entrypoint so OLM/CSV can launch the operator
# - Provide ansible-operator binary (copied from ose base)
# - Install python deps required by kubernetes.core modules (kubernetes + openshift)
# - Install ansible-runner (required by ansible-operator runner backend)
# - Ensure HOME + Ansible tmp dirs are writable under restricted-v2 SCC
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# Stage 0: Source the working Red Hat operator bits (entrypoint + ansible-operator)
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

# Stage 1: Our published UBI image
FROM registry.access.redhat.com/ubi9/ubi:latest

USER 0

# Where ansible-operator expects to run from
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# ---------------------------------------------------------------------------
# Repo hygiene: keep UBI repos only (avoid mixing rhel-9-for-* repos)
# ---------------------------------------------------------------------------
RUN set -eux; \
  rm -f /etc/yum.repos.d/redhat.repo || true; \
  rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# ---------------------------------------------------------------------------
# Install base tooling from UBI repos:
# - python3 + pip so we can install runtime python libs
# - ansible-core so ansible-galaxy/ansible-playbook are consistent with /usr/bin/python3
# ---------------------------------------------------------------------------
RUN set -eux; \
  dnf -y install \
    ca-certificates \
    python3 python3-pip python3-setuptools \
    ansible-core \
    findutils \
  ; \
  dnf -y clean all; \
  rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# ---------------------------------------------------------------------------
# Patch UBI first (security updates)
# ---------------------------------------------------------------------------
RUN set -eux; \
  dnf -y makecache --refresh; \
  dnf -y update --security --refresh; \
  dnf -y clean all; \
  rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# ---------------------------------------------------------------------------
# Copy ONLY the operator runtime bits we actually need from the official image:
# - /usr/local/bin/entrypoint  (CRITICAL: OLM expects this)
# - /usr/local/bin/ansible-operator
# - /opt/* (includes operator scaffolding bits used by ansible-operator plugins)
# NOTE: We do NOT copy /usr/local/bin/ansible* wrapper scripts because they
#       reference /usr/local/bin/python3 (3.12 in the ose image) which does not
#       exist in UBI. We use UBI's /usr/bin/ansible-* from ansible-core instead.
# ---------------------------------------------------------------------------
COPY --from=operator-src /usr/local/bin/entrypoint /usr/local/bin/entrypoint
COPY --from=operator-src /usr/local/bin/ansible-operator /usr/local/bin/ansible-operator
COPY --from=operator-src /opt/ /opt/

# Make sure entrypoint is executable
RUN set -eux; \
  chmod 0755 /usr/local/bin/entrypoint /usr/local/bin/ansible-operator

# ---------------------------------------------------------------------------
# Install python runtime deps required by your playbooks:
# - kubernetes + openshift: required for kubernetes.core.k8s_* modules
# - ansible-runner: required by ansible-operator to execute playbooks
# Keep pins conservative to avoid surprises.
# ---------------------------------------------------------------------------
RUN set -eux; \
  /usr/bin/python3 -m pip install --no-cache-dir --upgrade pip; \
  /usr/bin/python3 -m pip install --no-cache-dir \
    "ansible-runner>=2.4,<3" \
    "kubernetes>=26.1.0" \
    "openshift>=0.13.2" \
  ; \
  command -v ansible-runner; \
  ansible-runner --version; \
  /usr/bin/python3 -c "import kubernetes, openshift; print('kubernetes+openshift python OK')"

# ---------------------------------------------------------------------------
# Create directories that MUST be writable under restricted-v2:
# - HOME set to /opt/ansible (writable)
# - ansible local temp to /opt/ansible/.ansible/tmp
# - collections under /opt/ansible/.ansible/collections
# ---------------------------------------------------------------------------
RUN set -eux; \
  mkdir -p \
    /opt/ansible/.ansible/tmp \
    /opt/ansible/.ansible/collections \
    /licenses \
    ${ANSIBLE_OPERATOR_DIR} \
  ; \
  chgrp -R 0 /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR}; \
  chmod -R g=u /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR}

# ---------------------------------------------------------------------------
# Certification labels + NOTICE
# ---------------------------------------------------------------------------
LABEL name="webserver-operator-dev" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.34" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

RUN set -eux; \
  printf "See project repository for license and terms.\n" > /licenses/NOTICE

# ---------------------------------------------------------------------------
# Install required Ansible collections (using UBI's ansible-galaxy)
# ---------------------------------------------------------------------------
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
  /usr/bin/ansible-galaxy collection install -r /tmp/requirements.yml \
    --collections-path /opt/ansible/.ansible/collections; \
  rm -f /tmp/requirements.yml; \
  chgrp -R 0 /opt/ansible/.ansible; \
  chmod -R g=u /opt/ansible/.ansible

# ---------------------------------------------------------------------------
# Copy operator content into expected locations
# ---------------------------------------------------------------------------
COPY watches.yaml ./watches.yaml
COPY playbooks/ ./playbooks/
COPY roles/ ./roles/

# ---------------------------------------------------------------------------
# Runtime env: force writable HOME and tmp so Ansible doesn't try /.ansible/tmp
# ---------------------------------------------------------------------------
ENV HOME=/opt/ansible \
    ANSIBLE_LOCAL_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_REMOTE_TMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_COLLECTIONS_PATHS=/opt/ansible/.ansible/collections:/usr/share/ansible/collections \
    ANSIBLE_STDOUT_CALLBACK=default \
    ANSIBLE_LOAD_CALLBACK_PLUGINS=1 \
    ANSIBLE_FORCE_COLOR=0 \
    PYTHONUNBUFFERED=1 \
    ANSIBLE_DEPRECATION_WARNINGS=False

# OpenShift arbitrary UID best practice
USER 1001

# CRITICAL: keep the same entrypoint the Red Hat operator image uses
ENTRYPOINT ["/usr/local/bin/entrypoint"]
