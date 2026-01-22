# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - UBI rebase WITHOUT breaking runner events
#
# Fixes in this version:
# - DO NOT copy python3.12 site-packages into python3.9
# - Prefer operator-src python3.9 site-packages first
# - If importlib_metadata/zipp not present in operator-src, pip install ONLY those
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# -----------------------------------------------------------------------------
# Stage 0: Official operator base as source-of-truth
# -----------------------------------------------------------------------------
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# Install collections in the official image (avoid needing ansible-core in UBI)
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    if [ -s /tmp/requirements.yml ]; then \
      ansible-galaxy collection install -r /tmp/requirements.yml \
        --collections-path /opt/ansible/.ansible/collections; \
    fi; \
    rm -f /tmp/requirements.yml

COPY watches.yaml ${ANSIBLE_OPERATOR_DIR}/watches.yaml
COPY playbooks/ ${ANSIBLE_OPERATOR_DIR}/playbooks/
COPY roles/ ${ANSIBLE_OPERATOR_DIR}/roles/

# -----------------------------------------------------------------------------
# Stage 1: Final published image (UBI9)
# -----------------------------------------------------------------------------
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# Repo hygiene: keep ONLY UBI repos
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# Enable UBI repos + install minimal runtime deps
# NOTE: Do NOT try to dnf install importlib-metadata/zipp (not in your repos)
RUN set -eux; \
    dnf -y install dnf-plugins-core; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y makecache --refresh; \
    dnf -y install \
      ca-certificates \
      python3 python3-pip \
      python3-pyyaml python3-jinja2 python3-cryptography python3-requests python3-six \
      python3-pexpect \
      tar gzip findutils which shadow-utils; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# Patch UBI (CVE reduction)
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh || dnf -y update --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# OpenShift-friendly env (IMPORTANT: do NOT force stdout_callback here)
ENV HOME=/opt/ansible \
    ANSIBLE_LOCAL_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_REMOTE_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_COLLECTIONS_PATHS=/opt/ansible/.ansible/collections:/usr/share/ansible/collections \
    ANSIBLE_ROLES_PATH=/opt/ansible/.ansible/roles:/etc/ansible/roles:/usr/share/ansible/roles \
    ANSIBLE_NOCOLOR=1 \
    ANSIBLE_FORCE_COLOR=0 \
    TERM=dumb \
    PYTHONUNBUFFERED=1 \
    PIP_ROOT_USER_ACTION=ignore

RUN set -eux; \
    mkdir -p \
      /opt/ansible/.ansible/tmp \
      /opt/ansible/.ansible/collections \
      /opt/ansible/.ansible/roles \
      /etc/ansible \
      /licenses \
      ${ANSIBLE_OPERATOR_DIR} \
      /usr/local/bin \
      /usr/share/ansible/plugins/callback

# Copy /opt runtime bits (your operator content + collections installed in operator-src)
COPY --from=operator-src /opt/ /opt/

# Copy operator-src /usr to temp so we can locate python modules regardless of layout
COPY --from=operator-src /usr/ /tmp/operator-src/usr/

# Transplant python modules needed by operator execution:
# - ansible
# - ansible_runner
# Prefer the SAME python minor version as the UBI image (python3.9 on UBI9).
# If importlib_metadata/zipp are not present in operator-src python3.9 site-packages,
# install only those two via pip.
RUN set -eux; \
    PYVER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"; \
    echo "Final image python version: ${PYVER}"; \
    \
    PYROOT=/tmp/operator-src/usr; \
    find "$PYROOT" -maxdepth 8 -type d -name site-packages > /tmp/sitepkgs.txt || true; \
    echo "Candidate site-packages:"; cat /tmp/sitepkgs.txt || true; \
    \
    # Prefer matching python version paths first
    grep -E "/python${PYVER}/" /tmp/sitepkgs.txt > /tmp/sitepkgs.preferred.txt || true; \
    if [ -s /tmp/sitepkgs.preferred.txt ]; then \
      mv /tmp/sitepkgs.preferred.txt /tmp/sitepkgs.ordered.txt; \
      grep -v -E "/python${PYVER}/" /tmp/sitepkgs.txt >> /tmp/sitepkgs.ordered.txt || true; \
    else \
      cp /tmp/sitepkgs.txt /tmp/sitepkgs.ordered.txt; \
    fi; \
    \
    pick_dir() { \
      want="$1"; \
      while read -r d; do \
        if [ -d "$d/$want" ]; then echo "$d/$want"; return 0; fi; \
      done < /tmp/sitepkgs.ordered.txt; \
      return 1; \
    }; \
    \
    ANSIBLE_DIR="$(pick_dir ansible || true)"; \
    RUNNER_DIR="$(pick_dir ansible_runner || true)"; \
    IMD_DIR="$(pick_dir importlib_metadata || true)"; \
    ZIPP_DIR="$(pick_dir zipp || true)"; \
    \
    if [ -z "$ANSIBLE_DIR" ]; then \
      echo "ERROR: could not find ansible/ in operator-src under /usr"; \
      find "$PYROOT" -maxdepth 10 -type d -name ansible | head -n 50 || true; \
      exit 1; \
    fi; \
    if [ -z "$RUNNER_DIR" ]; then \
      echo "ERROR: could not find ansible_runner/ in operator-src under /usr"; \
      find "$PYROOT" -maxdepth 10 -type d -name ansible_runner | head -n 50 || true; \
      exit 1; \
    fi; \
    \
    echo "Using ANSIBLE_DIR=$ANSIBLE_DIR"; \
    echo "Using RUNNER_DIR=$RUNNER_DIR"; \
    \
    # Copy into the *actual* python3 site-packages in this UBI image
    DEST_SITEPKG="$(python3 -c 'import site; print(site.getsitepackages()[0])')"; \
    echo "DEST_SITEPKG=$DEST_SITEPKG"; \
    \
    cp -a "$ANSIBLE_DIR" "$DEST_SITEPKG/"; \
    cp -a "$RUNNER_DIR" "$DEST_SITEPKG/"; \
    \
    # Copy importlib_metadata + zipp if present; else install via pip (tiny + reliable)
    if [ -n "$IMD_DIR" ] && [ -n "$ZIPP_DIR" ]; then \
      cp -a "$IMD_DIR" "$DEST_SITEPKG/"; \
      cp -a "$ZIPP_DIR" "$DEST_SITEPKG/"; \
      echo "Copied importlib_metadata + zipp from operator-src"; \
    else \
      echo "operator-src missing importlib_metadata/zipp for python${PYVER}; installing via pip"; \
      python3 -m pip install --no-cache-dir "importlib-metadata<6.3" "zipp>=0.5"; \
    fi; \
    \
    rm -rf /tmp/operator-src/usr /tmp/sitepkgs.txt /tmp/sitepkgs.ordered.txt; \
    \
    python3 -c "import ansible, ansible_runner; import importlib_metadata, zipp; print('OK imports:', ansible.__file__, ansible_runner.__file__)"

# Bring over candidate bin dirs from operator-src (paths vary by image build)
COPY --from=operator-src /usr/local/bin/ /tmp/operator-src/usr-local-bin/
COPY --from=operator-src /usr/bin/       /tmp/operator-src/usr-bin/

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

# Certification labels + NOTICE
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
