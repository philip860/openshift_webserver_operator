# -----------------------------------------------------------------------------
# WebServer Operator (Ansible Operator) - Path B (Rebased UBI, Red Hat scan-friendly)
# -----------------------------------------------------------------------------

ARG OSE_ANSIBLE_DIGEST=sha256:81fe42f5070bdfadddd92318d00eed63bf2ad95e2f7e8a317f973aa8ab9c3a88

FROM registry.redhat.io/openshift4/ose-ansible-rhel9-operator@${OSE_ANSIBLE_DIGEST} AS operator-src

FROM registry.access.redhat.com/ubi9/ubi:latest AS final

USER 0

ENV ANSIBLE_OPERATOR_DIR=/opt/ansible-operator
WORKDIR ${ANSIBLE_OPERATOR_DIR}

# -----------------------------------------------------------------------------
# 1) Repo hygiene: keep ONLY UBI repos
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -f /etc/yum.repos.d/redhat.repo || true; \
    rm -f /etc/yum.repos.d/redhat.repo.rpmsave /etc/yum.repos.d/redhat.repo.rpmnew || true

# -----------------------------------------------------------------------------
# 2) Install minimal tooling INCLUDING ansible-core
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y install dnf-plugins-core ca-certificates yum \
      python3 python3-setuptools python3-pip \
      ansible-core; \
    dnf config-manager --set-enabled ubi-9-baseos-rpms || true; \
    dnf config-manager --set-enabled ubi-9-appstream-rpms || true; \
    dnf config-manager --set-enabled ubi-9-codeready-builder-rpms || true; \
    dnf -y repolist; \
    python3 --version; \
    ansible --version; \
    ansible-galaxy --version; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# 3) Patch UBI packages (security errata)
# -----------------------------------------------------------------------------
RUN set -eux; \
    dnf -y makecache --refresh; \
    dnf -y update --security --refresh; \
    dnf -y clean all; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# 4) OpenShift-friendly dirs + callback plumbing
# -----------------------------------------------------------------------------
ENV HOME=/opt/ansible \
    ANSIBLE_LOCAL_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_REMOTE_TEMP=/opt/ansible/.ansible/tmp \
    ANSIBLE_COLLECTIONS_PATHS=/opt/ansible/.ansible/collections:/usr/share/ansible/collections \
    ANSIBLE_ROLES_PATH=/opt/ansible/.ansible/roles:/etc/ansible/roles:/usr/share/ansible/roles \
    ANSIBLE_LOAD_CALLBACK_PLUGINS=1 \
    ANSIBLE_CALLBACK_PLUGINS=/usr/share/ansible/plugins/callback \
    ANSIBLE_NOCOLOR=1 \
    ANSIBLE_FORCE_COLOR=0 \
    TERM=dumb \
    PYTHONUNBUFFERED=1

RUN set -eux; \
    mkdir -p \
      /opt/ansible/.ansible/tmp \
      /opt/ansible/.ansible/collections \
      /opt/ansible/.ansible/roles \
      /usr/share/ansible/plugins/callback \
      /etc/ansible \
      /licenses \
      ${ANSIBLE_OPERATOR_DIR}; \
    chgrp -R 0 /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR} /usr/share/ansible/plugins /etc/ansible; \
    chmod -R g+rwX /opt/ansible /licenses ${ANSIBLE_OPERATOR_DIR} /usr/share/ansible/plugins /etc/ansible

# -----------------------------------------------------------------------------
# 5) Copy operator runtime bits from official OpenShift operator base
# -----------------------------------------------------------------------------
COPY --from=operator-src /opt/ /opt/

# -----------------------------------------------------------------------------
# 6) Copy ansible-operator binary from operator-src (robust detection)
# -----------------------------------------------------------------------------
RUN set -eux; \
    if [ -x /usr/local/bin/ansible-operator ]; then \
      echo "ansible-operator already exists in this image (unexpected)"; \
    fi

COPY --from=operator-src /usr/local/bin/ /tmp/operator-src/usr-local-bin/
COPY --from=operator-src /usr/bin/ /tmp/operator-src/usr-bin/

RUN set -eux; \
    if [ -x /tmp/operator-src/usr-local-bin/ansible-operator ]; then \
      install -m 0755 /tmp/operator-src/usr-local-bin/ansible-operator /usr/local/bin/ansible-operator; \
    elif [ -x /tmp/operator-src/usr-bin/ansible-operator ]; then \
      install -m 0755 /tmp/operator-src/usr-bin/ansible-operator /usr/local/bin/ansible-operator; \
    else \
      echo "ERROR: ansible-operator not found in operator-src image"; \
      ls -la /tmp/operator-src/usr-local-bin || true; \
      ls -la /tmp/operator-src/usr-bin || true; \
      exit 1; \
    fi; \
    rm -rf /tmp/operator-src; \
    /usr/local/bin/ansible-operator version

# -----------------------------------------------------------------------------
# 7) Install ansible-runner + k8s deps via pip
#    Then: copy runner callback plugins and set stdout_callback to the REAL plugin name.
# -----------------------------------------------------------------------------
RUN set -eux; \
    python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel; \
    python3 -m pip install --no-cache-dir \
      "ansible-runner>=2.3.6" \
      "kubernetes>=24.2.0" \
      "openshift>=0.13.2"; \
    python3 -c "import kubernetes, openshift, ansible_runner; print('python deps OK')"; \
    ansible-runner --version; \
    \
    python3 - <<'PY'
import os, glob, shutil
import ansible_runner

pkg_dir = os.path.dirname(ansible_runner.__file__)

# These cover runner 2.3.x and 2.4.x layouts
candidates = [
    os.path.join(pkg_dir, "plugins", "callback"),
    os.path.join(pkg_dir, "display_callback", "callback"),
    os.path.join(pkg_dir, "interface", "callback"),
]

found = None
for d in candidates:
    if os.path.isdir(d):
        pyfiles = [p for p in glob.glob(os.path.join(d, "*.py")) if not p.endswith("__init__.py")]
        if pyfiles:
            found = d
            break

if not found:
    raise SystemExit(f"ERROR: Could not find ansible-runner callback plugin directory. Tried: {candidates}")

dst = "/usr/share/ansible/plugins/callback"
os.makedirs(dst, exist_ok=True)

pyfiles = [p for p in glob.glob(os.path.join(found, "*.py")) if not p.endswith("__init__.py")]
for p in pyfiles:
    shutil.copy2(p, os.path.join(dst, os.path.basename(p)))

print("Copied callback plugin file(s) from", found, "to", dst)

# Pick the "best" stdout callback name:
# Prefer a file that looks like the runner callback; fall back to the first plugin file.
names = [os.path.splitext(os.path.basename(p))[0] for p in pyfiles]
preferred = None
for cand in ("ansible_runner", "runner", "awx_display", "display"):
    if cand in names:
        preferred = cand
        break
if not preferred:
    preferred = sorted(names)[0]

# Write ansible.cfg to use the discovered callback plugin
cfg = "/etc/ansible/ansible.cfg"
os.makedirs("/etc/ansible", exist_ok=True)
with open(cfg, "w") as f:
    f.write("[defaults]\n")
    f.write("callback_plugins = /usr/share/ansible/plugins/callback\n")
    f.write(f"stdout_callback = {preferred}\n")
    f.write("bin_ansible_callbacks = True\n")
    f.write("nocows = 1\n")

print("Configured stdout_callback =", preferred)
PY
    \
    # Sanity: ensure ansible can see the configured callback
    python3 - <<'PY'
import configparser
cfg = configparser.ConfigParser()
cfg.read("/etc/ansible/ansible.cfg")
cb = cfg.get("defaults", "stdout_callback", fallback="")
print("Sanity check: stdout_callback =", cb)
PY
    dnf -y clean all || true; \
    rm -rf /var/cache/dnf /var/tmp/* /tmp/*

# -----------------------------------------------------------------------------
# 8) Required certification labels + NOTICE
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
# 9) Operator content + collections
# -----------------------------------------------------------------------------
COPY requirements.yml /tmp/requirements.yml
RUN set -eux; \
    if [ -s /tmp/requirements.yml ]; then \
      ansible-galaxy collection install -r /tmp/requirements.yml \
        --collections-path /opt/ansible/.ansible/collections; \
    fi; \
    rm -f /tmp/requirements.yml; \
    chgrp -R 0 /opt/ansible; \
    chmod -R g+rwX /opt/ansible

COPY watches.yaml ${ANSIBLE_OPERATOR_DIR}/watches.yaml
COPY playbooks/ ${ANSIBLE_OPERATOR_DIR}/playbooks/
COPY roles/ ${ANSIBLE_OPERATOR_DIR}/roles/

RUN set -eux; \
    chgrp -R 0 ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /usr/share/ansible/plugins /etc/ansible; \
    chmod -R g=u ${ANSIBLE_OPERATOR_DIR} /opt/ansible /licenses /usr/share/ansible/plugins /etc/ansible

# -----------------------------------------------------------------------------
# 10) Entrypoint shim
# -----------------------------------------------------------------------------
RUN set -eux; \
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    '' \
    '# Run the operator using the watches file packaged into the image.' \
    'exec /usr/local/bin/ansible-operator run --watches-file=/opt/ansible-operator/watches.yaml' \
  > /usr/local/bin/entrypoint; \
  chmod 0755 /usr/local/bin/entrypoint

# -----------------------------------------------------------------------------
# 11) Drop to non-root for OpenShift
# -----------------------------------------------------------------------------
USER 1001
ENV ANSIBLE_USER_ID=1001

ENTRYPOINT ["/usr/local/bin/entrypoint"]
