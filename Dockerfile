# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - UBI9 Rebase (Path B)
#
# What this Dockerfile does:
# 1) Uses the Red Hat OpenShift Ansible Operator base image ONLY as a source of
#    the operator runtime bits under /opt and the ansible-operator binary.
# 2) Uses UBI9 as the published base image to reduce repo-mixing / improve hygiene.
# 3) Uses UBI's python + ansible-core for ansible-galaxy (so we don't rely on
#    /usr/local/bin/python3 wrappers from the operator base).
# 4) Installs ansible-runner via pip into /opt/pip and makes it discoverable via:
#    - a .pth file in system site-packages (adds /opt/pip site-packages to sys.path)
#    - a stable wrapper /usr/local/bin/ansible-runner that runs: python3 -m ansible_runner
# 5) Sets ENTRYPOINT/CMD to behave like a normal operator image:
#    - running the image runs ansible-operator by default
# 6) Sets OpenShift-friendly permissions for arbitrary UID (restricted SCC).
#
# Key problems this resolves (from your build/runtime logs):
# - /usr/local/bin/entrypoint not found  -> we do NOT use entrypoint
# - /usr/local/bin/python3 bad interpreter -> we do NOT copy ansible-* wrappers
# - ansible-runner not found at runtime -> we install it and put it on PATH
# - ModuleNotFoundError ansible_runner (pip --prefix) -> we add .pth + wrapper
# -----------------------------------------------------------------------------

# Pin the exact digest you validated exists and contains /usr/local/bin/ansible-operator
ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

# Stage 0: Official operator image (we only copy select runtime artifacts from here)
FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

# Stage 1 (final): Published UBI9 image
FROM registry.access.redhat.com/ubi9/ubi:latest AS final

# We need root during image build to install packages and set perms
USER 0

# This is the directory ansible-operator expects to run from
ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# Repo hygiene:
# If a redhat.repo is present (common when mixing layers), remove it so we only
# use UBI repos and avoid subscription/rhel repo mixing.
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# -----------------------------------------------------------------------------
# Install base tooling from UBI repos:
# - python3 + pip: required to install ansible-runner via pip (since RPM not found)
# - ansible-core: provides ansible-galaxy and ansible tooling compatible with UBI
# - dnf-plugins-core: provides config-manager
#
# NOTE about curl:
#   Do NOT install curl explicitly. UBI commonly ships curl-minimal and installing
#   curl can conflict. Keep it out unless you have a strong reason.
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
# Patch UBI to pull in latest security errata available at build time.
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# Create expected directories:
# - /opt/ansible and /opt/ansible/.ansible for collections
# - /opt/pip for pip --prefix installs
# - /licenses for certification
# - /usr/local/bin for our stable wrappers
# -----------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p \
      /opt/ansible \
      /opt/ansible/.ansible \
      /opt/pip \
      /licenses \
      /usr/local/bin \
      /opt/ansible-operator

# -----------------------------------------------------------------------------
# Copy operator runtime bits from the official operator image:
# - Copy /opt: this is where the operator SDK expects runtime scaffolding.
# - Copy ONLY the ansible-operator binary (Go binary; safe to copy).
#
# IMPORTANT:
#   We do NOT copy the whole /usr/local/bin directory from operator-src because
#   it contains tiny ansible-* python wrappers that depend on /usr/local/bin/python3
#   and other non-UBI paths.
# -----------------------------------------------------------------------------
COPY --from=operator-src /opt/ /opt/
COPY --from=operator-src /usr/local/bin/ansible-operator /usr/local/bin/ansible-operator

# Sanity check: verify the binary exists and can print its version
RUN set -eux; \
    test -x /usr/local/bin/ansible-operator; \
    /usr/local/bin/ansible-operator version

# -----------------------------------------------------------------------------
# Install ansible-runner via pip into /opt/pip
#
# Why:
#   Your UBI repos don't have an 'ansible-runner' RPM in this build context.
#
# The critical part:
#   pip --prefix installs modules under:
#     /opt/pip/lib/pythonX.Y/site-packages
#   but system python won't search that path by default.
#
# Fix:
#   - write a .pth file into system site-packages to add /opt/pip site-packages
#   - create /usr/local/bin/ansible-runner wrapper that runs:
#       /usr/bin/python3 -m ansible_runner
#
# This avoids:
# - broken shebangs in pip-generated console scripts
# - ModuleNotFoundError (ansible_runner not on sys.path)
# -----------------------------------------------------------------------------
RUN set -eux; \
    /usr/bin/pip3 install --no-cache-dir --prefix /opt/pip "ansible-runner>=2.4,<3"; \
    pyver="$(/usr/bin/python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"; \
    sitepk="/opt/pip/lib/python${pyver}/site-packages"; \
    test -d "${sitepk}"; \
    echo "${sitepk}" > "/usr/lib/python${pyver}/site-packages/zz_opt_pip_sitepackages.pth"; \
    cat > /usr/local/bin/ansible-runner <<'EOF'\n\
#!/bin/sh\n\
exec /usr/bin/python3 -m ansible_runner "$@"\n\
EOF\n\
    chmod +x /usr/local/bin/ansible-runner; \
    /usr/local/bin/ansible-runner --version; \
    /usr/bin/python3 -c 'import ansible_runner; print("ansible_runner import OK:", ansible_runner.__version__)'

# -----------------------------------------------------------------------------
# Certification labels (update values as needed)
# -----------------------------------------------------------------------------
LABEL name="webserver-operator-dev" \
      vendor="Duncan Networks" \
      maintainer="Phil Duncan <philipduncan860@gmail.com>" \
      version="1.0.34" \
      release="1" \
      summary="Kubernetes operator to deploy and manage web workloads" \
      description="An Ansible-based operator that manages web workload deployments on OpenShift/Kubernetes."

# Licensing (simple placeholder)
RUN set -eux; \
    printf "See project repository for license and terms.\n" > /licenses/NOTICE

# -----------------------------------------------------------------------------
# Logging and runtime env
# - Ensure Ansible prints to stdout/stderr so OpenShift Console "Logs" shows it.
# - Add /opt/pip/bin early in PATH just in case (we still provide wrapper).
# -----------------------------------------------------------------------------
ENV ANSIBLE_STDOUT_CALLBACK=default \
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
    chmod -R g+rwX /opt/ansible/.ansible; \
    rm -f /tmp/requirements.yml

# -----------------------------------------------------------------------------
# Copy operator content (watches, playbooks, roles)
# -----------------------------------------------------------------------------
COPY watches.yaml ./watches.yaml
COPY playbooks/ ./playbooks/
COPY roles/ ./roles/

# -----------------------------------------------------------------------------
# OpenShift-friendly permissions:
# - chgrp 0 + chmod g=u lets arbitrary UIDs (restricted SCC) write where needed.
# -----------------------------------------------------------------------------
RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses /usr/local/bin /opt/pip; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /opt/ansible/.ansible /licenses /usr/local/bin /opt/pip

# Run as arbitrary non-root UID
USER 1001
ENV ANSIBLE_USER_ID=1001

# -----------------------------------------------------------------------------
# Behave like a typical operator image:
# - ENTRYPOINT is the ansible-operator binary we copied from operator-src
# - CMD is the default action (run) with watches file
# -----------------------------------------------------------------------------
ENTRYPOINT ["/usr/local/bin/ansible-operator"]
CMD ["run", "--watches-file=/opt/ansible-operator/watches.yaml"]
