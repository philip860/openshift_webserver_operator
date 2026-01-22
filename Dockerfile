# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - REBASED UBI image (publish this)
#
# Goals:
# - Build a certification-friendly image based on UBI9 (no mixed RHEL repos)
# - Keep the OpenShift ansible-operator runtime behavior (ENTRYPOINT + /opt layout)
# - Ensure ansible-runner exists (UBI repo doesn't ship it) via pip, wired into system python
# - Ensure Ansible/Runner temp + cache dirs are writable under arbitrary UID (restricted SCC)
# - Ensure logs go to stdout (oc logs / OpenShift Console)
# - Avoid copying non-existent files (e.g., /usr/local/bin/entrypoint does NOT exist)
# -----------------------------------------------------------------------------

# Pin the exact OpenShift operator image digest you are rebasing from
ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# -----------------------------------------------------------------------------
# Stage 0: Source image (Red Hat OpenShift ansible-operator). We only copy bits from here.
# -----------------------------------------------------------------------------
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

# -----------------------------------------------------------------------------
# Stage 1: Final runtime image (UBI9). This is what you publish.
# -----------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0

# Where operator-sdk expects to find the operator project content
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# Repo hygiene: keep UBI repos only (avoid accidental RHEL repo mixing)
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# -----------------------------------------------------------------------------
# Install UBI packages needed for:
# - running ansible-playbook (ansible-core)
# - running pip to add ansible-runner (not available as an RPM in UBI repos)
# - basic TLS and tooling
#
# NOTE:
# - do NOT install curl unless you must (curl-minimal may be present and conflicts)
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates python3 python3-pip python3-setuptools ansible-core; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# Patch UBI packages (security updates)
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# Create expected directories.
# - /opt/ansible-operator: operator project root
# - /opt/ansible/.ansible: collections + cache
# - /opt/pip: pip prefix install location for ansible-runner
# -----------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p \
      /opt/ansible-operator \
      /opt/ansible/.ansible \
      /opt/pip \
      /licenses

# -----------------------------------------------------------------------------
# Copy operator runtime bits from the OpenShift image.
#
# IMPORTANT:
# - We copy /opt from the operator image because it contains operator runtime assets.
# - We copy the ansible-operator binary explicitly.
# - We DO NOT copy /usr/local/bin/entrypoint because it does not exist in that image.
# -----------------------------------------------------------------------------
COPY --from=operator-src /opt/ /opt/
COPY --from=operator-src /usr/local/bin/ansible-operator /usr/local/bin/ansible-operator

# -----------------------------------------------------------------------------
# Install ansible-runner using pip into /opt/pip and wire it into system python.
#
# Why the extra .pth file?
# - Pip --prefix installs modules under /opt/pip/lib/pythonX.Y/site-packages
# - Ansible in this image runs under /usr/bin/python3
# - Adding a .pth in the system site-packages makes python import from /opt/pip too
#
# Also:
# - Provide a stable /usr/local/bin/ansible-runner shim that runs module with system python
# -----------------------------------------------------------------------------
RUN set -eux; \
    /usr/bin/pip3 install --no-cache-dir --prefix /opt/pip "ansible-runner>=2.4,<3"; \
    pyver="$(/usr/bin/python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"; \
    sitepk="/opt/pip/lib/python${pyver}/site-packages"; \
    test -d "${sitepk}"; \
    echo "${sitepk}" > "/usr/lib/python${pyver}/site-packages/zz_opt_pip_sitepackages.pth"; \
    printf '%s\n' '#!/bin/sh' 'exec /usr/bin/python3 -m ansible_runner "$@"' > /usr/local/bin/ansible-runner; \
    chmod +x /usr/local/bin/ansible-runner; \
    /usr/local/bin/ansible-runner --version; \
    /usr/bin/python3 -c 'import ansible_runner; print("ansible_runner import OK")'

# -----------------------------------------------------------------------------
# Certification / metadata labels (adjust as needed)
# -----------------------------------------------------------------------------
LABEL name="webserver-operator-dev" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.34" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

# Licensing (placeholder)
RUN set -eux; \
    printf "See project repository for license and terms.\n" > /licenses/NOTICE

# -----------------------------------------------------------------------------
# Console-friendly Ansible logs (oc logs / OpenShift Console)
# -----------------------------------------------------------------------------
ENV ANSIBLE_STDOUT_CALLBACK=default \
    ANSIBLE_LOAD_CALLBACK_PLUGINS=1 \
    ANSIBLE_FORCE_COLOR=0 \
    ANSIBLE_NOCOLOR=1 \
    ANSIBLE_DISPLAY_SKIPPED_HOSTS=1 \
    ANSIBLE_DISPLAY_OK_HOSTS=1 \
    ANSIBLE_SHOW_TASK_PATH_ON_FAILURE=1 \
    ANSIBLE_VERBOSITY=2 \
    PYTHONUNBUFFERED=1

# -----------------------------------------------------------------------------
# Ensure Ansible/Runner write to a writable location under restricted SCC.
#
# Your error earlier was trying to write to: /.ansible/tmp
# Fix by explicitly setting HOME and the various Ansible temp dirs under /opt/ansible.
# -----------------------------------------------------------------------------
ENV HOME=/opt/ansible \
    ANSIBLE_HOME=/opt/ansible \
    ANSIBLE_LOCAL_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_REMOTE_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_COLLECTIONS_PATHS=/opt/ansible/.ansible/collections:/usr/share/ansible/collections \
    ANSIBLE_ROLES_PATH=/opt/ansible/.ansible/roles:/etc/ansible/roles:/usr/share/ansible/roles

RUN set -eux; \
    mkdir -p /opt/ansible/.ansible/tmp /opt/ansible/.ansible/collections /opt/ansible/.ansible/roles; \
    chmod -R g+rwX /opt/ansible

# -----------------------------------------------------------------------------
# Install required Ansible collections (using requirements.yml in your repo)
# -----------------------------------------------------------------------------
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    ansible-galaxy collection install -r /tmp/requirements.yml \
      --collections-path /opt/ansible/.ansible/collections; \
    rm -f /tmp/requirements.yml; \
    chmod -R g+rwX /opt/ansible/.ansible

# -----------------------------------------------------------------------------
# Copy operator project content
# -----------------------------------------------------------------------------
COPY watches.yaml ./watches.yaml
COPY playbooks/ ./playbooks/
COPY roles/ ./roles/

# -----------------------------------------------------------------------------
# Fix permissions for arbitrary UID (OpenShift restricted SCC):
# - group 0 (root group) + g=u so random UID in group 0 can write where needed
# -----------------------------------------------------------------------------
RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /opt/pip /usr/local/bin/ansible-runner; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /opt/pip; \
    chmod g=u /usr/local/bin/ansible-runner

# Run as non-root
USER 1001
ENV ANSIBLE_USER_ID=1001

# -----------------------------------------------------------------------------
# IMPORTANT: Make sure the image actually starts the operator.
# This restores runtime behavior even though we're rebasing onto UBI.
# -----------------------------------------------------------------------------
ENTRYPOINT ["/usr/local/bin/ansible-operator"]
CMD ["run"]
