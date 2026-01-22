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
# 2) Enable UBI repos + install Python 3.12 runtime (do NOT pip ansible/runner)
#    RHEL9/UBI has python3.12 as a parallel installable suite in newer minors.
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates yum findutils which tar gzip shadow-utils; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y makecache --refresh; \
    dnf -y install python3.12 python3.12-pip python3.12-setuptools python3.12-wheel || true; \
    dnf -y install python3.12 python3.12-pip || true; \
    /usr/bin/python3.12 -V; \
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
#    (This is what keeps runner events working like the official image.)
# -----------------------------------------------------------------------------
COPY --from=operator-src /etc/ansible/ /etc/ansible/
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
# 8) Copy the *exact* Python 3.12 site-packages for ansible + ansible_runner
#    from operator-src into this rebased image’s Python 3.12 site-packages.
# -----------------------------------------------------------------------------
RUN set -eux; \
    DEST_SITEPKG="$("/usr/bin/python3.12" -c 'import site; print(site.getsitepackages()[0])')"; \
    echo "DEST_SITEPKG=${DEST_SITEPKG}"; \
    mkdir -p "${DEST_SITEPKG}"; \
    SRC_SITEPKG=""; \
    for d in \
      /tmp/operator-src/usr-local-lib/python3.12/site-packages \
      /tmp/operator-src/usr-local-lib64/python3.12/site-packages \
    ; do \
      if [ -d "$d" ]; then SRC_SITEPKG="$d"; break; fi; \
    done; \
    if [ -z "$SRC_SITEPKG" ]; then \
      echo "ERROR: could not find operator-src python3.12 site-packages under /usr/local/lib{,64}"; \
      find /tmp/operator-src -maxdepth 6 -type d -name site-packages | head -n 200 || true; \
      exit 1; \
    fi; \
    echo "Using SRC_SITEPKG=${SRC_SITEPKG}"; \
    cp -a "${SRC_SITEPKG}/ansible" "${DEST_SITEPKG}/"; \
    cp -a "${SRC_SITEPKG}/ansible_runner" "${DEST_SITEPKG}/"; \
    # copy related dist-info if present (helps packaging metadata)
    cp -a "${SRC_SITEPKG}"/ansible-*.dist-info "${DEST_SITEPKG}/" 2>/dev/null || true; \
    cp -a "${SRC_SITEPKG}"/ansible_runner-*.dist-info "${DEST_SITEPKG}/" 2>/dev/null || true; \
    # ansible-runner on some builds expects importlib_metadata + zipp (py<3.10)
    if [ -d "${SRC_SITEPKG}/importlib_metadata" ] && [ -d "${SRC_SITEPKG}/zipp" ]; then \
      cp -a "${SRC_SITEPKG}/importlib_metadata" "${DEST_SITEPKG}/"; \
      cp -a "${SRC_SITEPKG}/zipp" "${DEST_SITEPKG}/"; \
      cp -a "${SRC_SITEPKG}"/importlib_metadata-*.dist-info "${DEST_SITEPKG}/" 2>/dev/null || true; \
      cp -a "${SRC_SITEPKG}"/zipp-*.dist-info "${DEST_SITEPKG}/" 2>/dev/null || true; \
    fi; \
    /usr/bin/python3.12 -c "import ansible, ansible_runner; print('OK:', ansible.__file__, ansible_runner.__file__)"

# -----------------------------------------------------------------------------
# 9) Clean temp copies
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -rf /tmp/operator-src

# -----------------------------------------------------------------------------
# 10) Environment: prefer python3.12 for localhost execution inside runner
#     Do NOT force stdout_callback here; we keep operator-src’s configs/plugins.
# -----------------------------------------------------------------------------
ENV HOME=/opt/ansible \
    ANSIBLE_LOCAL_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_REMOTE_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_COLLECTIONS_PATHS=/opt/ansible/.ansible/collections:/usr/share/ansible/collections \
    ANSIBLE_ROLES_PATH=/opt/ansible/.ansible/roles:/etc/ansible/roles:/usr/share/ansible/roles \
    ANSIBLE_LOAD_CALLBACK_PLUGINS=1 \
    ANSIBLE_PYTHON_INTERPRETER=/usr/bin/python3.12 \
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
# -----------------------------------------------------------------------------
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    if [ -s /tmp/requirements.yml ]; then \
      # use operator-src’s ansible-galaxy if present, otherwise ansible will still work
      if command -v ansible-galaxy >/dev/null 2>&1; then \
        ansible-galaxy collection install -r /tmp/requirements.yml \
          --collections-path /opt/ansible/.ansible/collections; \
      else \
        echo "WARN: ansible-galaxy not found; collections step skipped"; \
      fi; \
    fi; \
    rm -f /tmp/requirements.yml; \
    chgrp -R 0 /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR} /etc/ansible /usr/share/ansible || true; \
    chmod -R g+rwX /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR} /etc/ansible /usr/share/ansible || true

COPY watches.yaml ${ANSIBLE_OPERATOR_DIR}/watches.yaml
COPY playbooks/ ${ANSIBLE_OPERATOR_DIR}/playbooks/
COPY roles/ ${ANSIBLE_OPERATOR_DIR}/roles/

RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /etc/ansible /usr/share/ansible || true; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /etc/ansible /usr/share/ansible || true

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
