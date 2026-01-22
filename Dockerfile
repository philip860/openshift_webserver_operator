# -----------------------------------------------------------------------------
# WebServer Operator - Rebased UBI9 + Preserve official runner/ansible behavior
#
# Goal:
# - Pass Red Hat scan (UBI base + errata)
# - Mirror official ose-ansible-rhel9-operator runtime behavior so runner events
#   (including playbook_on_stats) work exactly like the base image.
# - Avoid pip-installing ansible-runner (layout/codec issues) and avoid heredocs.
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# Stage 0: official operator image (known-good ansible-runner + callbacks + config)
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

# Stage 1: rebased UBI image we publish
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0

ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# 1) Repo hygiene: remove redhat.repo; use only UBI content
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# -----------------------------------------------------------------------------
# 2) Enable UBI repos + install Python runtime
#    NOTE: UBI containers may not provide dnf modules; do NOT use `dnf module`.
#    Create stable /usr/local/bin/python3 + pip3 pointing at what we have.
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates yum findutils which tar gzip shadow-utils; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y makecache --refresh; \
    \
    if dnf -y install python3.12 python3.12-pip python3.12-setuptools python3.12-wheel; then \
      ln -sf /usr/bin/python3.12 /usr/local/bin/python3; \
      ln -sf /usr/bin/pip3.12 /usr/local/bin/pip3 || true; \
    else \
      echo "WARN: python3.12 not available in enabled UBI repos; falling back to python3"; \
      dnf -y install python3 python3-pip python3-setuptools python3-wheel; \
      ln -sf /usr/bin/python3 /usr/local/bin/python3; \
      ln -sf /usr/bin/pip3 /usr/local/bin/pip3 || true; \
    fi; \
    /usr/local/bin/python3 -V; \
    /usr/local/bin/python3 -m pip --version; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# 3) Patch UBI packages (security errata)
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh || dnf -y update --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# 4) Create OpenShift-friendly dirs
# -----------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p \
      /opt/ansible/.ansible/tmp \
      /opt/ansible/.ansible/collections \
      /opt/ansible/.ansible/roles \
      /etc/ansible \
      /licenses \
      ${ANSIBLE_OPERATOR_DIR} \
      /usr/local/bin

# -----------------------------------------------------------------------------
# 5) Copy operator runtime bits (under /opt) from official base
# -----------------------------------------------------------------------------
COPY --from=operator-src /opt/ /opt/

# -----------------------------------------------------------------------------
# 6) Bring in known-good configs + runner bits from operator-src
# -----------------------------------------------------------------------------
COPY --from=operator-src /etc/ansible/ /etc/ansible/
# NOTE: operator-src does NOT always ship /usr/share/ansible, so do not copy it.
# COPY --from=operator-src /usr/share/ansible/ /usr/share/ansible/
COPY --from=operator-src /usr/local/bin/ /tmp/operator-src/usr-local-bin/
COPY --from=operator-src /usr/bin/ /tmp/operator-src/usr-bin/
COPY --from=operator-src /usr/local/lib/ /tmp/operator-src/usr-local-lib/
COPY --from=operator-src /usr/local/lib64/ /tmp/operator-src/usr-local-lib64/

# -----------------------------------------------------------------------------
# 7) Install ansible-operator binary from operator-src (robust)
# -----------------------------------------------------------------------------
RUN set -eux; \
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
    /usr/local/bin/ansible-operator version

# -----------------------------------------------------------------------------
# 8) Copy the *exact* site-packages for ansible + ansible_runner from operator-src
#    into this rebased image’s current python3 site-packages.
#
#    IMPORTANT FIXES:
#    - Do NOT hardcode python3.12 paths (may fall back to python3)
#    - Do NOT hardcode operator-src python3.12 site-packages paths
#    - Install missing deps required by copied stack (pexpect, PyYAML, python-daemon, etc.)
# -----------------------------------------------------------------------------
RUN set -eux; \
    DEST_SITEPKG="$("/usr/local/bin/python3" -c 'import site; print(site.getsitepackages()[0])')"; \
    echo "DEST_SITEPKG=${DEST_SITEPKG}"; \
    mkdir -p "${DEST_SITEPKG}"; \
    \
    # Locate operator-src site-packages (python version may vary in the source image)
    SRC_SITEPKG="$(find /tmp/operator-src -type d -path '*/site-packages' | head -n 1 || true)"; \
    if [ -z "$SRC_SITEPKG" ]; then \
      echo "ERROR: could not find operator-src site-packages under /tmp/operator-src"; \
      find /tmp/operator-src -maxdepth 10 -type d -name site-packages | head -n 200 || true; \
      exit 1; \
    fi; \
    echo "Using SRC_SITEPKG=${SRC_SITEPKG}"; \
    \
    cp -a "${SRC_SITEPKG}/ansible" "${DEST_SITEPKG}/"; \
    cp -a "${SRC_SITEPKG}/ansible_runner" "${DEST_SITEPKG}/"; \
    \
    # copy related dist-info if present (helps packaging metadata)
    cp -a "${SRC_SITEPKG}"/ansible-*.dist-info "${DEST_SITEPKG}/" 2>/dev/null || true; \
    cp -a "${SRC_SITEPKG}"/ansible_runner-*.dist-info "${DEST_SITEPKG}/" 2>/dev/null || true; \
    \
    # extra deps: keep builds from failing with ModuleNotFoundError (yaml/pexpect/daemon/etc.)
    /usr/local/bin/python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel; \
    /usr/local/bin/python3 -m pip install --no-cache-dir \
      "pexpect>=4.8.0" \
      "ptyprocess>=0.7.0" \
      "PyYAML>=6.0" \
      "python-daemon>=3.0.1" \
      "lockfile>=0.12.2" \
      "jinja2>=3.1" \
      "packaging" \
      "resolvelib" \
      "cryptography"; \
    \
    /usr/local/bin/python3 -c "import pexpect, ptyprocess, yaml, daemon, lockfile, jinja2, packaging, resolvelib, cryptography; print('OK deps')"; \
    /usr/local/bin/python3 -c "import ansible, ansible_runner; print('OK:', ansible.__file__, ansible_runner.__file__)"

# -----------------------------------------------------------------------------
# 9) Clean temp copies
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -rf /tmp/operator-src

# -----------------------------------------------------------------------------
# 10) Environment: prefer our stable python path for localhost execution inside runner
# -----------------------------------------------------------------------------
ENV HOME=/opt/ansible \
    ANSIBLE_LOCAL_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_REMOTE_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_COLLECTIONS_PATHS=/opt/ansible/.ansible/collections:/usr/share/ansible/collections \
    ANSIBLE_ROLES_PATH=/opt/ansible/.ansible/roles:/etc/ansible/roles:/usr/share/ansible/roles \
    ANSIBLE_LOAD_CALLBACK_PLUGINS=1 \
    ANSIBLE_PYTHON_INTERPRETER=/usr/local/bin/python3 \
    PYTHONUNBUFFERED=1 \
    PIP_ROOT_USER_ACTION=ignore

# -----------------------------------------------------------------------------
# 11) Required certification labels + NOTICE
# -----------------------------------------------------------------------------
LABEL name="webserver-operator" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.35" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

RUN set -eux; \
    mkdir -p /licenses; \
    printf "See project repository for license and terms.\n" > /licenses/NOTICE

# -----------------------------------------------------------------------------
# 12) Collections + operator content
#    FIXES:
#    - /usr/share/ansible often does not exist -> don't chgrp/chmod it
#    - ansible-galaxy may not exist in this rebased layout -> warn and continue
# -----------------------------------------------------------------------------
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    if [ -s /tmp/requirements.yml ]; then \
      if command -v ansible-galaxy >/dev/null 2>&1; then \
        ansible-galaxy collection install -r /tmp/requirements.yml \
          --collections-path /opt/ansible/.ansible/collections; \
      else \
        echo "WARN: ansible-galaxy not found; collections step skipped"; \
      fi; \
    fi; \
    rm -f /tmp/requirements.yml; \
    chgrp -R 0 /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR} /etc/ansible || true; \
    chmod -R g+rwX /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR} /etc/ansible || true

COPY watches.yaml ${ANSIBLE_OPERATOR_DIR}/watches.yaml
COPY playbooks/ ${ANSIBLE_OPERATOR_DIR}/playbooks/
COPY roles/ ${ANSIBLE_OPERATOR_DIR}/roles/

RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /etc/ansible || true; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /etc/ansible || true

# -----------------------------------------------------------------------------
# 13) Entrypoint
# -----------------------------------------------------------------------------
RUN set -eux; \
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'exec /usr/local/bin/ansible-operator run --watches-file=/opt/ansible-operator/watches.yaml' \
  > /usr/local/bin/entrypoint; \
  chmod 0755 /usr/local/bin/entrypoint

# -----------------------------------------------------------------------------
# 14) Run as OpenShift arbitrary UID (non-root)
# -----------------------------------------------------------------------------
USER 1001
ENV ANSIBLE_USER_ID=1001

ENTRYPOINT ["/usr/local/bin/entrypoint"]
