# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - UBI9 Rebase (Path B)
#
# Goals:
# - Publish on UBI9 (repo hygiene; avoid rhel-9-for-* repo mixing).
# - Keep the OpenShift ansible-operator runtime behavior (ENTRYPOINT runs operator).
# - Use UBI python + ansible-core for ansible-galaxy.
# - Provide ansible-runner (not available as UBI RPM in your build context):
#     * install via pip into /opt/pip
#     * add a .pth file so system python can import it
#     * provide /usr/local/bin/ansible-runner wrapper on PATH
# - OpenShift restricted SCC friendly:
#     * arbitrary UID
#     * writable Ansible temp/cache dirs (avoid /.ansible/tmp permission denied)
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# Stage 0: Official operator base image (source of runtime bits + ansible-operator binary)
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

# Final stage: UBI9
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0

# Directory ansible-operator expects
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# Repo hygiene: ensure we only use UBI repos
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# -----------------------------------------------------------------------------
# Install base tooling from UBI repos
# NOTE: Do NOT install curl explicitly (curl-minimal conflicts are common).
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates yum; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y install python3 python3-setuptools python3-pip ansible-core; \
    /usr/bin/python3 --version; \
    ansible-galaxy --version; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# Patch UBI packages (security errata)
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# Create expected dirs:
# - /opt/ansible and /opt/ansible/.ansible for collections/caches
# - /opt/pip for pip --prefix installs (ansible-runner)
# - /licenses for certification
# - /usr/local/bin for stable wrappers
# - /tmp/ansible/tmp for Ansible temp (writable under restricted SCC)
# -----------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p \
      /opt/ansible \
      /opt/ansible/.ansible \
      /opt/ansible/.cache \
      /opt/pip \
      /licenses \
      /usr/local/bin \
      /opt/ansible-operator \
      /tmp/ansible/tmp

# -----------------------------------------------------------------------------
# Copy operator runtime bits from the official operator image
# IMPORTANT:
# - Copy /opt runtime bits (required)
# - Copy ONLY ansible-operator binary (do NOT copy /usr/local/bin wrappers)
#   because those wrappers may reference python paths not present in UBI.
# -----------------------------------------------------------------------------
COPY --from=operator-src /opt/ /opt/
COPY --from=operator-src /usr/local/bin/ansible-operator /usr/local/bin/ansible-operator

# Sanity check: ansible-operator exists and prints version
RUN set -eux; \
    test -x /usr/local/bin/ansible-operator; \
    /usr/local/bin/ansible-operator version

# -----------------------------------------------------------------------------
# Install ansible-runner via pip into /opt/pip
#
# Why the .pth file:
# - pip --prefix installs modules to /opt/pip/lib/pythonX.Y/site-packages
# - system python doesn't search that path by default
# - .pth adds it to sys.path automatically
#
# Why wrapper script:
# - provides stable "ansible-runner" executable on PATH
# - avoids shebang/path issues
# -----------------------------------------------------------------------------
RUN set -eux; \
    /usr/bin/pip3 install --no-cache-dir --prefix /opt/pip "ansible-runner>=2.4,<3"; \
    pyver="$(/usr/bin/python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"; \
    sitepk="/opt/pip/lib/python${pyver}/site-packages"; \
    test -d "${sitepk}"; \
    echo "${sitepk}" > "/usr/lib/python${pyver}/site-packages/zz_opt_pip_sitepackages.pth"; \
    printf '%s\n' '#!/bin/sh' 'exec /usr/bin/python3 -m ansible_runner "$@"' > /usr/local/bin/ansible-runner; \
    chmod +x /usr/local/bin/ansible-runner; \
    /usr/local/bin/ansible-runner --version

# -----------------------------------------------------------------------------
# Certification labels
# -----------------------------------------------------------------------------
LABEL name="webserver-operator-dev" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.34" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

# Licensing placeholder (adjust as needed)
RUN set -eux; \
    printf "See project repository for license and terms.\n" > /licenses/NOTICE

# -----------------------------------------------------------------------------
# Runtime/logging + OpenShift SCC friendliness
#
# The KEY fix for your error:
#   ERROR: Unable to create local directories(/.ansible/tmp): Permission denied
#
# This happens when $HOME is "/" (or unset) under arbitrary UID, so "~/.ansible"
# becomes "/.ansible". We force HOME and Ansible temp dirs to writable paths.
# -----------------------------------------------------------------------------
ENV HOME=/opt/ansible \
    XDG_CACHE_HOME=/opt/ansible/.cache \
    ANSIBLE_LOCAL_TEMP=/tmp/ansible/tmp \
    ANSIBLE_REMOTE_TEMP=/tmp/ansible/tmp \
    ANSIBLE_TMPDIR=/tmp/ansible/tmp \
    ANSIBLE_STDOUT_CALLBACK=default \
    ANSIBLE_LOAD_CALLBACK_PLUGINS=1 \
    ANSIBLE_FORCE_COLOR=0 \
    PYTHONUNBUFFERED=1 \
    ANSIBLE_DEPRECATION_WARNINGS=False \
    PATH="/opt/pip/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# -----------------------------------------------------------------------------
# Install required Ansible collections into /opt/ansible/.ansible/collections
# -----------------------------------------------------------------------------
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    ansible-galaxy collection install -r /tmp/requirements.yml \
      --collections-path /opt/ansible/.ansible/collections; \
    rm -f /tmp/requirements.yml

# -----------------------------------------------------------------------------
# Copy operator content
# -----------------------------------------------------------------------------
COPY watches.yaml ./watches.yaml
COPY playbooks/ ./playbooks/
COPY roles/ ./roles/

# -----------------------------------------------------------------------------
# OpenShift-friendly permissions:
# - chgrp 0 + chmod g=u => arbitrary UID can read/write where needed.
# -----------------------------------------------------------------------------
RUN set -eux; \
    chgrp -R 0 \
      ${ANSIBLE_OPERATOR_DIR} \
      /opt/ansible \
      /opt/ansible/.ansible \
      /opt/ansible/.cache \
      /licenses \
      /usr/local/bin \
      /opt/pip \
      /tmp/ansible; \
    chmod -R g=u \
      ${ANSIBLE_OPERATOR_DIR} \
      /opt/ansible \
      /opt/ansible/.ansible \
      /opt/ansible/.cache \
      /licenses \
      /usr/local/bin \
      /opt/pip \
      /tmp/ansible

# Non-root (restricted SCC)
USER 1001
ENV ANSIBLE_USER_ID=1001

# -----------------------------------------------------------------------------
# Match typical operator image behavior
# -----------------------------------------------------------------------------
ENTRYPOINT ["/usr/local/bin/ansible-operator"]
CMD ["run", "--watches-file=/opt/ansible-operator/watches.yaml"]
