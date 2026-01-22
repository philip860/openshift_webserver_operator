# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - Path B (UBI rebase) WITHOUT breaking runner events
#
# Fixes included:
# - Robustly locate python site-packages for ansible/ansible_runner in operator-src
#   (paths vary: /usr/lib64, /usr/local, etc.) and transplant into final image.
# - Robustly copy required binaries from operator-src (/usr/local/bin vs /usr/bin).
# - Do NOT pip install ansible-runner; do NOT force stdout_callback.
# - UBI9 base + dnf update --security for scan/CVE reduction.
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# -----------------------------------------------------------------------------
# Stage 0: Official operator base as source-of-truth (runner events OK here)
# -----------------------------------------------------------------------------
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# Install collections using the official image (avoids needing ansible-core in UBI)
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    if [ -s /tmp/requirements.yml ]; then \
      ansible-galaxy collection install -r /tmp/requirements.yml \
        --collections-path /opt/ansible/.ansible/collections; \
    fi; \
    rm -f /tmp/requirements.yml

# Package operator content into the /opt tree we will copy to final
COPY watches.yaml ${ANSIBLE_OPERATOR_DIR}/watches.yaml
COPY playbooks/ ${ANSIBLE_OPERATOR_DIR}/playbooks/
COPY roles/ ${ANSIBLE_OPERATOR_DIR}/roles/

# -----------------------------------------------------------------------------
# Stage 1: Final image (UBI9) we publish
# -----------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# Repo hygiene: keep ONLY UBI repos
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# Minimal runtime deps only (NO ansible-core, NO ansible-runner via pip)
# Avoid installing curl to prevent curl vs curl-minimal conflicts.
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

# Patch UBI (scan/CVE reduction lever)
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh || dnf -y update --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# OpenShift-friendly env (DO NOT set ANSIBLE_STDOUT_CALLBACK)
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
      ${ANSIBLE_OPERATOR_DIR} \
      /usr/local/bin \
      /usr/lib/python3.9/site-packages

# Copy operator runtime bits from official base (includes /opt, your content, collections, etc.)
COPY --from=operator-src /opt/ /opt/

# Copy /usr from operator-src into temp so we can locate python modules regardless of layout
# (operator-src may use /usr/lib64 or /usr/local, etc.)
COPY --from=operator-src /usr/ /tmp/operator-src/usr/

# Transplant ansible + ansible_runner python modules from operator-src into this image
RUN set -eux; \
    PYROOT=/tmp/operator-src/usr; \
    find "$PYROOT" -maxdepth 7 -type d -name site-packages > /tmp/sitepkgs.txt || true; \
    echo "Candidate site-packages:"; \
    cat /tmp/sitepkgs.txt || true; \
    \
    ANSIBLE_DIR=""; RUNNER_DIR=""; SITEPKG_BASE=""; \
    while read -r d; do \
      if [ -z "$ANSIBLE_DIR" ] && [ -d "$d/ansible" ]; then ANSIBLE_DIR="$d/ansible"; SITEPKG_BASE="$d"; fi; \
      if [ -z "$RUNNER_DIR" ] && [ -d "$d/ansible_runner" ]; then RUNNER_DIR="$d/ansible_runner"; fi; \
    done < /tmp/sitepkgs.txt; \
    \
    if [ -z "$ANSIBLE_DIR" ]; then \
      echo "ERROR: could not find ansible/ in operator-src under /usr"; \
      find "$PYROOT" -maxdepth 9 -type d -name ansible | head -n 50 || true; \
      exit 1; \
    fi; \
    if [ -z "$RUNNER_DIR" ]; then \
      echo "ERROR: could not find ansible_runner/ in operator-src under /usr"; \
      find "$PYROOT" -maxdepth 9 -type d -name ansible_runner | head -n 50 || true; \
      exit 1; \
    fi; \
    \
    # Copy modules
    cp -a "$ANSIBLE_DIR" /usr/lib/python3.9/site-packages/; \
    cp -a "$RUNNER_DIR" /usr/lib/python3.9/site-packages/; \
    \
    # Copy dist-info metadata if present (helps tooling)
    if [ -n "$SITEPKG_BASE" ]; then \
      cp -a "$SITEPKG_BASE"/ansible-*.dist-info /usr/lib/python3.9/site-packages/ 2>/dev/null || true; \
      cp -a "$SITEPKG_BASE"/ansible_runner-*.dist-info /usr/lib/python3.9/site-packages/ 2>/dev/null || true; \
    fi; \
    \
    # Cleanup temp /usr copy
    rm -rf /tmp/operator-src/usr /tmp/sitepkgs.txt; \
    \
    # Sanity check
    python3 -c "import ansible, ansible_runner; print('ansible:', ansible.__file__); print('ansible_runner:', ansible_runner.__file__)"

# Bring over candidate bin dirs from operator-src (paths vary by image build)
COPY --from=operator-src /usr/local/bin/ /tmp/operator-src/usr-local-bin/
COPY --from=operator-src /usr/bin/       /tmp/operator-src/usr-bin/

# Install required CLIs from whichever location exists
RUN set -eux; \
    # ansible-operator MUST exist
    if [ -x /tmp/operator-src/usr-local-bin/ansible-operator ]; then \
      install -m 0755 /tmp/operator-src/usr-local-bin/ansible-operator /usr/local/bin/ansible-operator; \
    elif [ -x /tmp/operator-src/usr-bin/ansible-operator ]; then \
      install -m 0755 /tmp/operator-src/usr-bin/ansible-operator /usr/local/bin/ansible-operator; \
    else \
      echo "ERROR: ansible-operator not found in operator-src"; \
      ls -la /tmp/operator-src/usr-local-bin || true; \
      ls -la /tmp/operator-src/usr-bin || true; \
      exit 1; \
    fi; \
    \
    # Optional CLIs (may not exist; OK)
    for b in ansible-runner ansible-playbook ansible-galaxy ansible-doc ansible; do \
      if [ -x "/tmp/operator-src/usr-local-bin/$b" ]; then \
        install -m 0755 "/tmp/operator-src/usr-local-bin/$b" "/usr/local/bin/$b"; \
      elif [ -x "/tmp/operator-src/usr-bin/$b" ]; then \
        install -m 0755 "/tmp/operator-src/usr-bin/$b" "/usr/local/bin/$b"; \
      else \
        echo "INFO: $b not present in operator-src (ok)"; \
      fi; \
    done; \
    rm -rf /tmp/operator-src; \
    /usr/local/bin/ansible-operator version

# Minimal ansible.cfg WITHOUT forcing stdout_callback
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
